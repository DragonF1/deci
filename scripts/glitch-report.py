#!/usr/bin/env python3
"""Deci glitch report: what the unified log saw around a heard crackle.

When the owner says "it crackled", run this; no manual marking is needed. It
pulls the unified log for a window with one `log show --style syslog --info`
call (an OR-ed predicate) and lines up four sources on one timeline:

  1. Deci's own lines (subsystem com.abraham.Deci): "[GLITCH]" lines, parsed as
     key=value (the contract), for example
       [GLITCH] app="Google Chrome" pid=123 dropouts=+2 latest_ms=11.8
                discontinuities=+0 devices=AA-BB-CC-DD-EE-FF:output,BuiltInSpeakerDevice load=6.42
       [GLITCH] app="Deci music" stalled=1 load=3.10
     plus "[WATCHDOG]", "[RESCUE]", "[CROSSFADE]" and "IO buffer" lines as context.
  2. bluetoothd "A2DP LinkQualityReport" (one a second), "AudioSkywalkReadLoop
     overwait" (BT waited on late audio) and "StreamStateChanged for handle"
     (A2DP stream start/stop).
  3. CoreAudio overloads: the coreaudiod HALS_OverloadMessage burst ("Overload
     possibly due to ...", "Audio IO Overload thread", carc "overload_type"),
     and in the Deci process the HALC "skipping cycle due to overload" and the
     aqme "Abandoning I/O cycle because ..." lines.
  4. Output default changes: coreaudiod "HALS_DefaultDeviceManager::Set..." for
     'dOut' and 'sOut'.

Usage:
  python3 -I scripts/glitch-report.py [--last 30m] [--verbose]
  python3 -I scripts/glitch-report.py --start "YYYY-MM-DD HH:MM[:SS]" [--end "YYYY-MM-DD HH:MM[:SS]"]
  python3 -I scripts/glitch-report.py --from-file PATH [--start ... --end ...]

  --last DUR        window ending now: 90s, 30m, 2h, 1d (default 30m; bare number = minutes)
  --start, --end    local-time window; --end defaults to now
  --from-file PATH  parse saved `log show` text (syslog or compact style) instead
                    of calling `log show`; --start/--end narrow it
  --verbose         after the report, print every matching raw line in log order

Reading it: a BT spike second has ReTx >= 25%, any flushed packet, or a rate
below the best rate seen on that link. A normal second is about 5% ReTx; 50%
and up lined up with heard crackles before. Exit status is 0 (also with zero
events) and 2 on bad arguments or a failed `log show`.
"""

import argparse
import collections
import datetime as dt
import re
import subprocess
import sys

LOG_BIN = "/usr/bin/log"
DECI_SUBSYSTEM = "com.abraham.Deci"
DECI_PROCESS = "Deci"
DECI_CONTEXT_TAGS = ("[WATCHDOG]", "[RESCUE]", "[CROSSFADE]", "IO buffer")

SPIKE_RETX = 25.0      # a BT second at or above this ReTx % is a spike
HEARD_RETX = 50.0      # seconds at or above this lined up with heard crackles before
SUSPECT_CAP = 60
CONTEXT_CAP = 25
NEAR_ROUTE_S = 2       # an event this close to a route change is a switch transient
COINCIDE_S = 1         # a BT spike this close to a Deci/HAL event counts as coinciding
HAL_CLUSTER_S = 1.0    # coreaudiod logs one overload as a burst of lines

PREDICATE = " OR ".join((
    '(subsystem == "com.abraham.Deci" AND (eventMessage CONTAINS "[GLITCH]"'
    ' OR eventMessage CONTAINS "[WATCHDOG]" OR eventMessage CONTAINS "[RESCUE]"'
    ' OR eventMessage CONTAINS "[CROSSFADE]" OR eventMessage CONTAINS "IO buffer"))',
    '(process == "bluetoothd" AND (eventMessage CONTAINS "A2DP LinkQualityReport"'
    ' OR eventMessage CONTAINS "AudioSkywalkReadLoop overwait"'
    ' OR eventMessage CONTAINS "StreamStateChanged for handle"))',
    '(process == "coreaudiod" AND (eventMessage CONTAINS[c] "overload"'
    ' OR eventMessage CONTAINS "HALS_DefaultDeviceManager::Set"))',
    '(process == "Deci" AND (eventMessage CONTAINS[c] "overload"'
    ' OR eventMessage CONTAINS[c] "skipping cycle"'
    ' OR eventMessage CONTAINS "Abandoning I/O cycle"))',
))

