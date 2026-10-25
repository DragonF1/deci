/*
 * Deci Audio Companion: service worker.
 *
 * MESSAGE CONTRACT (native host 'com.abraham.deci', chrome.runtime.connectNative).
 * Every message is a JSON object with a "type".
 *
 * Extension to app:
 *   TAB_LIST {
 *     type: "TAB_LIST",
 *     incognitoAllowed: boolean,
 *     tabs: [ {
 *       id: int,
 *       title: string,
 *       favIconUrl: string | null,   (null when missing or longer than 64 KB)
 *       incognito: boolean,
 *       isAudible: boolean,
 *       captured: boolean,           (true only for real tab capture)
 *       control: string,             one of:
 *                                      "capture"  captured (gain, EQ and device in Deci)
 *                                      "none"     not captured: plain control (the page's
 *                                                 media volume and Chrome's tab mute, see
 *                                                 TAB MODES)
 *                                    (missing means an older extension: use captured)
 *       volume: number 0..1,         (base volume, NOT multiplied by boost)
 *       boost: 1 | 2 | 3 | 4,
 *       muted: boolean,              (captured ? Deci gain mute : Chrome tab mute)
 *       eqBands: [10 numbers, dB],
 *       deviceName: string,          ("" means system default; a CoreAudio device name)
 *       deviceNames: [string],       the outputs of a tab in multi-output mode (see
 *                                    SET_TAB_DEVICES); [] for a tab on one output. Missing
 *                                    means an older extension: the app reads it as []. While
 *                                    it is not empty it replaces deviceName; deviceName keeps
 *                                    the last single choice so SET_TAB_DEVICE can restore it.
 *       deviceMissing: [string],     the names in deviceNames that matched no output while
 *                                    captured (skipped, the tab plays on the others); [] when
 *                                    not captured or when every name matched
 *       deviceStatus: string         one of:
 *                                      "default"  no device chosen (system default output)
 *                                      "pending"  a device is chosen, tab not captured yet
 *                                      "routed"   captured and playing on the chosen device,
 *                                                 or in multi mode on at least one chosen device
 *                                      "notFound" captured, no output matches (in multi mode:
 *                                                 none of the names), playing on system default
 *                                                 meanwhile
 *                                      "noAccess" captured, device labels unreadable
 *                                                 (mic permission missing), playing on default
 *                                    (app treats unknown or missing values as "default")
 *     } ],
 *     multiDevice: true,             this extension understands SET_TAB_DEVICES (1.8.0 and
 *                                    later). Missing means an older extension: the app then
 *                                    sends only SET_TAB_DEVICE.
 *     deviceAccess: boolean,         true when the extension origin may read output
 *                                    device labels (mic permission granted). Missing
 *                                    means an older extension: app treats it as true.
 *     tracking: { tabs: boolean, incognito: boolean }
 *                                    echo of the tracking switch the app last set on this
 *                                    port (see SET_TRACKING and TRACKING below). tabs is []
 *                                    when tracking.tabs is false; tabs with incognito: true
 *                                    are left out when tracking.incognito is false. Missing
 *                                    while the gate is closed (a new native port that has
 *                                    not yet sent SET_TRACKING): tabs is [] then too, and
 *                                    the app answers a missing echo with SET_TRACKING.
 *   }
 *   MEDIA_STATE { type: "MEDIA_STATE", tabId: int, paused: boolean,
 *                 currentTime: number, duration: number }
 *     (sent only when the page has a media element, and never for a tab hidden by
 *     the tracking switch or while the gate is closed)
 *
 * App to extension:
 *   GET_TABS {}                              reply with a TAB_LIST push
 *   SET_TAB_VOLUME { tabId, volume, boost }  volume 0..1, boost 1..4. Captured: the graph plays
 *                                            at volume * boost. Not captured: the plain level is
 *                                            volume (clamped to 0..1); boost is stored but ignored
 *                                            until a capture uses it (see TAB MODES)
 *   SET_TAB_MUTE { tabId, muted }            captured: the Deci gain mute (Chrome's tab mute stays
 *                                            off). Not captured: Chrome's tab mute
 *   SET_TAB_EQ { tabId, eqBands }            10 numbers in dB
 *   SET_TAB_DEVICE { tabId, deviceName }     "" = system default; applied with
 *                                            AudioContext.setSinkId while captured,
 *                                            stored and applied when capture starts.
 *                                            Ends multi-output mode for the tab.
 *   SET_TAB_DEVICES { tabId, deviceNames }   multi-output: one tab plays on every named
 *                                            device at once (at most 8, duplicates and
 *                                            empty names dropped), one AudioContext with
 *                                            its own setSinkId per device, all fed by the
 *                                            same capture. A list with no usable name is
 *                                            ignored (the tab stays where it is). Names
 *                                            that match no output are skipped (see
 *                                            deviceMissing); when none matches the tab
 *                                            plays on the system default. Volume, boost,
 *                                            mute and EQ apply to every output alike.
 *                                            Stored and applied when capture starts.
 *   OPEN_DEVICE_PERMISSION {}                open (or focus) permissions.html so the
 *                                            user can grant the one-time mic prompt
 *   TOGGLE_PLAYBACK { tabId }
 *   GET_MEDIA_STATE { tabId }                reply with one MEDIA_STATE (nothing for a
 *                                            hidden tab or while the gate is closed, see
 *                                            TRACKING)
 *   SET_TRACKING { tabs, incognito }         booleans: what the extension may report.
 *                                            Stored when the value changed, and it opens
 *                                            the gate of the current port. A fresh
 *                                            TAB_LIST follows when the value changed or
 *                                            the gate just opened. One boolean alone
 *                                            changes only that field; a message with no
 *                                            boolean field is ignored.
 *   SET_OPTIONS { ytmAutoSwitch }            boolean: ytm-switch.js clicks "Switch" on
 *                                            YouTube Music's "Listen on this device?"
 *                                            dialog. Stored when the value changed; the
 *                                            app restates it with every GET_TABS.
 *   SET_TAP_LATENCY { devices }              no tabId. devices: [ { deviceName: string,
 *                                            seconds: number } ], the delay the app's own
 *                                            Core Audio tap adds to each output it taps,
 *                                            measured by the app (deviceName is the Core
 *                                            Audio device name, as in SET_TAB_DEVICES).
 *                                            Multi-output mode adds it to that output's
 *                                            latency when it lines the outputs up, so the
 *                                            other outputs wait for it. Every message
 *                                            replaces the previous one; devices: [] means
 *                                            no tap latency anywhere. Entries need a
 *                                            non-blank string deviceName and finite seconds
 *                                            from 0 to 0.5; others are dropped, and at
 *                                            most 8 are kept. Kept in memory and in
 *                                            session storage, and sent on to the offscreen
 *                                            document, again whenever it is created or a
 *                                            capture starts or is reconciled.
 *
 * TAB MODES. A tab is On or Off, nothing in between.
 *   On, control "capture": the toolbar click (or its shortcut) captured the tab (tabCapture and the
 *     offscreen graph). Volume, boost, mute, EQ and output devices are all Deci's. The plain level of
 *     its frames is 1, so the page plays at its own level into the capture.
 *   Off, control "none": not captured. Plain control only, with no click, no AudioContext and no
 *     audio graph: the media elements of every frame play at the page's own volume times the tab's
 *     plain level, clamp(volume, 0, 1) (plain-volume.js), and mute is Chrome's tab mute. Boost, EQ and
 *     devices are only stored, for a later capture. Audio that does not come from a media element
 *     (Web Audio), and pages content scripts cannot reach (chrome:// pages, the Web Store), get mute
 *     only.
 *   Switching never makes a tab louder for a moment. A capture start sends level 1 only once the
 *   graph is live (until then the plain level scales the capture too, so the tab is only quieter). A
 *   stop sends the plain level before the capture is released. A capture that ended on its own
 *   (CAPTURE_ENDED, the offscreen document gone) is released before the worker hears of it, so its
 *   plain level follows as soon as it does.
 *
 * TRACKING. The app can switch off what the extension reports about tabs. A tab is
 * HIDDEN when tracking.tabs is false, or when tracking.incognito is false and the tab is
 * incognito. A hidden tab is left out of TAB_LIST and gets no MEDIA_STATE, so its title,
 * URL and favicon never leave Chrome. TAB_LIST is still sent while everything is hidden
 * (with tabs: []), so the app sees the tracking echo and the connection stays alive; the
 * app resends SET_TRACKING when the echo differs from what it wants. Tracking changes only
 * what is reported: capture, badges and per-tab volume, boost, EQ and device work
 * exactly as before, and SET_TAB_* commands are still honored.
 *
 * PRIVACY GATE. The stored switch can be stale, so it never decides what a new connection
 * hears. Every new native port (and every worker start) begins with the gate CLOSED: all
 * tabs count as hidden, so TAB_LIST goes out with tabs: [] and without the tracking echo,
 * and MEDIA_STATE posts nothing. The app treats the missing echo as a mismatch and answers
 * with SET_TRACKING (it also sends SET_TRACKING before every GET_TABS). A valid
 * SET_TRACKING opens the gate for the port it arrived on and pushes a fresh TAB_LIST with
 * the real tabs and the echo. A reconnect makes a new port, which closes the gate again.
 * The stored value, or the default { tabs: true, incognito: false } when nothing is stored,
 * only fills in the field a one-boolean SET_TRACKING leaves out and tells whether a
 * SET_TRACKING changed anything.
 *
 * Service worker <-> offscreen document messages carry target 'offscreen' or
 * target 'background'; each side ignores messages not addressed to it.
 *   to offscreen:  START_CAPTURE { tabId, streamId, volume, boost, muted, eqBands, deviceName,
 *                                  deviceNames }
 *                  SET_STATE { tabId, volume, boost, muted, eqBands, deviceName, deviceNames }
 *                                    (a changed deviceName or deviceNames re-resolves that
 *                                     capture's sinks: outputs are added and removed without
 *                                     restarting the capture)
 *                  STOP_CAPTURE { tabId }
 *                  SET_TAP_LATENCY { devices }  global (no tabId), as from the app, already
 *                                      sanitized; the offscreen document sanitizes again.
 *                                      Replaces its list and re-runs output alignment
 *                                      under the usual tolerance and timing rules
 *                  LIST_CAPTURES {}  (response: array of captured tab ids)
 *                  RESOLVE_DEVICES {}  re-check label access and re-resolve every capture,
 *                                      reporting DEVICE_ACCESS and each DEVICE_STATUS even
 *                                      when unchanged (sent when deviceAccess flips, and
 *                                      after adopting captures the worker did not know)
 *   to background: CAPTURE_ENDED { tabId }
 *                  DEVICE_STATUS { tabId, status, missing }
 *                                                    status as in TAB_LIST deviceStatus
 *                                                    ("routed" | "notFound" | "noAccess" | "default"),
 *                                                    missing: [string], the deviceNames that
 *                                                    matched no output (absent from an older
 *                                                    offscreen document: read as [])
 *                                                    sent when either changes for a capture, and
 *                                                    always first after a device change
 *                  DEVICE_ACCESS { granted }         from offscreen (labels readable or not)
 *                                                    and from permissions.html (prompt result)
 *
 * Service worker <-> content script messages (plain control, see TAB MODES). They carry no target
 * field. Only this extension's content scripts in a tab (sender.id is this extension, sender.tab
 * set) are answered.
 *   to background: PLAIN_HELLO {}   from plain-bridge.js in every frame when it loads, and again
 *                                   when its page comes back from the back/forward cache or a
 *                                   prerendered page is shown. Reply { factor }: the plain level
 *                                   of sender.tab.id, the last one this worker sent to the tab,
 *                                   else the stored state's (1 with no state yet)
 *   to every frame of a tab (chrome.tabs.sendMessage):
 *                  PLAIN_VOLUME { factor }  factor 0..1, sent when the tab's plain level changes
 *                                   (an uncaptured volume change, a capture start or end), never
 *                                   when it did not. Reply { ok: true }. When no frame answers (a
 *                                   tab open from before the extension loaded, or one whose copies
 *                                   an extension reload cut off) both scripts are injected into it,
 *                                   once per tab and worker start, and the level is sent again.
 *                                   The first worker start of a session (storage.session empty,
 *                                   as after an extension reload or update) also sends every open
 *                                   tab its level once, so no page keeps a level from before
 *   plain-bridge.js to plain-volume.js (page world): CustomEvent '__deci_plain_volume__' on
 *                  document, detail = the factor. One way only: the page world script never sends
 *                  anything to the extension.
 *   Plain level: captured ? 1 : clamp(volume, 0, 1).
 *
 * Device resolution (offscreen): enumerateDevices() 'audiooutput', skipping the
 * 'default' and 'communications' pseudo entries; match deviceName against label:
 * exact, then label starting with deviceName + " (", then case-insensitive contains.
 * Re-resolved for every capture on navigator.mediaDevices 'devicechange'. No match or
 * no labels: setSinkId('') and report "notFound" / "noAccess". A multi-output capture
 * resolves each name the same way: names that match are played on (one AudioContext and
 * sink per distinct output), names that do not are reported as missing and skipped.
 *
 * STORAGE
 *   chrome.storage.session  'tab:<id>'  -> { volume, boost, muted, eqBands, deviceName,
 *                                            deviceNames, deviceMissing, deviceStatus,
 *                                            captured }
 *   chrome.storage.local    'tracking' -> { tabs: boolean, incognito: boolean }
 *                           (written by SET_TRACKING only when the value changed; default
 *                           both true; read at worker start to merge a one-boolean
 *                           SET_TRACKING; never decides what a new port is told, see
 *                           PRIVACY GATE)
 *   chrome.storage.local    'options' -> { ytmAutoSwitch: boolean }
 *                           (written by SET_OPTIONS only when the value changed; read by
 *                           ytm-switch.js, which treats a missing value as true)
 *   chrome.storage.local    'deviceAccess' -> boolean (last known; default false)
 *   chrome.storage.session  'tapLatency' -> [ { deviceName, seconds } ] (the last SET_TAP_LATENCY,
 *                           sanitized; restored at worker start so a restart keeps it)
 *   chrome.storage.session  'knownTabs' -> [tab ids that were audible this session]
 *   chrome.storage.local    'siteDefaults' -> { hostname: { volume, boost } }
 *                           (only volume is applied, when capture starts)
 *     Written on volume or boost changes of a captured, non-incognito tab.
 *     Read when a tab with no per-tab state yet starts capture.
 *     Never applied on reload or navigation, never stores mute.
 */