# Line layout. syslog: "TS[+-zzzz]  host proc[pid]: (Lib) [subsystem:category] msg"
# compact: "TS Ty proc[pid:tid] (Lib) msg" or "TS Ty proc[pid:tid] [subsystem:category] msg"
TS_RE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d(?:\.\d+)?)(?:[+-]\d{4})?\s+(\S+)\s+(.*)$")
TYPE_RE = re.compile(r"^[A-Z][a-z]?$")
PROC_SYSLOG_RE = re.compile(r"^([^\[\]()]+?)\[(\d+)\]:\s?(.*)$")
PROC_COMPACT_RE = re.compile(r"^([^\[\]()]+?)\[(\d+)(?::[0-9a-fA-F]+)?\]\s?(.*)$")
TAIL_RE = re.compile(r"^(?:\(([^)]*)\)\s+)?(?:\[([A-Za-z0-9_.\-]+):([^\]]*)\]\s*)?(.*)$", re.S)

# The fields bluetoothd prints in its A2DP LinkQualityReport lines.
LQR_RE = re.compile(
    r"A2DP LinkQualityReport: Handle = (\d+) ReTx =\s*([\d.]+)% \(\s*(\d+) /\s*(\d+)\), "
    r"NAK =\s*(\d+), NoSync =\s*(\d+), TxPwr =\s*(-?\d+) dBm, RSSI =\s*(-?\d+)"
    r".*?TxFlush pkts =\s*(\d+), Tx2Flush pkts =\s*(\d+), rate =\s*(\d+) kbps Flow off =\s*(\d+)")
OVERWAIT_RE = re.compile(r"AudioSkywalkReadLoop overwait (\d+) ms")
STREAM_RE = re.compile(r"music playback is (started|stopped)(?:.*?bitrate (\d+))?")
DEFDEV_RE = re.compile(
    r"HALS_DefaultDeviceManager::Set(Transient)?DefaultDevice\w*:\s*'(\w+)\s*'\s*\|\s*(\d+):\s*'([^']*)'")
CAUSE_CARC_RE = re.compile(r'"cause": Optional\(([^)]*)\)')
CAUSE_TEXT_RE = re.compile(r"Overload possibly due to (.+?)\.?\s*$")
CLIENT_RE = re.compile(r'"HAL_client_IO_duration": Optional\((\d+)\)')
BUDGET_RE = re.compile(r'"io_cycle_budget": Optional\((\d+)\)')
TRANSPORT_RE = re.compile(r'"output_device_transport_list": Optional\(([^)]*)\)')
OTYPE_RE = re.compile(r'"overload_type": Optional\(([^)]*)\)')
ABANDON_RE = re.compile(r"(\S+): Abandoning I/O cycle because (.+?)\s*$")
SRC_PREFIX_RE = re.compile(r"^\S+\.(?:cpp|mm|m|c|h|hpp):\d+\s+")
KV_RE = re.compile(r'(\w+)=("[^"]*"|\S+)')

Rec = collections.namedtuple("Rec", "ts proc subsystem msg raw")
ROLE_NAMES = {"dOut": "default output", "sOut": "system output"}


# ---------------------------------------------------------------- parsing

def parse_ts(s):
    fmt = "%Y-%m-%d %H:%M:%S.%f" if "." in s else "%Y-%m-%d %H:%M:%S"
    return dt.datetime.strptime(s, fmt)


def parse_text(text):
    """Turns `log show` text (syslog or compact style) into records."""
    recs = []
    for line in text.splitlines():
        m = TS_RE.match(line)
        if not m:
            # A message with embedded newlines continues on the next lines.
            if recs and line.strip() and not line.startswith("Timestamp"):
                last = recs[-1]
                recs[-1] = last._replace(msg=last.msg + " " + line.strip(), raw=last.raw + "\n" + line)
            continue
        ts_s, first, rest = m.groups()
        try:
            ts = parse_ts(ts_s)
        except ValueError:
            continue
        if TYPE_RE.match(first):  # compact: first token is the level (Df, E, I, A ...)
            pm = PROC_COMPACT_RE.match(rest)
        else:                     # syslog: first token is the host
            pm = PROC_SYSLOG_RE.match(rest)
        if pm:
            proc, tail = pm.group(1).strip(), pm.group(3)
        else:
            proc, tail = "", rest
        tm = TAIL_RE.match(tail)
        subsystem = tm.group(2) or ""
        msg = (tm.group(4) or "").strip()
        recs.append(Rec(ts, proc, subsystem, msg, line))
    return recs


def to_int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        try:
            return int(float(v))
        except (TypeError, ValueError):
            return 0