const NATIVE_HOST = 'com.abraham.deci';
const RECONNECT_ALARM = 'deci-reconnect';
const LEGACY_ALARM = 'reconnect';
const EQ_BAND_COUNT = 10;
const EQ_LIMIT_DB = 30;
const MAX_FAVICON_LENGTH = 64 * 1024;
const TAB_LIST_BUDGET = 900 * 1024;
const PUSH_DEBOUNCE_MS = 150;
const SITE_WRITE_DEBOUNCE_MS = 500;
const RETRY_MIN_MS = 1000;
const RETRY_MAX_MS = 30000;
const STABLE_CONNECTION_MS = 5000;
const MIN_SITE_VOLUME = 0.05;
const BADGE_COLOR = '#4688F1';
const TITLE_OFF = "Deci: click to control this tab's audio";
const TITLE_ON = 'Deci: controlling this tab (click to stop)';
const YTM_SWITCH_FILE = 'ytm-switch.js';
const YTM_URL_PATTERN = 'https://music.youtube.com/*';
const PLAIN_VOLUME_FILE = 'plain-volume.js'; // page world (see TAB MODES)
const PLAIN_BRIDGE_FILE = 'plain-bridge.js'; // isolated world
const PLAIN_SWEPT_KEY = 'plainSwept'; // chrome.storage.session flag, see sweepPlain()
const PLAIN_STOP_WAIT_MS = 500; // the longest a stop waits for the plain level to land
const PLAIN_SWEEP_BATCH = 8; // tabs the startup sweep reaches at once
const DEVICE_STATUSES = ['default', 'pending', 'routed', 'notFound', 'noAccess'];
const REPORTED_DEVICE_STATUSES = ['default', 'routed', 'notFound', 'noAccess'];
const MAX_DEVICE_NAMES = 8; // outputs one tab can play on at once (offscreen.js has the same cap)
const MAX_TAP_LATENCY_SECONDS = 0.5; // the most a tap latency entry may claim; a larger value is not trusted
const MAX_TAP_ENTRIES = 8; // tap latency entries kept (offscreen.js has the same cap)

// ---------------------------------------------------------------------------
// Value helpers
// ---------------------------------------------------------------------------

function clampVolume(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) return 1;
  return Math.min(1, Math.max(0, n));
}

function clampBoost(value) {
  const n = Math.round(Number(value));
  if (!Number.isFinite(n)) return 1;
  return Math.min(4, Math.max(1, n));
}