def to_float(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def parse_glitch(msg):
    body = msg.split("[GLITCH]", 1)[1]
    kv = {}
    for k, v in KV_RE.findall(body):
        if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
            v = v[1:-1]
        kv[k] = v
    return {
        "app": kv.get("app", "?"),
        "pid": kv.get("pid"),
        "dropouts": to_int(kv.get("dropouts")) if "dropouts" in kv else None,
        "latest_ms": to_float(kv.get("latest_ms")),
        "disc": to_int(kv.get("discontinuities")) if "discontinuities" in kv else None,
        "stalled": to_int(kv.get("stalled")) if "stalled" in kv else None,
        "devices": kv.get("devices"),
        "load": to_float(kv.get("load")),
    }


# ---------------------------------------------------------------- model

class Model(object):
    def __init__(self):
        self.matched = []          # every record a classifier used, for --verbose
        self.glitches = []         # (ts, fields)
        self.deci_context = []     # (ts, msg)
        self.lqr = []              # sample dicts, one per LQR line
        self.lqr_unparsed = 0
        self.overwaits = []        # (ts, ms)
        self.hal = {"coreaudiod": [], "Deci": []}   # (ts, msg)
        self.routes = []           # (ts, text): output default changes
        self.streams = []          # (ts, text): A2DP stream start/stop


def classify(r, m):
    msg = r.msg
    if r.subsystem == DECI_SUBSYSTEM or (r.proc == DECI_PROCESS and "[GLITCH]" in msg):
        if "[GLITCH]" in msg:
            m.glitches.append((r.ts, parse_glitch(msg)))
        elif any(t in msg for t in DECI_CONTEXT_TAGS):
            m.deci_context.append((r.ts, msg))
        else:
            return
        m.matched.append(r)
        return
    if r.proc == "bluetoothd":
        if "A2DP LinkQualityReport" in msg:
            g = LQR_RE.search(msg)
            if not g:
                m.lqr_unparsed += 1
            else:
                v = g.groups()
                m.lqr.append({
                    "ts": r.ts, "handle": v[0], "retx_pct": float(v[1]), "retx": int(v[2]),
                    "tot": int(v[3]), "nak": int(v[4]), "nosync": int(v[5]), "rssi": int(v[7]),
                    "flush": int(v[8]), "flush2": int(v[9]), "rate": int(v[10]), "flowoff": int(v[11]),
                })
        elif "AudioSkywalkReadLoop overwait" in msg:
            g = OVERWAIT_RE.search(msg)
            m.overwaits.append((r.ts, int(g.group(1)) if g else None))
        elif "StreamStateChanged for handle" in msg:
            g = STREAM_RE.search(msg)
            if not g:
                return
            text = "A2DP stream " + g.group(1)
            if g.group(1) == "started" and g.group(2):
                text += " (%s kbps)" % g.group(2)
            m.streams.append((r.ts, text))
        else:
            return
        m.matched.append(r)
        return
    if r.proc == "coreaudiod":
        if "HALS_DefaultDeviceManager::Set" in msg:
            g = DEFDEV_RE.search(msg)
            if g and g.group(2) in ROLE_NAMES:
                text = "%s -> %s" % (ROLE_NAMES[g.group(2)], g.group(4) or ("device " + g.group(3)))
                if g.group(1):
                    text += " (transient)"
                m.routes.append((r.ts, text))
        elif "overload" in msg.lower():
            m.hal["coreaudiod"].append((r.ts, msg))
        else:
            return
        m.matched.append(r)
        return
    if r.proc == DECI_PROCESS:
        low = msg.lower()
        if "overload" in low or "skipping cycle" in low or "abandoning i/o cycle" in low:
            m.hal["Deci"].append((r.ts, msg))
            m.matched.append(r)


def cluster(lines):
    """Groups (ts, msg) lines whose gaps are at most HAL_CLUSTER_S into events."""
    out = []
    for ts, msg in sorted(lines, key=lambda x: x[0]):
        if out and (ts - out[-1]["last"]).total_seconds() <= HAL_CLUSTER_S:
            out[-1]["lines"].append(msg)
            out[-1]["last"] = ts
        else:
            out.append({"ts": ts, "last": ts, "lines": [msg]})
    return out


def describe_cad(c):
    """One coreaudiod overload burst: (count, text)."""
    lines = c["lines"]
    n_thread = sum("HALthreadID:" in x for x in lines)
    n_io = sum("Audio IO Overload thread" in x for x in lines)
    count = max(1, n_thread, n_io)
    joined = " ".join(lines)
    known = n_thread or n_io or "HALS_OverloadMessage" in joined or '"overload_type"' in joined
    if not known:
        return count, "coreaudiod overload text: " + SRC_PREFIX_RE.sub("", lines[0])[:110]
    causes = []
    for x in CAUSE_CARC_RE.findall(joined):
        for t in x.split(","):
            if t.strip() and t.strip() not in causes:
                causes.append(t.strip())
    if not causes:
        for x in lines:
            g = CAUSE_TEXT_RE.search(x)
            if g and g.group(1) not in causes:
                causes.append(g.group(1))
    text = "coreaudiod overload" + (" x%d" % count if count > 1 else "")
    otypes = [t for t in OTYPE_RE.findall(joined) if t and t != "Overload"]
    if otypes:
        text += " type " + ",".join(sorted(set(otypes)))
    if causes:
        text += ": " + ", ".join(causes)
    cl, bu = CLIENT_RE.search(joined), BUDGET_RE.search(joined)
    if cl and bu:
        text += "; HAL client %.1f ms vs budget %.1f ms" % (int(cl.group(1)) / 1e6, int(bu.group(1)) / 1e6)
    tr = TRANSPORT_RE.search(joined)
    if tr and tr.group(1):
        text += "; out " + tr.group(1)
    return count, text


def describe_deci_hal(c):
    """Deci-process HAL lines in one burst: (count, abandoned, text)."""
    parts = collections.OrderedDict()
    abandoned = 0
    for x in c["lines"]:
        g = ABANDON_RE.search(x)
        if g:
            abandoned += 1
            key = "abandoned IO cycle (%s) on %s" % (g.group(2), g.group(1))
        else:
            key = SRC_PREFIX_RE.sub("", x)[:110]
        parts[key] = parts.get(key, 0) + 1
    text = "; ".join(k if n == 1 else "%s x%d" % (k, n) for k, n in parts.items())
    return len(c["lines"]), abandoned, "Deci HAL: " + text


# ---------------------------------------------------------------- report

def sec(ts):
    return ts.replace(microsecond=0)


def minute(ts):
    return ts.replace(second=0, microsecond=0)


def fmt_count(n):
    return "." if not n else str(n)


def build(m):
    """Derives per-second suspects, per-minute rows and stats from the model."""
    s = {}
    route_secs = sorted(set(sec(t) for t, _ in m.routes) | set(sec(t) for t, _ in m.streams))

    def near_route(x):
        best = None
        for r in route_secs:
            d = (x - r).total_seconds()
            if abs(d) <= NEAR_ROUTE_S and (best is None or abs(d) < abs(best)):
                best = d
        return best

    suspects = collections.defaultdict(list)   # second -> [(score, kind, text)]
    rows = collections.defaultdict(lambda: {
        "drop": 0, "disc": 0, "stall": 0, "halD": 0, "halC": 0, "retx": [], "spk": 0,
        "flush": 0, "notes": set(), "event": False})

    # Deci [GLITCH]
    by_app = collections.defaultdict(lambda: [0, set(), []])   # dropouts, seconds, loads
    tot_drop = tot_disc = tot_stall = 0
    loads = []
    for ts, g in m.glitches:
        row = rows[minute(ts)]
        row["event"] = True
        parts = []
        if g["dropouts"] is not None:
            row["drop"] += g["dropouts"]
            tot_drop += g["dropouts"]
            if g["dropouts"]:
                by_app[g["app"]][0] += g["dropouts"]
                by_app[g["app"]][1].add(sec(ts))
                if g["load"] is not None:
                    by_app[g["app"]][2].append(g["load"])
            p = "dropouts %+d" % g["dropouts"]
            if g["latest_ms"] is not None:
                p += " (latest %.1f ms)" % g["latest_ms"]
            parts.append(p)
        if g["disc"] is not None:
            row["disc"] += g["disc"]
            tot_disc += g["disc"]
            parts.append("disc %+d" % g["disc"])
        if g["stalled"] is not None:
            n = max(1, g["stalled"])
            row["stall"] += n
            tot_stall += n
            parts.append("stalled %d" % g["stalled"])
        if g["devices"]:
            parts.append("on " + g["devices"])
        if g["load"] is not None:
            loads.append(g["load"])
            parts.append("load %.2f" % g["load"])
        head = "Deci " + g["app"] + (" pid " + g["pid"] if g["pid"] else "")
        suspects[sec(ts)].append((1000 + (g["dropouts"] or 0), "deci", head + ": " + " ".join(parts)))

    # HAL
    cad_events = deci_hal_events = deci_abandoned = 0
    cad_causes = collections.OrderedDict()
    for c in cluster(m.hal["coreaudiod"]):
        n, text = describe_cad(c)
        cad_events += n
        for x in text.split(": ", 1)[1].split(";")[0].split(", ") if ": " in text else []:
            cad_causes[x] = 1
        rows[minute(c["ts"])]["halC"] += n
        rows[minute(c["ts"])]["event"] = True
        suspects[sec(c["ts"])].append((1000, "hal", text))
    for c in cluster(m.hal["Deci"]):
        n, ab, text = describe_deci_hal(c)
        deci_hal_events += n
        deci_abandoned += ab
        rows[minute(c["ts"])]["halD"] += n
        rows[minute(c["ts"])]["event"] = True
        suspects[sec(c["ts"])].append((1000, "hal" if n > ab else "abandon", text))

    # BT overwaits
    for ts, ms in m.overwaits:
        rows[minute(ts)]["notes"].add("ovw")
        rows[minute(ts)]["event"] = True
        suspects[sec(ts)].append((900, "ovw", "BT overwait %s ms (bluetoothd waited on late audio)"
                                  % (ms if ms is not None else "?")))

    # BT link quality
    base_rate = {}
    for x in m.lqr:
        base_rate[x["handle"]] = max(base_rate.get(x["handle"], 0), x["rate"])
    handles = sorted(base_rate)
    worst = {}   # (second, handle) -> sample
    for x in m.lqr:
        rows[minute(x["ts"])]["retx"].append(x["retx_pct"])
        k = (sec(x["ts"]), x["handle"])
        if k not in worst or x["retx_pct"] > worst[k]["retx_pct"]:
            worst[k] = x
    spike_secs = set()
    reasons = collections.Counter()
    heard = 0
    for (second, handle), x in sorted(worst.items()):
        why = []
        if x["retx_pct"] >= SPIKE_RETX:
            why.append("retx")
        if x["flush"] + x["flush2"] > 0:
            why.append("flush")
        if x["rate"] < base_rate[handle]:
            why.append("rate")
        row = rows[minute(second)]
        row["flush"] += x["flush"] + x["flush2"]
        if not why:
            continue
        for w in why:
            reasons[w] += 1
        if x["retx_pct"] >= HEARD_RETX:
            heard += 1
        spike_secs.add(second)
        row["spk"] += 1
        row["event"] = True
        text = "BT %.1f%% (%d/%d) nak %d nosync %d rssi %d" % (
            x["retx_pct"], x["retx"], x["tot"], x["nak"], x["nosync"], x["rssi"])
        if x["flush"] or x["flush2"]:
            text += " flush %d/%d" % (x["flush"], x["flush2"])
        if "rate" in why:
            text += " rate %d<%d kbps" % (x["rate"], base_rate[handle])
        if x["flowoff"]:
            text += " flowoff %d" % x["flowoff"]
        if len(handles) > 1:
            text += " h" + handle
        score = x["retx_pct"] + (50 if "flush" in why else 0) + (50 if "rate" in why else 0)
        suspects[second].append((score, "bt", text))

    # Route and Deci context
    for ts, _ in m.routes:
        rows[minute(ts)]["notes"].add("route")
        rows[minute(ts)]["event"] = True
    for ts, text in m.streams:
        rows[minute(ts)]["notes"].add("a2dp+" if "started" in text else "a2dp-")
        rows[minute(ts)]["event"] = True
    for ts, msg in m.deci_context:
        tag = "iobuf"
        for t, name in (("[WATCHDOG]", "wd"), ("[RESCUE]", "rescue"), ("[CROSSFADE]", "xfade")):
            if t in msg:
                tag = name
        rows[minute(ts)]["notes"].add(tag)
        rows[minute(ts)]["event"] = True

    event_secs = set()
    for second, items in suspects.items():
        if any(k in ("deci", "hal", "abandon") for _, k, _ in items):
            event_secs.add(second)
    coincide = set()
    for second in spike_secs:
        for e in event_secs:
            if abs((second - e).total_seconds()) <= COINCIDE_S:
                coincide.add(second)
                break
    near_abandon = 0
    for second, items in suspects.items():
        if near_route(second) is not None:
            near_abandon += sum(1 for _, k, _ in items if k in ("abandon", "hal"))

    s.update(
        suspects=suspects, rows=rows, near_route=near_route, handles=handles, base_rate=base_rate,
        spike_secs=spike_secs, reasons=reasons, heard=heard, coincide=coincide, event_secs=event_secs,
        by_app=by_app, tot_drop=tot_drop, tot_disc=tot_disc, tot_stall=tot_stall, loads=loads,
        cad_events=cad_events, cad_causes=list(cad_causes), deci_hal_events=deci_hal_events,
        deci_abandoned=deci_abandoned, near_abandon=near_abandon,
    )
    return s


def context_lines(m, tfmt):
    items = []
    groups = []
    for ts, text in sorted(m.routes):
        if groups and (ts - groups[-1][0]).total_seconds() <= 1.0:
            if text not in groups[-1][1]:
                groups[-1][1].append(text)
        else:
            groups.append((ts, [text]))
    for ts, texts in groups:
        items.append((ts, "route: " + "; ".join(texts)))
    for ts, text in m.streams:
        items.append((ts, "BT: " + text))
    for ts, msg in m.deci_context:
        items.append((ts, "Deci: " + (msg if len(msg) <= 150 else msg[:147] + "...")))
    items.sort(key=lambda x: x[0])
    merged = []   # [ts, text, count]
    for ts, text in items:
        if merged and merged[-1][1] == text and (ts - merged[-1][0]).total_seconds() <= 60:
            merged[-1][2] += 1
        else:
            merged.append([ts, text, 1])
    cut = max(0, len(merged) - CONTEXT_CAP)
    out = []
    for ts, text, n in merged[cut:]:
        out.append("%s %s%s" % (ts.strftime(tfmt), text, "" if n == 1 else " (x%d)" % n))
    return out, cut


def pattern_lines(m, s):
    out = []
    n_spk = len(s["spike_secs"])
    alone = n_spk - len(s["coincide"])
    any_event = n_spk or m.glitches or s["cad_events"] or s["deci_hal_events"] or m.overwaits
    if not any_event:
        bt = ("no BT LQR seconds (no A2DP stream)" if not m.lqr
              else "BT ReTx stayed under %d%% with no flushes or rate drops" % SPIKE_RETX)
        out.append("No suspect events: %s, no Deci [GLITCH] lines, no HAL overloads. If a crackle was "
                   "heard in this window none of these sources saw it: widen the window, or the cause "
                   "is outside them (the source audio itself, the speaker)." % bt)
        return out
    if n_spk:
        worst = max(m.lqr, key=lambda x: x["retx_pct"]) if m.lqr else None
        line = ("BT link: %d spike seconds, %d with no Deci or HAL event within %d s; %d at >= %d%% "
                "(the level that matched heard crackles before)" % (n_spk, alone, COINCIDE_S, s["heard"], HEARD_RETX))
        if worst:
            line += ", worst %.1f%% at %s" % (worst["retx_pct"], worst["ts"].strftime("%H:%M:%S"))
        line += (". Rule: BT spikes with no Deci or HAL events point to the Bluetooth link "
                 "(RF retransmits, range, interference), not Deci or system load.")
        if not m.glitches:
            line += (" No [GLITCH] lines at all in the window, so this only clears Deci if the "
                     "running build logs them.")
        out.append(line)
    if s["coincide"]:
        out.append("Mixed: %d BT spike seconds sit within %d s of a Deci or HAL event; read those "
                   "seconds first." % (len(s["coincide"]), COINCIDE_S))
    max_load = (" (load up to %.2f)" % max(s["loads"])) if s["loads"] else ""
    for app, (n, secs, app_loads) in sorted(s["by_app"].items(), key=lambda x: -x[1][0]):
        who = "Chrome" if "chrome" in app.lower() else app
        out.append("Deci dropouts in %s: %d over %d s%s. Rule: exact-zero gaps cutting into the app's "
                   "own audio mean %s starved upstream, not Deci's tap or the BT link."
                   % (app, n, len(secs), (" (load up to %.2f)" % max(app_loads)) if app_loads else "", who))
    if s["tot_disc"]:
        out.append("Deci tap discontinuities: %d%s. Rule: skipped IO cycles on Deci's tap point to "
                   "Deci's IO thread or system load; check load= and HAL overloads at the same seconds."
                   % (s["tot_disc"], max_load))
    if s["tot_stall"]:
        out.append("Deci music stalls: %d. Rule: Deci's own player ran dry (decode or network); heard "
                   "as a gap in Deci music only." % s["tot_stall"])
    real_hal = s["cad_events"] + s["deci_hal_events"] - s["deci_abandoned"]
    if real_hal:
        causes = ("; causes " + ", ".join(s["cad_causes"])) if s["cad_causes"] else ""
        out.append("HAL overloads: coreaudiod %d, Deci process %d%s. Rule: overloads point to system "
                   "load or an IO thread that blew its cycle budget (page faults, a slow HAL client)."
                   % (s["cad_events"], s["deci_hal_events"] - s["deci_abandoned"], causes))
    if s["deci_abandoned"]:
        out.append("Abandoned IO cycles in Deci: %d (Deci/HAL events within %d s of a route change: %d). "
                   "Rule: a cycle abandoned for a pending reconfig is a device-switch transient, "
                   "expected once per switch, not a steady-state crackle."
                   % (s["deci_abandoned"], NEAR_ROUTE_S, s["near_abandon"]))
    if m.overwaits:
        near = sum(1 for ts, _ in m.overwaits if s["near_route"](sec(ts)) is not None)
        out.append("BT overwaits: %d (%d within %d s of a route change). Rule: audio reached bluetoothd "
                   "late; right after a stream start it is a startup transient, otherwise check HAL "
                   "overloads and load at that second." % (len(m.overwaits), near, NEAR_ROUTE_S))
    return out


def render(m, start, end, source):
    s = build(m)
    multi_day = bool(start and end and start.date() != end.date())
    tfmt = "%m-%d %H:%M:%S" if multi_day else "%H:%M:%S"
    mfmt = "%m-%d %H:%M" if multi_day else "%H:%M"
    out = []
    if start and end:
        mins = (end - start).total_seconds() / 60.0
        win = "%s to %s (%s min)" % (start.strftime("%Y-%m-%d %H:%M:%S"),
                                     end.strftime("%Y-%m-%d %H:%M:%S" if multi_day else "%H:%M:%S"),
                                     ("%.0f" % mins) if mins >= 1 else ("%.1f" % mins))
    else:
        win = "whole file (no timestamped lines)"
    out.append("== glitch-report: %s, source: %s" % (win, source))
    out.append("Deci : %d [GLITCH] lines (dropouts %d, discontinuities %d, music stalls %d); %d context lines"
               % (len(m.glitches), s["tot_drop"], s["tot_disc"], s["tot_stall"], len(m.deci_context)))
    if m.lqr:
        avg = sum(x["retx_pct"] for x in m.lqr) / len(m.lqr)
        worst = max(m.lqr, key=lambda x: x["retx_pct"])
        rates = ", ".join("h%s %d kbps" % (h, s["base_rate"][h]) for h in s["handles"])
        out.append("BT   : %d LQR lines (%s); ReTx avg %.1f%%, max %.1f%% at %s"
                   % (len(m.lqr), rates, avg, worst["retx_pct"], worst["ts"].strftime(tfmt)))
        r = s["reasons"]
        out.append("       %d spike seconds (ReTx>=%d%%: %d, flush: %d, rate drop: %d); %d at >=%d%%; overwaits %d%s"
                   % (len(s["spike_secs"]), SPIKE_RETX, r["retx"], r["flush"], r["rate"], s["heard"], HEARD_RETX,
                      len(m.overwaits), "; %d LQR lines did not parse" % m.lqr_unparsed if m.lqr_unparsed else ""))
    else:
        out.append("BT   : no A2DP LinkQualityReport lines (no A2DP stream in window); overwaits %d%s"
                   % (len(m.overwaits), "; %d LQR lines did not parse" % m.lqr_unparsed if m.lqr_unparsed else ""))
    out.append("HAL  : coreaudiod overloads %d; Deci process %d (abandoned cycles %d)"
               % (s["cad_events"], s["deci_hal_events"], s["deci_abandoned"]))
    out.append("Route: %d output default changes, %d A2DP stream start/stop" % (len(m.routes), len(m.streams)))

    out.append("")
    rows = [(k, v) for k, v in sorted(s["rows"].items()) if v["event"]]
    if rows:
        out.append("per minute (rows with an event; '.' = 0, '-' = no BT data; halD/halC = HAL events in Deci/coreaudiod; bt = ReTx %):")
        mw = 11 if multi_day else 7
        out.append("%-*s drop disc stall halD halC btMax btAvg  spk flush notes" % (mw, "minute"))
        for k, v in rows:
            if v["retx"]:
                bmax = "%5.1f" % max(v["retx"])
                bavg = "%5.1f" % (sum(v["retx"]) / len(v["retx"]))
            else:
                bmax = bavg = "    -"
            out.append(("%-*s %4s %4s %5s %4s %4s %s %s %4s %5s %s" % (
                mw, k.strftime(mfmt), fmt_count(v["drop"]), fmt_count(v["disc"]), fmt_count(v["stall"]),
                fmt_count(v["halD"]), fmt_count(v["halC"]), bmax, bavg, fmt_count(v["spk"]),
                fmt_count(v["flush"]), ",".join(sorted(v["notes"])))).rstrip())
    else:
        out.append("per minute: no minute with an event")

    out.append("")
    sus = s["suspects"]
    if sus:
        ranked = sorted(sus.items(), key=lambda kv: -max(x[0] for x in kv[1]))
        kept, cut = ranked[:SUSPECT_CAP], ranked[SUSPECT_CAP:]
        out.append("suspect seconds (%d; BT = ReTx%% (retx/total) nak nosync rssi, flush/rate/flowoff only when abnormal):"
                   % len(sus))
        for second, items in sorted(kept, key=lambda kv: kv[0]):
            items = sorted(items, key=lambda x: -x[0])
            line = "%s %s" % (second.strftime(tfmt), " | ".join(t for _, _, t in items))
            d = s["near_route"](second)
            if d is not None:
                line += " [route change %+ds]" % d
            out.append(line)
        if cut:
            bt_cut = [max(x[0] for x in items) for _, items in cut]
            all_bt = all(k == "bt" for _, items in cut for _, k, _ in items)
            if all_bt:
                out.append("... %d more cut: BT-only seconds with ReTx up to %.1f%%"
                           % (len(cut), max(bt_cut)))
            else:
                out.append("... %d more cut (lowest severity)" % len(cut))
    else:
        out.append("suspect seconds: none")

    ctx, ctx_cut = context_lines(m, tfmt)
    if ctx:
        out.append("")
        out.append("context (route changes, A2DP stream, Deci [WATCHDOG]/[RESCUE]/[CROSSFADE]/IO buffer)%s:"
                   % (" (%d earlier cut)" % ctx_cut if ctx_cut else ""))
        out.extend(ctx)

    out.append("")
    out.append("pattern:")
    out.extend("- " + x for x in pattern_lines(m, s))
    return out


# ---------------------------------------------------------------- main

def parse_time(text, p, flag):
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"):
        try:
            return dt.datetime.strptime(text.strip(), fmt)
        except ValueError:
            pass
    p.error('%s wants "YYYY-MM-DD HH:MM[:SS]", got %r' % (flag, text))


def parse_duration(text, p):
    g = re.match(r"^\s*(\d+(?:\.\d+)?)\s*([smhd]?)\s*$", text)
    if not g:
        p.error("--last wants a duration like 90s, 30m, 2h or 1d, got %r" % text)
    mult = {"s": 1, "m": 60, "h": 3600, "d": 86400, "": 60}[g.group(2)]
    return dt.timedelta(seconds=float(g.group(1)) * mult)


def run_log_show(start, end):
    cmd = [LOG_BIN, "show", "--style", "syslog", "--info",
           "--start", start.strftime("%Y-%m-%d %H:%M:%S"), "--end", end.strftime("%Y-%m-%d %H:%M:%S"),
           "--predicate", PREDICATE]
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=1800)
    except FileNotFoundError:
        sys.stderr.write("glitch-report: %s not found (macOS only)\n" % LOG_BIN)
        sys.exit(2)
    except subprocess.TimeoutExpired:
        sys.stderr.write("glitch-report: log show timed out; try a shorter window\n")
        sys.exit(2)
    if proc.returncode != 0:
        sys.stderr.write("glitch-report: log show failed (%d): %s\n"
                         % (proc.returncode, proc.stderr.decode("utf-8", "replace").strip()))
        sys.exit(2)
    return proc.stdout.decode("utf-8", "replace")


def main(argv=None):
    p = argparse.ArgumentParser(
        prog="glitch-report.py",
        description="Line up Deci [GLITCH] lines, Bluetooth A2DP link quality, CoreAudio overloads and "
                    "output route changes for a window of the unified log.")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--last", metavar="DUR", help="window ending now: 90s, 30m, 2h, 1d (default 30m)")
    g.add_argument("--start", metavar="TIME", help='window start, "YYYY-MM-DD HH:MM[:SS]" local time')
    p.add_argument("--end", metavar="TIME", help="window end (default now, or the file's last line)")
    p.add_argument("--from-file", metavar="PATH", help="parse saved log show text instead of calling log show")
    p.add_argument("--verbose", action="store_true", help="also print every matching raw line")
    a = p.parse_args(argv)
    if a.end and not a.start:
        p.error("--end needs --start")
    if a.from_file and a.last:
        p.error("--last reads the live log; use --start/--end to narrow --from-file")

    start = parse_time(a.start, p, "--start") if a.start else None
    end = parse_time(a.end, p, "--end") if a.end else None
    if a.from_file:
        try:
            with open(a.from_file, "r", encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError as e:
            p.error("cannot read %s: %s" % (a.from_file, e))
        source = "file " + a.from_file
    else:
        now = dt.datetime.now().replace(microsecond=0)
        if start is None:
            start = now - parse_duration(a.last or "30m", p)
        if end is None:
            end = now
        source = "log show"
    if start and end and end <= start:
        p.error("--end must be after --start")
    if not a.from_file:
        text = run_log_show(start, end)

    recs = parse_text(text)
    if a.from_file:
        if start:
            recs = [r for r in recs if r.ts >= start]
        if end:
            recs = [r for r in recs if r.ts <= end]
        if recs:
            start = start or sec(recs[0].ts)
            end = end or sec(recs[-1].ts)
    m = Model()
    for r in recs:
        classify(r, m)

    out = render(m, start, end, source)
    if a.verbose:
        out.append("")
        out.append("raw (%d matching lines; predicate: %s):" % (len(m.matched), PREDICATE))
        out.extend(r.raw for r in m.matched)
    sys.stdout.write("\n".join(out) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(0)