function normalizeBands(bands) {
  const out = new Array(EQ_BAND_COUNT).fill(0);
  if (!Array.isArray(bands)) return out;
  for (let i = 0; i < EQ_BAND_COUNT; i++) {
    const n = Number(bands[i]);
    if (Number.isFinite(n)) out[i] = Math.min(EQ_LIMIT_DB, Math.max(-EQ_LIMIT_DB, n));
  }
  return out;
}

// A list of output names: strings only, no empty ones, no duplicates, capped.
// Pure.
function normalizeNames(names) {
  if (!Array.isArray(names)) return [];
  const out = [];
  for (const name of names) {
    if (typeof name !== 'string' || name === '' || out.includes(name)) continue;
    out.push(name);
    if (out.length >= MAX_DEVICE_NAMES) break;
  }
  return out;
}

function sameNames(a, b) {
  return a.length === b.length && a.every((name, i) => name === b[i]);
}

// A tap latency list (SET_TAP_LATENCY): entries with a non-blank string deviceName and a finite number of seconds
// from 0 to MAX_TAP_LATENCY_SECONDS, the first MAX_TAP_ENTRIES of them, as fresh { deviceName, seconds } objects.
// Anything else is dropped. Pure.
function normalizeTapLatency(devices) {
  if (!Array.isArray(devices)) return [];
  const out = [];
  for (const device of devices) {
    if (!device || typeof device.deviceName !== 'string' || device.deviceName.trim() === '') continue;
    const seconds = device.seconds;
    if (typeof seconds !== 'number' || !Number.isFinite(seconds) || seconds < 0 || seconds > MAX_TAP_LATENCY_SECONDS) continue;
    out.push({ deviceName: device.deviceName, seconds });
    if (out.length >= MAX_TAP_ENTRIES) break;
  }
  return out;
}

function defaultState() {
  return {
    volume: 1,
    boost: 1,
    muted: false,
    eqBands: new Array(EQ_BAND_COUNT).fill(0),
    deviceName: '',
    deviceNames: [],
    deviceMissing: [],
    deviceStatus: 'default',
    captured: false
  };
}

// True when the tab has an output chosen: a multi list, else a single name.
function hasDeviceChoice(s) {
  return s.deviceNames.length > 0 || !!s.deviceName;
}

// deviceStatus before the offscreen document has reported one.
function unresolvedDeviceStatus(s) {
  return hasDeviceChoice(s) ? 'pending' : 'default';
}

// Forgets what the offscreen document last said about the tab's outputs
// (a new capture, a new choice or the end of the capture reports afresh).
function resetDeviceReport(s) {
  s.deviceStatus = unresolvedDeviceStatus(s);
  s.deviceMissing = [];
}

// deviceStatus as sent in TAB_LIST: the stored (last reported) value only
// counts while the tab is captured and a device is chosen.
function listDeviceStatus(s, captured) {
  if (!hasDeviceChoice(s)) return 'default';
  if (!captured || s.deviceStatus === 'default') return 'pending';
  return s.deviceStatus;
}

function normalizeState(raw) {
  const s = defaultState();
  if (!raw || typeof raw !== 'object') return s;
  s.volume = clampVolume(raw.volume);
  s.boost = clampBoost(raw.boost);
  s.muted = raw.muted === true;
  s.eqBands = normalizeBands(raw.eqBands);
  s.deviceName = typeof raw.deviceName === 'string' ? raw.deviceName : '';
  s.deviceNames = normalizeNames(raw.deviceNames);
  s.captured = raw.captured === true;
  s.deviceStatus = s.captured && DEVICE_STATUSES.includes(raw.deviceStatus)
    ? raw.deviceStatus : unresolvedDeviceStatus(s);
  s.deviceMissing = s.captured
    ? normalizeNames(raw.deviceMissing).filter((name) => s.deviceNames.includes(name))
    : [];
  return s;
}

// Everything the offscreen graph needs (sent in START_CAPTURE and SET_STATE).
function audioFields(s) {
  return {
    volume: s.volume,
    boost: s.boost,
    muted: s.muted,
    eqBands: s.eqBands.slice(),
    deviceName: s.deviceName,
    deviceNames: s.deviceNames.slice()
  };
}

function sameAudio(a, b) {
  return a.volume === b.volume && a.boost === b.boost && a.muted === b.muted &&
    a.deviceName === b.deviceName && sameNames(a.deviceNames, b.deviceNames) &&
    a.eqBands.every((v, i) => v === b.eqBands[i]);
}

function hostOf(url) {
  try { return new URL(url).hostname || null; } catch (e) { return null; }
}

// How Deci controls a tab: real capture, or not at all. This is the TAB_LIST
// "control" field. st may be undefined (no state yet).
function controlOf(st) {
  return st && st.captured ? 'capture' : 'none';
}

// The plain level a tab's frames get while it is not captured: its volume,
// boost ignored. st may be undefined (no state yet: the page's own level).
function uncapturedFactor(st) {
  return st ? clampVolume(st.volume) : 1;
}

// The plain level for the tab as it is now (see TAB MODES).
function plainFactor(st) {
  return st && st.captured ? 1 : uncapturedFactor(st);
}

function faviconOrNull(url) {
  return typeof url === 'string' && url.length > 0 && url.length <= MAX_FAVICON_LENGTH ? url : null;
}

function errorText(err) {
  return (err && err.message) || String(err);
}

function logError(context) {
  return (err) => console.error(`Deci: ${context}:`, errorText(err));
}

async function getTab(tabId) {
  try { return await chrome.tabs.get(tabId); } catch (e) { return null; }
}

// ---------------------------------------------------------------------------
// Tracking switch (chrome.storage.local 'tracking'), warm in memory. It only
// decides what the app is told about tabs, never how audio is handled.
//
// PRIVACY GATE. The stored value may be stale, so it never decides what a new
// native port hears. trackingConfirmed is false at worker start and again for
// every new native port (connect()); while it is false nothing counts as
// reported and the TAB_LIST carries no echo. Only a valid SET_TRACKING from the
// app opens it. Whatever reports tab data reads isReported() and `tracking`
// with no await in between, so the filter and the echo always agree.
// ---------------------------------------------------------------------------

let tracking = { tabs: true, incognito: false };
let trackingLoaded = false;
// Invariant: trackingConfirmed implies trackingLoaded (setTracking sets both).
let trackingConfirmed = false;

// Missing or malformed values fall back to the defaults: tabs shown, incognito hidden.
function normalizeTracking(raw) {
  const r = raw && typeof raw === 'object' ? raw : {};
  return { tabs: r.tabs !== false, incognito: r.incognito === true };
}

// Reads the stored value for a SET_TRACKING that carries one boolean only, and
// for the unchanged-write check. It never opens the gate.
async function loadTracking() {
  if (trackingLoaded) return;
  // A failed read throws and leaves tracking unloaded; the next call reads again.
  const stored = await chrome.storage.local.get('tracking');
  if (trackingLoaded) return; // a SET_TRACKING landed while this read was pending
  tracking = normalizeTracking(stored.tracking);
  trackingLoaded = true;
}

// Whether the app may hear about this tab (see TRACKING in the header). Nothing
// is reported until the app has confirmed the switch on the current port.
function isReported(tab) {
  return trackingConfirmed && !!tab && tracking.tabs && (!tab.incognito || tracking.incognito);
}

// SET_TRACKING: a boolean field replaces its value, anything else keeps it.
// The value is stored only when it changed. A fresh TAB_LIST follows when it
// changed or when this message opened the gate for the port it arrived on.
async function setTracking(msg) {
  const hasTabs = typeof msg.tabs === 'boolean';
  const hasIncognito = typeof msg.incognito === 'boolean';
  if (!hasTabs && !hasIncognito) return;
  const fromPort = port; // the gate belongs to this port, not to whichever is current later
  // A full message needs no stored value; a partial one starts from it.
  if (!(hasTabs && hasIncognito)) await loadTracking();
  const next = {
    tabs: hasTabs ? msg.tabs : tracking.tabs,
    incognito: hasIncognito ? msg.incognito : tracking.incognito
  };
  // Unchanged is only known once the stored value has been read.
  const unchanged = trackingLoaded && next.tabs === tracking.tabs && next.incognito === tracking.incognito;
  const opensGate = !trackingConfirmed && !!fromPort && port === fromPort;
  tracking = next;
  trackingLoaded = true;
  if (opensGate) trackingConfirmed = true;
  if (!unchanged) await chrome.storage.local.set({ tracking }).catch(logError('tracking write'));
  if (!unchanged || opensGate) schedulePush();
}

// SET_OPTIONS: stores the app's options for content scripts. Only a boolean
// ytmAutoSwitch is taken; the write happens only when the value changed.
async function setOptions(msg) {
  if (typeof msg.ytmAutoSwitch !== 'boolean') return;
  const { options } = await chrome.storage.local.get('options');
  if (options && options.ytmAutoSwitch === msg.ytmAutoSwitch) return;
  await chrome.storage.local.set({ options: { ...(options || {}), ytmAutoSwitch: msg.ytmAutoSwitch } });
}

// ---------------------------------------------------------------------------
// Per-tab state: chrome.storage.session is the source of truth, mirrored in
// an in-memory cache that is loaded (and reconciled with the offscreen
// document) the first time anything needs it after the worker wakes.
// ---------------------------------------------------------------------------

const tabKey = (tabId) => `tab:${tabId}`;

let readyPromise = null;
let storeSync = null; // same object ready() resolves to, for synchronous peeks

function ready() {
  if (!readyPromise) {
    readyPromise = (async () => {
      const all = await chrome.storage.session.get(null);
      const store = { tabs: new Map(), known: new Set() };
      for (const [key, value] of Object.entries(all)) {
        if (!key.startsWith('tab:')) continue;
        const id = Number(key.slice(4));
        if (Number.isInteger(id)) store.tabs.set(id, normalizeState(value));
      }
      if (Array.isArray(all.knownTabs)) {
        for (const id of all.knownTabs) if (Number.isInteger(id)) store.known.add(id);
      }
      // A SET_TAP_LATENCY that landed while this read was pending is newer than what was stored.
      if (!tapLatencyTouched) tapLatency = normalizeTapLatency(all.tapLatency);
      await reconcileCaptures(store, true);
      storeSync = store;
      return store;
    })().catch((err) => {
      readyPromise = null;
      throw err;
    });
  }
  return readyPromise;
}

function persistTab(tabId, state) {
  chrome.storage.session.set({ [tabKey(tabId)]: state }).catch(logError('session write'));
}

function removeTabState(store, tabId) {
  store.tabs.delete(tabId);
  chrome.storage.session.remove(tabKey(tabId)).catch(logError('session remove'));
}

function persistKnown(store) {
  chrome.storage.session.set({ knownTabs: [...store.known] }).catch(logError('session write'));
}

// ---------------------------------------------------------------------------
// Per-site defaults (chrome.storage.local), writes debounced and serialized
// ---------------------------------------------------------------------------

const pendingSiteWrites = new Map();
let siteWriteTimer = null;
let siteWriteChain = Promise.resolve();

function queueSiteDefault(host, volume, boost) {
  pendingSiteWrites.set(host, { volume, boost });
  if (siteWriteTimer) return;
  siteWriteTimer = setTimeout(() => {
    siteWriteTimer = null;
    const batch = [...pendingSiteWrites];
    pendingSiteWrites.clear();
    siteWriteChain = siteWriteChain.then(async () => {
      const { siteDefaults } = await chrome.storage.local.get('siteDefaults');
      const next = siteDefaults && typeof siteDefaults === 'object' ? siteDefaults : {};
      for (const [h, v] of batch) next[h] = v;
      await chrome.storage.local.set({ siteDefaults: next });
    }).catch(logError('siteDefaults write'));
  }, SITE_WRITE_DEBOUNCE_MS);
}

async function getSiteDefault(url) {
  const host = hostOf(url);
  if (!host) return null;
  let value = pendingSiteWrites.get(host);
  if (!value) {
    const { siteDefaults } = await chrome.storage.local.get('siteDefaults');
    value = siteDefaults && siteDefaults[host];
  }
  if (!value || typeof value !== 'object') return null;
  // Volume only: a remembered 4x boost on a loud page would jump, and a
  // remembered near-silent volume makes a new tab look broken.
  const volume = clampVolume(value.volume);
  if (volume < MIN_SITE_VOLUME) return null;
  return { volume };
}

// ---------------------------------------------------------------------------
// Offscreen document
// ---------------------------------------------------------------------------

const OFFSCREEN_URL = chrome.runtime.getURL('offscreen.html');
let creatingOffscreen = null;

async function hasOffscreen() {
  const contexts = await chrome.runtime.getContexts({
    contextTypes: ['OFFSCREEN_DOCUMENT'],
    documentUrls: [OFFSCREEN_URL]
  });
  return contexts.length > 0;
}

async function ensureOffscreen() {
  if (await hasOffscreen()) return;
  let creator = false;
  if (!creatingOffscreen) {
    creator = true;
    creatingOffscreen = chrome.offscreen.createDocument({
      url: 'offscreen.html',
      reasons: ['USER_MEDIA'],
      justification: 'Capture tab audio to apply per-tab volume, mute and EQ.'
    }).catch((err) => {
      // Lost a creation race with an earlier call: the document exists, fine.
      if (!/single offscreen/i.test(errorText(err))) throw err;
    }).finally(() => {
      creatingOffscreen = null;
    });
  }
  await creatingOffscreen;
  // A new document knows no tap latency: give it the current one. Not awaited, so it cannot hold a capture up.
  if (creator) postTapLatency();
}

async function sendToOffscreen(message) {
  try {
    return await chrome.runtime.sendMessage({ ...message, target: 'offscreen' });
  } catch (err) {
    console.warn(`Deci: offscreen ${message.type} failed:`, errorText(err));
    return undefined;
  }
}

// ---------------------------------------------------------------------------
// Tap latency (SET_TAP_LATENCY): what the app's own audio tap adds to the outputs it taps. The app measures it,
// the offscreen document adds it to the matching output when it lines the outputs up. Kept here (and in
// chrome.storage.session) so a new offscreen document or capture, or a restarted worker, still has it.
// ---------------------------------------------------------------------------

let tapLatency = [];
let tapLatencyTouched = false; // a SET_TAP_LATENCY has landed since the worker started: the stored value is older

// Sends the current tap latency to the offscreen document. Never throws and never creates the document. The value
// is read when the send is made, so a send that ran late still carries the newest one.
async function postTapLatency() {
  try {
    await sendToOffscreen({ type: 'SET_TAP_LATENCY', devices: tapLatency.map((device) => ({ ...device })) });
  } catch (err) {
    console.warn('Deci: SET_TAP_LATENCY failed:', errorText(err));
  }
}

// postTapLatency, but only when a document exists (with none, there is nobody to tell, and a new one gets it
// from ensureOffscreen). Never throws.
async function sendTapLatency() {
  try {
    if (!(await hasOffscreen())) return;
  } catch (err) {
    return;
  }
  await postTapLatency();
}

// SET_TAP_LATENCY from the app: replaces the list at once, stores it, tells the offscreen document.
async function setTapLatency(devices) {
  tapLatency = normalizeTapLatency(devices);
  tapLatencyTouched = true;
  chrome.storage.session.set({ tapLatency }).catch(logError('session write'));
  await sendTapLatency();
}

// Tab ids the offscreen document is capturing, [] when it does not exist,
// or null when it exists but did not answer (state unknown, change nothing).
async function liveCaptureIds() {
  if (!(await hasOffscreen())) return [];
  const ids = await sendToOffscreen({ type: 'LIST_CAPTURES' });
  return Array.isArray(ids) ? ids.filter(Number.isInteger) : null;
}

// Asks a running offscreen document to re-check access and every route.
// Never creates the document: with no captures there is nothing to route.
async function resolveDevicesInOffscreen() {
  if (await hasOffscreen()) await sendToOffscreen({ type: 'RESOLVE_DEVICES' });
}

// ---------------------------------------------------------------------------
// Device access: whether output device labels are readable, which needs the
// extension origin's microphone permission (granted on permissions.html).
// ---------------------------------------------------------------------------

let deviceAccess = null; // null until loaded from chrome.storage.local

async function getDeviceAccess() {
  if (deviceAccess === null) {
    const stored = await chrome.storage.local.get('deviceAccess').catch(() => ({}));
    if (deviceAccess === null) deviceAccess = stored.deviceAccess === true;
  }
  return deviceAccess;
}

async function setDeviceAccess(granted) {
  await getDeviceAccess();
  if (deviceAccess === granted) return;
  deviceAccess = granted;
  chrome.storage.local.set({ deviceAccess: granted }).catch(logError('deviceAccess write'));
  // A grant lets "noAccess" captures route now. Either way the offscreen
  // document re-checks, so a wrong report from any source corrects itself.
  resolveDevicesInOffscreen().catch(logError('RESOLVE_DEVICES'));
  schedulePush();
}

// Best effort: the Permissions API may be missing or refuse 'microphone' in a
// service worker; only definite answers are used.
async function watchMicPermission() {
  if (!navigator.permissions || typeof navigator.permissions.query !== 'function') return;
  const status = await navigator.permissions.query({ name: 'microphone' });
  const apply = () => {
    if (status.state === 'granted') setDeviceAccess(true).catch(logError('deviceAccess'));
    else if (status.state === 'denied') setDeviceAccess(false).catch(logError('deviceAccess'));
  };
  apply();
  status.onchange = apply;
}

const PERMISSIONS_URL = chrome.runtime.getURL('permissions.html');
let openingPermissionPage = null;

function isPermissionPage(tab) {
  const url = tab.url || tab.pendingUrl || '';
  return url.split(/[?#]/)[0] === PERMISSIONS_URL;
}

async function openPermissionPage() {
  const tabs = await chrome.tabs.query({});
  const open = tabs.find((t) => !t.incognito && isPermissionPage(t));
  if (open) {
    await chrome.tabs.update(open.id, { active: true });
    await chrome.windows.update(open.windowId, { focused: true });
    return;
  }
  // Always a normal window: the prompt is for the regular profile.
  let target = null;
  try {
    const last = await chrome.windows.getLastFocused({ windowTypes: ['normal'] });
    if (last && !last.incognito) target = last;
  } catch (e) { /* no window focused yet */ }
  if (!target) {
    const windows = await chrome.windows.getAll({ windowTypes: ['normal'] });
    target = windows.find((w) => !w.incognito) || null;
  }
  if (!target) {
    await chrome.windows.create({ url: PERMISSIONS_URL, focused: true, incognito: false });
    return;
  }
  await chrome.tabs.create({ windowId: target.id, url: PERMISSIONS_URL, active: true });
  await chrome.windows.update(target.id, { focused: true });
}

function openPermissionPageOnce() {
  if (!openingPermissionPage) {
    openingPermissionPage = openPermissionPage().finally(() => { openingPermissionPage = null; });
  }
  return openingPermissionPage;
}

// ---------------------------------------------------------------------------
// Badge / per-tab action state
// ---------------------------------------------------------------------------

const BADGES = {
  capture: { text: 'ON', color: BADGE_COLOR, title: TITLE_ON },
  off: { text: '', color: null, title: TITLE_OFF }
};

// mode: 'capture' | 'off'
function setBadge(tabId, mode) {
  const ignore = () => {};
  const badge = BADGES[mode] || BADGES.off;
  chrome.action.setBadgeText({ tabId, text: badge.text }).catch(ignore);
  if (badge.color) chrome.action.setBadgeBackgroundColor({ tabId, color: badge.color }).catch(ignore);
  chrome.action.setTitle({ tabId, title: badge.title }).catch(ignore);
}

// A tab's badge: ON when captured, none otherwise. st may be undefined.
function badgeFor(st) {
  return controlOf(st) === 'capture' ? 'capture' : 'off';
}

// Re-derives a tab's badge from its stored state.
async function refreshBadge(store, tabId) {
  const tab = await getTab(tabId);
  if (tab) setBadge(tabId, badgeFor(store.tabs.get(tabId)));
}

// ---------------------------------------------------------------------------
// Plain control (uncaptured tabs, see TAB MODES)
// ---------------------------------------------------------------------------

const plainSent = new Map(); // tabId -> plain level last sent by this worker
const plainInjected = new Set(); // tabs this worker injected the plain scripts into (or tried)

// What a frame of the tab should play at: the last level sent (it may be
// ahead of the stored state while a capture starts or stops), else the
// stored state's. store may be null (the state could not be loaded).
function plainLevelOf(store, tabId) {
  if (plainSent.has(tabId)) return plainSent.get(tabId);
  return plainFactor(store ? store.tabs.get(tabId) : undefined);
}

// Sends the tab's plain level to every frame unless it is the one already
// sent. Resolves once a frame has applied it, or once that failed (never
// rejects).
function pushPlain(tabId, factor) {
  if (plainSent.get(tabId) === factor) return Promise.resolve();
  plainSent.set(tabId, factor);
  return sendPlain(tabId, factor);
}

async function sendPlain(tabId, factor) {
  try {
    await chrome.tabs.sendMessage(tabId, { type: 'PLAIN_VOLUME', factor });
    return;
  } catch (err) {
    // No live bridge in the tab: it was open before this extension loaded,
    // or a reload of the extension cut off its copies.
  }
  if (plainInjected.has(tabId) || removedTabs.has(tabId)) return;
  plainInjected.add(tabId);
  // Injected even for level 1: a page world copy left from before an
  // extension reload may still hold an older level.
  if (!(await injectPlain(tabId)) || !plainSent.has(tabId)) return;
  // The newest level, which may have changed while the scripts went in.
  await chrome.tabs.sendMessage(tabId, { type: 'PLAIN_VOLUME', factor: plainSent.get(tabId) }).catch(() => {});
}

// Puts both plain scripts into every frame of the tab. A frame that already
// has a live copy ignores the repeat. Resolves false where scripts cannot run
// (chrome:// pages, the Web Store, a discarded tab).
async function injectPlain(tabId) {
  try {
    await chrome.scripting.executeScript({
      target: { tabId, allFrames: true }, files: [PLAIN_VOLUME_FILE], world: 'MAIN', injectImmediately: true
    });
    await chrome.scripting.executeScript({
      target: { tabId, allFrames: true }, files: [PLAIN_BRIDGE_FILE], injectImmediately: true
    });
    return true;
  } catch (err) {
    return false;
  }
}

// chrome.storage.session starts empty after an extension reload, update or
// re-enable, so every tab is back at plain level 1, but the page world copies
// in tabs open from before keep the level they last got. Once per session,
// send every open tab its level so none plays quieter than the app shows.
async function sweepPlain() {
  const flags = await chrome.storage.session.get(PLAIN_SWEPT_KEY);
  if (flags[PLAIN_SWEPT_KEY]) return;
  const store = await ready();
  const tabs = (await chrome.tabs.query({}))
    .filter((tab) => !tab.discarded && Number.isInteger(tab.id) && tab.id >= 0);
  // A few tabs at a time, so a window of a hundred tabs is not one burst of injections.
  for (let i = 0; i < tabs.length; i += PLAIN_SWEEP_BATCH) {
    await Promise.all(tabs.slice(i, i + PLAIN_SWEEP_BATCH)
      .map((tab) => pushPlain(tab.id, plainFactor(store.tabs.get(tab.id)))));
  }
  await chrome.storage.session.set({ [PLAIN_SWEPT_KEY]: true });
}

// PLAIN_HELLO from plain-bridge.js. Only this extension's own content scripts
// in a tab are answered; other messages are left to the listener below.
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg || msg.type !== 'PLAIN_HELLO' || msg.target !== undefined) return false;
  const tab = sender && sender.tab;
  if (sender.id !== chrome.runtime.id || !tab || !Number.isInteger(tab.id) || tab.id < 0) return false;
  ready().then(
    (store) => sendResponse({ factor: plainLevelOf(store, tab.id) }),
    () => sendResponse({ factor: plainLevelOf(null, tab.id) })
  );
  return true;
});

// ---------------------------------------------------------------------------
// Capture lifecycle
// ---------------------------------------------------------------------------

// Bring storage in line with what the offscreen document is really capturing.
async function reconcileCaptures(store, refreshAllBadges) {
  const ids = await liveCaptureIds();
  if (ids === null) return;
  const live = new Set(ids);
  let adopted = false;
  for (const [tabId, st] of store.tabs) {
    const isLive = live.has(tabId);
    if (st.captured && !isLive) {
      markUncaptured(store, tabId);
    } else if (!st.captured && isLive) {
      st.captured = true;
      persistTab(tabId, st);
      setBadge(tabId, 'capture');
      pushPlain(tabId, 1); // the graph is live
      adopted = true;
    } else if (refreshAllBadges) {
      if (isLive) setBadge(tabId, 'capture');
      else refreshBadge(store, tabId).catch(logError('badge refresh'));
    }
  }
  for (const tabId of live) {
    if (store.tabs.has(tabId)) continue;
    // A capture with no stored state: adopt it with defaults and sync the graph.
    const st = defaultState();
    st.captured = true;
    store.tabs.set(tabId, st);
    persistTab(tabId, st);
    setBadge(tabId, 'capture');
    sendToOffscreen({ type: 'SET_STATE', tabId, ...audioFields(st) });
    pushPlain(tabId, 1);
    adopted = true;
  }
  // Adopted captures may have reported their device status to nobody.
  if (adopted) sendToOffscreen({ type: 'RESOLVE_DEVICES' });
  // The document may be a new one that never got the tap latency. Not awaited.
  sendTapLatency();
}

function markUncaptured(store, tabId) {
  setBadge(tabId, 'off');
  const st = store.tabs.get(tabId);
  if (!st) return;
  if (st.captured) {
    // The capture is gone already (or going, from stopCapture, which sent
    // this level first and makes this a no-op): back to the plain level.
    pushPlain(tabId, uncapturedFactor(st));
    st.captured = false;
    resetDeviceReport(st);
    persistTab(tabId, st);
    if (st.muted) chrome.tabs.update(tabId, { muted: true }).catch(() => {});
    schedulePush();
  }
}

async function stopCapture(store, tabId) {
  const st = store.tabs.get(tabId);
  // Mute through the tabs API, and scale the page's media to the plain level,
  // before releasing the stream so the tab never blips back at full level.
  // While the graph still runs the tab is only quieter. A frame that takes too
  // long to answer does not hold the stop up.
  const plain = Promise.race([
    pushPlain(tabId, uncapturedFactor(st)),
    new Promise((resolve) => setTimeout(resolve, PLAIN_STOP_WAIT_MS))
  ]);
  await Promise.all([
    st && st.muted ? chrome.tabs.update(tabId, { muted: true }).catch(() => {}) : null,
    plain
  ]);
  await sendToOffscreen({ type: 'STOP_CAPTURE', tabId });
  markUncaptured(store, tabId);
}

// Resolves true when the capture started.
async function startCapture(store, tabId, streamId) {
  const tab = await getTab(tabId);
  if (!tab) return false;

  const existing = store.tabs.get(tabId);
  // The new capture reports its own device status; drop any stale one.
  if (existing) resetDeviceReport(existing);
  const next = existing
    ? {
      ...existing,
      eqBands: existing.eqBands.slice(),
      deviceNames: existing.deviceNames.slice(),
      deviceMissing: existing.deviceMissing.slice()
    }
    : defaultState();
  if (!existing) {
    const site = await getSiteDefault(tab.url);
    if (site) next.volume = site.volume;
    // Store the seeded state now so app changes made while the capture is
    // starting edit it instead of creating a fresh full-volume default.
    store.tabs.set(tabId, next);
    persistTab(tabId, next);
  }
  // Chrome's tab mute moves into the Deci gain while captured.
  const apiMuted = !!(tab.mutedInfo && tab.mutedInfo.muted);
  next.muted = apiMuted;

  // Snapshot what the graph starts with: app changes during the start may
  // edit the stored object in place.
  const sent = audioFields(next);
  await ensureOffscreen();
  const resp = await sendToOffscreen({ type: 'START_CAPTURE', tabId, streamId, ...sent });
  if (!resp || !resp.ok) {
    console.warn(`Deci: capture of tab ${tabId} failed:`, resp ? resp.error : 'no response');
    return false;
  }
  // The document has the tap latency already; sending it again costs nothing and makes sure. Not awaited.
  postTapLatency();

  // Merge with anything the app changed while the capture was starting.
  const current = store.tabs.get(tabId);
  const final = current ? { ...current, muted: apiMuted, captured: true } : { ...next, captured: true };
  store.tabs.set(tabId, final);
  persistTab(tabId, final);
  if (current && !sameAudio(final, sent)) {
    sendToOffscreen({ type: 'SET_STATE', tabId, ...audioFields(final) });
  }
  // Only now that the graph is live does the page go back to its own level
  // (until then the plain level scaled the capture too: quieter, never
  // louder). Sent in the same turn as captured flips, so a stop or a
  // CAPTURE_ENDED that follows always sends its plain level after this one.
  pushPlain(tabId, 1);
  // Unmute via the API only after the gain (muted) owns the audio.
  if (apiMuted) chrome.tabs.update(tabId, { muted: false }).catch(() => {});
  setBadge(tabId, 'capture');
  schedulePush();
  return true;
}

async function toggleCapture(tabId, streamIdRequest) {
  const store = await ready();
  const st = store.tabs.get(tabId);
  if (st && st.captured) {
    await stopCapture(store, tabId);
    return;
  }
  const result = await (streamIdRequest || requestStreamId(tabId));
  if (result.error) {
    // Self-heal: the offscreen document may already hold this tab's stream.
    if (((await liveCaptureIds()) || []).includes(tabId)) {
      const healed = store.tabs.get(tabId) || defaultState();
      healed.captured = true;
      store.tabs.set(tabId, healed);
      persistTab(tabId, healed);
      setBadge(tabId, 'capture');
      pushPlain(tabId, 1); // the graph is live
      sendToOffscreen({ type: 'RESOLVE_DEVICES' }); // its status may have gone unrecorded
      schedulePush();
      return;
    }
    console.warn(`Deci: cannot capture tab ${tabId}:`, result.error);
    return;
  }
  if (!(await startCapture(store, tabId, result.id))) {
    // Still plain. A failed start may have seeded the state with a site
    // default, so the level may have changed.
    pushPlain(tabId, plainFactor(store.tabs.get(tabId)));
  }
}

function requestStreamId(tabId) {
  // No consumerTabId: the stream id is consumed by the offscreen document.
  // Callback form, resolved to { id } or { error } (never rejects).
  return new Promise((resolve) => {
    try {
      chrome.tabCapture.getMediaStreamId({ targetTabId: tabId }, (id) => {
        const err = chrome.runtime.lastError;
        if (err || !id) resolve({ error: err ? err.message : 'empty stream id' });
        else resolve({ id });
      });
    } catch (err) {
      resolve({ error: errorText(err) });
    }
  });
}

const togglingTabs = new Set();

chrome.action.onClicked.addListener((tab) => {
  if (!tab || !Number.isInteger(tab.id) || tab.id < 0) return;
  const tabId = tab.id;
  if (togglingTabs.has(tabId)) return;
  togglingTabs.add(tabId);
  // Ask for the stream id before any await while the invocation is fresh,
  // unless the warm cache already says this click is a stop.
  const knownCaptured = !!(storeSync && storeSync.tabs.get(tabId) && storeSync.tabs.get(tabId).captured);
  const streamIdRequest = knownCaptured ? null : requestStreamId(tabId);
  toggleCapture(tabId, streamIdRequest)
    .catch(logError(`toggle tab ${tabId}`))
    .finally(() => togglingTabs.delete(tabId));
});

// The offscreen document holds a port open; when it goes away (crash, or
// Chrome closed it) every capture is gone, so clear them right away instead
// of waiting for the 30 s alarm.
chrome.runtime.onConnect.addListener((p) => {
  if (p.name !== 'deci-offscreen') return;
  p.onDisconnect.addListener(() => {
    setTimeout(() => {
      ready().then((store) => reconcileCaptures(store, false)).catch(logError('offscreen gone'));
    }, 250);
  });
});

// Stores the offscreen document's latest device status for a tab (no graph
// sync needed: it came from the graph).
// `missing` lists the multi-output names that matched nothing; it only means
// something for names the tab still has (a late report may name old ones).
async function setDeviceStatus(tabId, status, missing) {
  const store = await ready();
  const st = store.tabs.get(tabId);
  if (!st) return;
  const names = normalizeNames(missing).filter((name) => st.deviceNames.includes(name));
  if (st.deviceStatus === status && sameNames(st.deviceMissing, names)) return;
  st.deviceStatus = status;
  st.deviceMissing = names;
  persistTab(tabId, st);
  schedulePush();
}

// Messages from the offscreen document and permissions.html.
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg || msg.target !== 'background') return false;
  switch (msg.type) {
    case 'CAPTURE_ENDED':
      if (!Number.isInteger(msg.tabId)) break;
      ready().then((store) => markUncaptured(store, msg.tabId)).catch(logError('capture ended'));
      break;
    case 'DEVICE_STATUS':
      if (!Number.isInteger(msg.tabId) || !REPORTED_DEVICE_STATUSES.includes(msg.status)) break;
      setDeviceStatus(msg.tabId, msg.status, msg.missing).catch(logError('DEVICE_STATUS'));
      break;
    case 'DEVICE_ACCESS':
      if (typeof msg.granted !== 'boolean') break;
      setDeviceAccess(msg.granted).catch(logError('DEVICE_ACCESS'));
      break;
    default:
      break;
  }
  // Answer so the sender's promise resolves instead of rejecting with
  // "message port closed" (offscreen re-sends reports whose send failed).
  sendResponse({ ok: true });
  return false;
});

// ---------------------------------------------------------------------------
// YouTube Music switch script
// ---------------------------------------------------------------------------

// ytm-switch.js: the copy in an open YouTube Music tab is orphaned by a
// reload, update or disable and stops, so without this the tab never clicks
// "Switch" until the user reloads it. Manifest content scripts never reach tabs
// that were open before the extension was installed or reloaded either. Top
// frame only, as in the manifest.
async function injectYTMSwitch() {
  const tabs = await chrome.tabs.query({ url: YTM_URL_PATTERN });
  await Promise.all(tabs.filter((tab) => !tab.discarded).map((tab) =>
    chrome.scripting.executeScript({ target: { tabId: tab.id }, files: [YTM_SWITCH_FILE] }).catch(() => {})
  ));
}

chrome.tabs.onActivated.addListener(({ tabId }) => {
  ready().then((store) => refreshBadge(store, tabId)).catch(logError('badge refresh'));
});

// ---------------------------------------------------------------------------
// TAB_LIST
// ---------------------------------------------------------------------------

const removedTabs = new Set(); // ids removed during this worker's lifetime
let pushTimer = null;

function schedulePush() {
  if (!port || pushTimer) return;
  pushTimer = setTimeout(() => {
    pushTimer = null;
    sendTabList().catch(logError('TAB_LIST'));
  }, PUSH_DEBOUNCE_MS);
}

async function sendTabList() {
  if (!port) return;
  const store = await ready();
  const [tabs, incognitoAllowed, access] = await Promise.all([
    chrome.tabs.query({}),
    chrome.extension.isAllowedIncognitoAccess(),
    getDeviceAccess()
  ]);
  // The gate and `tracking` are read from here to the post with no await in
  // between, so the filter and the echo always agree.

  const liveIds = new Set();
  let knownChanged = false;
  const list = [];
  for (const t of tabs) {
    if (!Number.isInteger(t.id) || t.id < 0 || removedTabs.has(t.id)) continue;
    liveIds.add(t.id);
    if (t.audible && !store.known.has(t.id)) {
      store.known.add(t.id);
      knownChanged = true;
    }
    const st = store.tabs.get(t.id);
    const captured = !!(st && st.captured);
    const control = controlOf(st);
    // A captured tab is listed even while silent; any other only once it was audible.
    if (!t.audible && control !== 'capture' && !store.known.has(t.id)) continue;
    // Hidden by the tracking switch, or the gate is still closed on this port.
    // Bookkeeping above and all audio handling are unchanged; only the report
    // leaves the tab out.
    if (!isReported(t)) continue;
    const s = st || defaultState();
    list.push({
      id: t.id,
      title: t.title || '',
      favIconUrl: faviconOrNull(t.favIconUrl),
      incognito: !!t.incognito,
      isAudible: !!t.audible,
      captured,
      control,
      volume: s.volume,
      boost: s.boost,
      muted: captured ? s.muted : !!(t.mutedInfo && t.mutedInfo.muted),
      eqBands: s.eqBands.slice(),
      deviceName: s.deviceName,
      deviceNames: s.deviceNames.slice(),
      deviceMissing: captured ? s.deviceMissing.slice() : [],
      deviceStatus: listDeviceStatus(s, captured)
    });
  }

  // Prune ids of tabs that no longer exist (never a live capture).
  for (const id of [...store.known]) {
    if (!liveIds.has(id)) {
      store.known.delete(id);
      knownChanged = true;
    }
  }
  for (const [id, st] of [...store.tabs]) {
    if (!liveIds.has(id) && !st.captured) removeTabState(store, id);
  }
  if (knownChanged) persistKnown(store);

  const message = {
    type: 'TAB_LIST',
    incognitoAllowed: !!incognitoAllowed,
    tabs: list,
    deviceAccess: access === true,
    multiDevice: true
  };
  // No echo while the gate is closed: the app reads that as a mismatch and
  // answers with SET_TRACKING.
  if (trackingConfirmed) message.tracking = { tabs: tracking.tabs, incognito: tracking.incognito };
  // Keep the message far below the native messaging limit: drop the largest
  // (data URL) favicons first if the list is unusually heavy.
  let size = JSON.stringify(message).length;
  if (size > TAB_LIST_BUDGET) {
    const heavy = list.filter((t) => t.favIconUrl).sort((a, b) => b.favIconUrl.length - a.favIconUrl.length);
    for (const t of heavy) {
      if (size <= TAB_LIST_BUDGET) break;
      size -= t.favIconUrl.length;
      t.favIconUrl = null;
    }
  }
  postToNative(message);
}

// ---------------------------------------------------------------------------
// Tab events
// ---------------------------------------------------------------------------

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  const listChange = 'audible' in changeInfo || 'mutedInfo' in changeInfo || 'title' in changeInfo ||
    'favIconUrl' in changeInfo || 'status' in changeInfo;
  if (!listChange && !('url' in changeInfo)) return;
  ready().then((store) => {
    const st = store.tabs.get(tabId);
    const control = controlOf(st);
    // Navigation can reset per-tab action state.
    if ('status' in changeInfo || 'url' in changeInfo) setBadge(tabId, badgeFor(st));
    if (changeInfo.audible === true && !store.known.has(tabId)) {
      store.known.add(tabId);
      persistKnown(store);
    }
    if (listChange && (tab.audible || control === 'capture' || store.known.has(tabId))) schedulePush();
  }).catch(logError('tab update'));
});

function forgetTab(tabId) {
  removedTabs.add(tabId);
  plainSent.delete(tabId);
  plainInjected.delete(tabId);
  ready().then((store) => {
    const st = store.tabs.get(tabId);
    if (st && st.captured) sendToOffscreen({ type: 'STOP_CAPTURE', tabId });
    if (store.tabs.has(tabId)) removeTabState(store, tabId);
    if (store.known.delete(tabId)) persistKnown(store);
    schedulePush();
  }).catch(logError('tab removed'));
}

chrome.tabs.onRemoved.addListener((tabId) => forgetTab(tabId));
chrome.tabs.onReplaced.addListener((addedTabId, removedTabId) => forgetTab(removedTabId));

// ---------------------------------------------------------------------------
// In-page functions (run via chrome.scripting.executeScript)
// ---------------------------------------------------------------------------

function getMediaState() {
  const els = Array.from(document.querySelectorAll('video, audio'));
  const el = els.find((e) => !e.paused && !e.ended && e.readyState > 2)
    || els.find((e) => isFinite(e.duration) && e.duration > 0)
    || els[0];
  if (!el) return null;
  return {
    paused: el.paused,
    currentTime: el.currentTime || 0,
    duration: isFinite(el.duration) ? el.duration : 0
  };
}

function togglePlayback() {
  const els = Array.from(document.querySelectorAll('video, audio'));
  const el = els.find((e) => !e.paused && !e.ended && e.readyState > 2)
    || els.find((e) => isFinite(e.duration) && e.duration > 0)
    || els[0];
  if (!el) return;
  if (el.paused) {
    el.play().catch(() => {});
  } else {
    el.pause();
  }
}

async function sendMediaState(tabId) {
  try {
    // A hidden tab (or any tab while the gate is closed) is not asked at all, and
    // not answered if the switch flips or the port changes while the page script
    // runs. An unknown tab has nothing to report.
    const tab = await getTab(tabId);
    if (!isReported(tab)) return;
    const results = await chrome.scripting.executeScript({ target: { tabId }, func: getMediaState });
    const state = results && results[0] && results[0].result;
    if (state && isReported(tab)) postToNative({ type: 'MEDIA_STATE', tabId, ...state });
  } catch (err) {
    console.warn(`Deci: media state for tab ${tabId} failed:`, errorText(err));
  }
}

async function runTogglePlayback(tabId) {
  try {
    await chrome.scripting.executeScript({ target: { tabId }, func: togglePlayback });
  } catch (err) {
    console.warn(`Deci: toggle playback for tab ${tabId} failed:`, errorText(err));
  }
}

// ---------------------------------------------------------------------------
// App commands
// ---------------------------------------------------------------------------

// Applies a change to a tab's stored state, syncs the offscreen graph when
// the tab is captured (else the plain level of its frames, sent only when it
// changed), and schedules a TAB_LIST push.
async function updateTabState(tabId, mutate) {
  const store = await ready();
  const tab = await getTab(tabId);
  if (!tab) return null;
  const st = store.tabs.get(tabId) || defaultState();
  mutate(st);
  store.tabs.set(tabId, st);
  persistTab(tabId, st);
  if (st.captured) sendToOffscreen({ type: 'SET_STATE', tabId, ...audioFields(st) });
  else pushPlain(tabId, plainFactor(st));
  schedulePush();
  return { st, tab };
}

function setTabDevice(tabId, deviceName) {
  return updateTabState(tabId, (st) => {
    if (st.deviceName === deviceName && st.deviceNames.length === 0) return;
    st.deviceName = deviceName;
    // One output ends multi-output mode.
    st.deviceNames = [];
    // "pending" until the offscreen document reports for the new name
    // (it always reports first after a change).
    resetDeviceReport(st);
  });
}

// Multi-output: the tab plays on every named device. A list with no usable
// name changes nothing (the app sends nothing for an empty selection, and a
// garbled message must not silence the tab). deviceName is left alone so a
// later SET_TAB_DEVICE or the app's switch back to single restores it.
function setTabDevices(tabId, deviceNames) {
  const names = normalizeNames(deviceNames);
  if (names.length === 0) return Promise.resolve(null);
  return updateTabState(tabId, (st) => {
    if (sameNames(st.deviceNames, names)) return;
    st.deviceNames = names;
    resetDeviceReport(st);
  });
}

async function setTabVolume(tabId, volume, boost) {
  const result = await updateTabState(tabId, (st) => {
    st.volume = clampVolume(volume);
    if (boost !== undefined) st.boost = clampBoost(boost);
  });
  if (!result) return;
  const { st, tab } = result;
  if (controlOf(st) === 'capture' && !tab.incognito) {
    const host = hostOf(tab.url);
    if (host) queueSiteDefault(host, st.volume, st.boost);
  }
}

async function setTabMute(tabId, muted) {
  const store = await ready();
  const st = store.tabs.get(tabId);
  if (st && st.captured) {
    await updateTabState(tabId, (s) => { s.muted = muted; });
    return;
  }
  // Uncaptured: Chrome's tab mute is the truth (onUpdated pushes the change).
  try {
    await chrome.tabs.update(tabId, { muted });
  } catch (err) {
    console.warn(`Deci: mute tab ${tabId} failed:`, errorText(err));
  }
}

function handleNativeMessage(msg) {
  if (!msg || typeof msg !== 'object') return;
  const { type, tabId } = msg;
  if (type === 'GET_TABS') {
    schedulePush();
    return;
  }
  if (type === 'OPEN_DEVICE_PERMISSION') {
    openPermissionPageOnce().catch(logError('OPEN_DEVICE_PERMISSION'));
    return;
  }
  if (type === 'SET_TRACKING') {
    setTracking(msg).catch(logError('SET_TRACKING'));
    return;
  }
  if (type === 'SET_OPTIONS') {
    setOptions(msg).catch(logError('SET_OPTIONS'));
    return;
  }
  if (type === 'SET_TAP_LATENCY') {
    // Global, no tabId: handled before the tab gate below.
    setTapLatency(msg.devices).catch(logError('SET_TAP_LATENCY'));
    return;
  }
  if (!Number.isInteger(tabId)) return;
  switch (type) {
    case 'SET_TAB_VOLUME':
      // A missing or non-numeric volume is dropped, never read as 100%.
      if (typeof msg.volume !== 'number' || !Number.isFinite(msg.volume)) break;
      setTabVolume(tabId, msg.volume, msg.boost).catch(logError('SET_TAB_VOLUME'));
      break;
    case 'SET_TAB_MUTE':
      setTabMute(tabId, msg.muted === true).catch(logError('SET_TAB_MUTE'));
      break;
    case 'SET_TAB_EQ':
      updateTabState(tabId, (st) => { st.eqBands = normalizeBands(msg.eqBands); })
        .catch(logError('SET_TAB_EQ'));
      break;
    case 'SET_TAB_DEVICE':
      // Captured: SET_STATE makes the offscreen document re-route now.
      // Otherwise it is stored and START_CAPTURE carries it.
      setTabDevice(tabId, typeof msg.deviceName === 'string' ? msg.deviceName : '')
        .catch(logError('SET_TAB_DEVICE'));
      break;
    case 'SET_TAB_DEVICES':
      // Same path as SET_TAB_DEVICE: SET_STATE makes the offscreen document
      // add and remove outputs now, or START_CAPTURE carries the list.
      setTabDevices(tabId, msg.deviceNames).catch(logError('SET_TAB_DEVICES'));
      break;
    case 'TOGGLE_PLAYBACK':
      runTogglePlayback(tabId);
      break;
    case 'GET_MEDIA_STATE':
      sendMediaState(tabId);
      break;
    default:
      break;
  }
}

// ---------------------------------------------------------------------------
// Native connection
// ---------------------------------------------------------------------------

let port = null;
let retryDelay = RETRY_MIN_MS;
let retryTimer = null;
let stableTimer = null;

function postToNative(message) {
  if (!port) return;
  try {
    port.postMessage(message);
  } catch (err) {
    console.warn('Deci: native post failed:', errorText(err));
  }
}

function scheduleReconnect() {
  if (retryTimer) return;
  const delay = retryDelay;
  retryDelay = Math.min(retryDelay * 2, RETRY_MAX_MS);
  retryTimer = setTimeout(() => {
    retryTimer = null;
    connect();
  }, delay);
}

function connect() {
  if (port) return;
  if (retryTimer) {
    clearTimeout(retryTimer);
    retryTimer = null;
  }
  let p;
  try {
    p = chrome.runtime.connectNative(NATIVE_HOST);
  } catch (err) {
    console.error('Deci: connectNative threw:', errorText(err));
    scheduleReconnect();
    return;
  }
  port = p;
  // A new port starts with the privacy gate closed (see the tracking block).
  trackingConfirmed = false;
  let gotMessage = false;
  // A connection that survives a few seconds counts as healthy.
  stableTimer = setTimeout(() => { retryDelay = RETRY_MIN_MS; }, STABLE_CONNECTION_MS);

  p.onMessage.addListener((msg) => {
    if (!gotMessage) {
      gotMessage = true;
      retryDelay = RETRY_MIN_MS;
    }
    handleNativeMessage(msg);
  });
  p.onDisconnect.addListener(() => {
    const reason = chrome.runtime.lastError && chrome.runtime.lastError.message;
    console.warn('Deci: native host disconnected:', reason || 'no reason given');
    if (port === p) {
      port = null;
      // The app is gone, so its tap is too: a stale value would keep delaying the other outputs.
      setTapLatency([]).catch(logError('tap latency clear'));
    }
    clearTimeout(stableTimer);
    stableTimer = null;
    scheduleReconnect();
  });
  console.info('Deci: connected to native host');
  schedulePush();
}

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name !== RECONNECT_ALARM) return;
  connect();
  // Safety net: if the offscreen document vanished, nothing is captured.
  ready().then(async (store) => {
    const anyCaptured = [...store.tabs.values()].some((s) => s.captured);
    if (anyCaptured && !(await hasOffscreen())) await reconcileCaptures(store, false);
  }).catch(logError('alarm reconcile'));
});

chrome.runtime.onStartup.addListener(() => connect());
chrome.runtime.onInstalled.addListener(() => connect());

// ---------------------------------------------------------------------------
// Worker startup
// ---------------------------------------------------------------------------

chrome.alarms.clear(LEGACY_ALARM).catch(() => {});
chrome.alarms.get(RECONNECT_ALARM).then((alarm) => {
  if (!alarm) return chrome.alarms.create(RECONNECT_ALARM, { periodInMinutes: 0.5 });
  return undefined;
}).catch(logError('alarm setup'));

// Values an older version stored and nothing reads any more. Idempotent: a no-op once gone.
chrome.storage.local.remove('autoTracks').catch(logError('stale key remove'));
chrome.storage.session.remove('pageBlocked').catch(logError('stale key remove'));

ready().catch(logError('startup state load'));
loadTracking().catch(logError('tracking read'));
// Every worker start, not onInstalled: re-enabling the extension orphans the
// tab's copy too and fires no onInstalled. A live copy ignores the repeat.
injectYTMSwitch().catch(logError('inject ytm-switch'));
// A no-op after the first worker start of a session.
sweepPlain().catch(logError('plain sweep'));
// Never throws (async); if the Permissions API is unusable here, the
// offscreen document and permissions.html still report access.
watchMicPermission().catch(() => {});
connect();
