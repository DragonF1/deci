/*
 * Deci Audio Companion: offscreen document.
 * Owns one Web Audio graph (a "chain") per output of a captured tab:
 *   source > gain > 10 x BiquadFilter (EQ) > limiter > trim > destination
 * A tab on one output has one chain. A tab in multi-output mode has one chain
 * per distinct output, each in its own AudioContext with its own setSinkId and
 * its own source node from the same tab capture (the first chain reads the
 * capture stream itself, the others read clones of it). Volume, mute and EQ
 * are applied to every chain alike. The destination of each chain is routed
 * with AudioContext.setSinkId (resolved by device name, re-resolved on
 * 'devicechange'). Only handles messages with target 'offscreen'; reports to
 * the service worker with target 'background'. See background.js for the
 * full contract.
 */

const FREQUENCIES = [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
const FILTER_Q = 1.41;
const SMOOTHING_SECONDS = 0.015; // setTargetAtTime time constant
const EQ_LIMIT_DB = 30;
const PSEUDO_OUTPUT_IDS = ['default', 'communications'];
const DEVICE_CHANGE_DEBOUNCE_MS = 300;
const FIRST_ROUTE_TIMEOUT_MS = 1500; // a start never waits longer than this for its sink
const DEVICE_CALL_TIMEOUT_MS = 4000; // a hung enumerateDevices/setSinkId must not stall the queue
const MAX_SINKS = 8; // outputs one tab can play on at once (background.js has the same cap)

const LIMITER = { threshold: -1, knee: 0, ratio: 20, attack: 0.003, release: 0.25 };

// Chrome's DynamicsCompressor applies automatic makeup gain:
//   makeup = (1 / fullRangeGain) ^ 0.6
// where fullRangeGain is the static curve's output for a 0 dBFS input. With a
// hard knee, 0 dBFS sits (0 - threshold) dB over the threshold, so the curve
// gives threshold + (0 - threshold) / ratio = -0.95 dB, and makeup is about
// +0.57 dB. The trim stage cancels it (about 0.936 linear) so a captured tab
// at 100% matches its uncaptured loudness.
const FULL_RANGE_DB = LIMITER.threshold + (0 - LIMITER.threshold) / LIMITER.ratio;
const MAKEUP_DB = -FULL_RANGE_DB * 0.6;
const TRIM_GAIN = Math.pow(10, -MAKEUP_DB / 20);

// tabId -> { stream, chains, state, deviceGen, deviceQueue, reportedStatus }
//   chains: one per output, never empty once a capture is registered:
//     { ctx, stream, ownsStream, source, gain, filters, limiter, trim, sinkId, connected }
//     sinkId is the output the chain's context plays on ('' = system default);
//     ownsStream is true for a clone that dies with the chain.
const captures = new Map();
const pendingStarts = new Map(); // tabId -> token of the newest in-flight start

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
  const out = new Array(FREQUENCIES.length).fill(0);
  if (!Array.isArray(bands)) return out;
  for (let i = 0; i < out.length; i++) {
    const n = Number(bands[i]);
    if (Number.isFinite(n)) out[i] = Math.min(EQ_LIMIT_DB, Math.max(-EQ_LIMIT_DB, n));
  }
  return out;
}

// Merges the defined fields of msg over base and normalizes the result.
function mergeState(base, msg) {
  return {
    volume: clampVolume(msg.volume !== undefined ? msg.volume : base.volume),
    boost: clampBoost(msg.boost !== undefined ? msg.boost : base.boost),
    muted: msg.muted !== undefined ? msg.muted === true : base.muted === true,
    eqBands: normalizeBands(msg.eqBands !== undefined ? msg.eqBands : base.eqBands),
    deviceName: typeof msg.deviceName === 'string' ? msg.deviceName
      : (typeof base.deviceName === 'string' ? base.deviceName : ''),
    deviceNames: uniqueNames(msg.deviceNames !== undefined ? msg.deviceNames : base.deviceNames)
  };
}

function targetGain(state) {
  return state.muted ? 0 : state.volume * state.boost;
}

function stopTracks(stream) {
  for (const track of stream.getTracks()) {
    try { track.stop(); } catch (e) { /* already stopped */ }
  }
}

// Releases one chain: its nodes, its context and, when it owns one, its stream.
function teardownChain(chain) {
  if (chain.ownsStream) stopTracks(chain.stream);
  for (const node of [chain.source, chain.gain, ...chain.filters, chain.limiter, chain.trim]) {
    try { node.disconnect(); } catch (e) { /* not connected */ }
  }
  chain.ctx.close().catch(() => {});
}

function teardown(entry) {
  stopTracks(entry.stream);
  const chains = entry.chains;
  entry.chains = [];
  for (const chain of chains) teardownChain(chain);
}

function stopCapture(tabId) {
  pendingStarts.delete(tabId); // abort an in-flight start for this tab
  const entry = captures.get(tabId);
  if (!entry) return false;
  captures.delete(tabId);
  teardown(entry);
  return true;
}

function onTrackEnded(tabId, entry) {
  if (captures.get(tabId) !== entry) return;
  captures.delete(tabId);
  teardown(entry);
  chrome.runtime.sendMessage({ target: 'background', type: 'CAPTURE_ENDED', tabId }).catch(() => {});
}

// Builds one chain on a fresh context, not yet connected to the destination
// (so nothing is heard before its output is chosen). Synchronous on purpose:
// the chain starts from the entry's state as it is now and is registered by the
// caller before anything can await, so a SET_STATE can never miss it.
// routed: the chain may be heard on the output it is on. The first chain is,
// since it starts on the default output; an extra chain is not until its
// output is set (see trySetSink).
function buildChain(ctx, stream, ownsStream, state, routed) {
  const source = ctx.createMediaStreamSource(stream);
  const gain = ctx.createGain();
  gain.gain.value = targetGain(state);

  const filters = FREQUENCIES.map((frequency, i) => {
    const filter = ctx.createBiquadFilter();
    if (i === 0) filter.type = 'lowshelf';
    else if (i === FREQUENCIES.length - 1) filter.type = 'highshelf';
    else filter.type = 'peaking';
    filter.frequency.value = frequency;
    filter.Q.value = FILTER_Q;
    filter.gain.value = state.eqBands[i];
    return filter;
  });

  const limiter = ctx.createDynamicsCompressor();
  limiter.threshold.value = LIMITER.threshold;
  limiter.knee.value = LIMITER.knee;
  limiter.ratio.value = LIMITER.ratio;
  limiter.attack.value = LIMITER.attack;
  limiter.release.value = LIMITER.release;

  const trim = ctx.createGain();
  trim.gain.value = TRIM_GAIN;

  source.connect(gain);
  let prev = gain;
  for (const filter of filters) {
    prev.connect(filter);
    prev = filter;
  }
  prev.connect(limiter);
  limiter.connect(trim);

  return { ctx, stream, ownsStream, source, gain, filters, limiter, trim, sinkId: '', routed, connected: false };
}

// Lets a chain be heard. Idempotent.
function connectChain(chain) {
  if (chain.connected) return;
  chain.trim.connect(chain.ctx.destination);
  chain.connected = true;
}

async function startCapture(msg) {
  const tabId = msg.tabId;
  const streamId = msg.streamId;
  if (!Number.isInteger(tabId) || typeof streamId !== 'string' || !streamId) {
    throw new Error('invalid START_CAPTURE');
  }
  // Never play a tab twice: replace any existing capture of it.
  stopCapture(tabId);
  const token = {};
  pendingStarts.set(tabId, token);

  let stream = null;
  let ctx = null;
  try {
    stream = await navigator.mediaDevices.getUserMedia({
      audio: { mandatory: { chromeMediaSource: 'tab', chromeMediaSourceId: streamId } },
      video: false
    });
    if (pendingStarts.get(tabId) !== token) throw new Error('capture superseded');
    ctx = new AudioContext();
    await ctx.resume();
    if (pendingStarts.get(tabId) !== token) throw new Error('capture superseded');
  } catch (err) {
    if (stream) stopTracks(stream);
    if (ctx) ctx.close().catch(() => {});
    throw err;
  } finally {
    if (pendingStarts.get(tabId) === token) pendingStarts.delete(tabId);
  }

  const state = mergeState({}, msg);

  // The first chain plays the capture stream itself and starts on the default
  // output; routing then moves it to the chosen output (or keeps it).
  const first = buildChain(ctx, stream, false, state, true);
  const entry = {
    stream, chains: [first], state,
    deviceGen: 0, deviceQueue: Promise.resolve(), reportedStatus: null
  };
  const tracks = stream.getAudioTracks();
  if (tracks.length === 0 || tracks.every((t) => t.readyState === 'ended')) {
    teardown(entry);
    throw new Error('tab stream has no live audio track');
  }
  captures.set(tabId, entry);
  for (const track of tracks) {
    track.addEventListener('ended', () => onTrackEnded(tabId, entry), { once: true });
  }
  // Pick the sinks before anything reaches a destination, so a routed tab
  // never blips on the default output first (capped for slow devices).
  routeOutput(tabId, entry);
  // A fresh context already plays on the default output, so only a named
  // device is worth waiting for.
  if (wantedNames(entry.state).some((name) => name !== '')) {
    await Promise.race([routeSettled(entry), delay(FIRST_ROUTE_TIMEOUT_MS)]);
  }
  // Stopped, ended or replaced meanwhile: that path already tore it down.
  if (captures.get(tabId) !== entry) throw new Error('capture stopped while starting');
  // Whatever routing has not finished plays on the default output until it
  // does, on the first chain only: an extra chain with no output yet stays
  // silent, or it would double the tab on the default output.
  for (const chain of entry.chains) {
    if (chain.routed) connectChain(chain);
  }
}

function setState(msg) {
  const entry = captures.get(msg.tabId);
  if (!entry) return false;
  const next = mergeState(entry.state, msg);
  for (const chain of entry.chains) {
    const now = chain.ctx.currentTime;
    chain.gain.gain.setTargetAtTime(targetGain(next), now, SMOOTHING_SECONDS);
    for (let i = 0; i < chain.filters.length; i++) {
      if (next.eqBands[i] !== entry.state.eqBands[i]) {
        chain.filters[i].gain.setTargetAtTime(next.eqBands[i], now, SMOOTHING_SECONDS);
      }
    }
  }
  const deviceChanged = next.deviceName !== entry.state.deviceName ||
    !sameNames(next.deviceNames, entry.state.deviceNames);
  entry.state = next;
  if (deviceChanged) {
    // The service worker shows "pending" after a device change, so the
    // first result for the new choice is always reported.
    entry.reportedStatus = null;
    routeOutput(msg.tabId, entry);
  }
  return true;
}

// ---------------------------------------------------------------------------
// Output device routing
// ---------------------------------------------------------------------------

// Picks the output for deviceName from an enumerateDevices() list. Pure (no
// Chrome APIs) so it can be tested on its own. Returns
// { sinkId, status, readable } where readable means output labels are visible.
function matchOutput(devices, deviceName) {
  const outputs = (Array.isArray(devices) ? devices : []).filter((d) =>
    d && d.kind === 'audiooutput' && !PSEUDO_OUTPUT_IDS.includes(d.deviceId));
  const labelOf = (d) => (typeof d.label === 'string' ? d.label : '');
  const readable = outputs.some((d) => labelOf(d) !== '');
  if (!deviceName) return { sinkId: '', status: 'default', readable };
  if (!readable) return { sinkId: '', status: 'noAccess', readable };
  const lower = deviceName.toLowerCase();
  const match = outputs.find((d) => labelOf(d) === deviceName) ||
    outputs.find((d) => labelOf(d).startsWith(`${deviceName} (`)) ||
    outputs.find((d) => labelOf(d).toLowerCase().includes(lower));
  if (match && match.deviceId) return { sinkId: match.deviceId, status: 'routed', readable };
  return { sinkId: '', status: 'notFound', readable };
}

// An output name list: strings only, no empty ones, no duplicates, capped.
// Pure.
function uniqueNames(names) {
  if (!Array.isArray(names)) return [];
  const out = [];
  for (const name of names) {
    if (typeof name !== 'string' || name === '' || out.includes(name)) continue;
    out.push(name);
    if (out.length >= MAX_SINKS) break;
  }
  return out;
}

function sameNames(a, b) {
  return a.length === b.length && a.every((name, i) => name === b[i]);
}

// The output names a tab plays on: its multi list when it has one, else its
// single choice, where [''] means "follow the system default". Pure.
function wantedNames(state) {
  const list = uniqueNames(state.deviceNames);
  if (list.length > 0) return list;
  return [typeof state.deviceName === 'string' ? state.deviceName : ''];
}

// What to play on when nothing can be resolved or routed: the default output
// alone, every wanted name reported missing. Pure.
function defaultPlan(names) {
  const missing = names.filter((name) => name !== '');
  return {
    sinks: [{ name: '', sinkId: '' }],
    missing,
    status: missing.length > 0 ? 'notFound' : 'default',
    readable: true
  };
}

// Resolves a list of output names (as from wantedNames) against an
// enumerateDevices() list. Pure. Returns
//   { sinks: [{ name, sinkId }], missing: [name], status, readable }
// sinks holds one entry per distinct output that matched, in name order (two
// names that match the same output share one sink). Names that matched nothing
// are skipped and listed in missing, so the others keep playing. When nothing
// matched, sinks is the default output alone. status is "default" (no name
// asked for), "routed" (at least one name matched), "noAccess" (labels
// unreadable) or "notFound" (readable, nothing matched).
function planSinks(devices, names) {
  const wanted = names.length > 0 ? names : [''];
  const sinks = [];
  const missing = [];
  let readable = true;
  let anyAsked = false;
  for (const name of wanted) {
    const match = matchOutput(devices, name);
    readable = match.readable;
    if (name === '') continue;
    anyAsked = true;
    if (match.status === 'routed') {
      if (!sinks.some((sink) => sink.sinkId === match.sinkId)) {
        sinks.push({ name, sinkId: match.sinkId });
      }
    } else {
      missing.push(name);
    }
  }
  if (!anyAsked) return { sinks: [{ name: '', sinkId: '' }], missing: [], status: 'default', readable };
  if (sinks.length > 0) return { sinks, missing, status: 'routed', readable };
  return {
    sinks: [{ name: '', sinkId: '' }],
    missing,
    status: readable ? 'notFound' : 'noAccess',
    readable
  };
}

// Compares the outputs chains play on now with the ones wanted. Pure.
// currentIds may repeat (two chains on one output); wantedIds are distinct.
//   keep:   outputs already played on, left alone
//   move:   [{ from, to }] a surplus chain re-pointed at a missing output
//           (setSinkId on the same context, no new capture graph)
//   add:    outputs that need a new chain
//   remove: surplus outputs left over, their chains are closed
function diffSinks(currentIds, wantedIds) {
  const keep = [];
  const surplus = [];
  const seen = new Set();
  for (const id of currentIds) {
    if (wantedIds.includes(id) && !seen.has(id)) {
      seen.add(id);
      keep.push(id);
    } else {
      surplus.push(id);
    }
  }
  const needed = wantedIds.filter((id) => !seen.has(id));
  const move = [];
  while (surplus.length > 0 && needed.length > 0) {
    move.push({ from: surplus.shift(), to: needed.shift() });
  }
  return { keep, move, add: needed, remove: surplus };
}

// The status to report once routing has settled. Pure.
//   routedCount: chains playing on a planned output; failed: planned names
//   whose output could not be set up. Returns { status, missing }.
function finalStatus(plan, routedCount, failed) {
  const missing = plan.missing.concat(failed);
  // Only a plan with outputs to play on can end up routed (or fail to).
  if (plan.status !== 'routed') return { status: plan.status, missing };
  return { status: routedCount > 0 ? 'routed' : 'notFound', missing };
}

let accessSent = null; // last DEVICE_ACCESS value this document sent

function reportAccess(granted) {
  if (accessSent === granted) return;
  accessSent = granted;
  chrome.runtime.sendMessage({ target: 'background', type: 'DEVICE_ACCESS', granted })
    .catch(() => { if (accessSent === granted) accessSent = null; });
}

function reportStatus(tabId, entry, status, missing) {
  const key = missing.length > 0 ? `${status}\n${missing.join('\n')}` : status;
  if (entry.reportedStatus === key) return;
  entry.reportedStatus = key;
  chrome.runtime.sendMessage({ target: 'background', type: 'DEVICE_STATUS', tabId, status, missing })
    .catch(() => { if (entry.reportedStatus === key) entry.reportedStatus = null; });
}

async function checkAccess() {
  try {
    reportAccess(matchOutput(await navigator.mediaDevices.enumerateDevices(), '').readable);
  } catch (err) {
    // enumerateDevices failed: no new information about access.
  }
}

// Rejects if the promise has not settled within ms.
function withTimeout(promise, ms, what) {
  let timer;
  return Promise.race([
    promise,
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`${what} timed out`)), ms);
    })
  ]).finally(() => clearTimeout(timer));
}

// Moves a chain's context to an output. Resolves true when it plays there,
// and marks the chain routed. On failure the chain's sinkId is re-read from the context, so it reflects
// where the context really plays (a timed-out call may still land later).
async function trySetSink(chain, sinkId) {
  if (chain.sinkId === sinkId) {
    chain.routed = true;
    return true;
  }
  try {
    await withTimeout(chain.ctx.setSinkId(sinkId), DEVICE_CALL_TIMEOUT_MS, 'setSinkId');
    chain.sinkId = sinkId;
    chain.routed = true;
    return true;
  } catch (err) {
    console.warn(`Deci offscreen: setSinkId ${JSON.stringify(sinkId)} failed:`, err);
    if (typeof chain.ctx.sinkId === 'string') chain.sinkId = chain.ctx.sinkId;
    return false;
  }
}

// Adds a chain for one more output: a new context fed by a clone of the
// capture stream. The chain is registered at once (so SET_STATE reaches it)
// and stays silent until its output is set. Returns null when it could not be
// built or started.
async function addChain(tabId, entry) {
  let ctx = null;
  let stream = null;
  try {
    ctx = new AudioContext();
    stream = entry.stream.clone();
    const chain = buildChain(ctx, stream, true, entry.state, false);
    entry.chains.push(chain);
    await withTimeout(ctx.resume(), DEVICE_CALL_TIMEOUT_MS, 'resume');
    return chain;
  } catch (err) {
    console.warn(`Deci offscreen: extra output for tab ${tabId} failed:`, err);
    const chain = entry.chains.find((c) => c.ctx === ctx);
    if (chain) {
      entry.chains = entry.chains.filter((c) => c !== chain);
      teardownChain(chain);
    } else {
      if (stream) stopTracks(stream);
      if (ctx) ctx.close().catch(() => {});
    }
    return null;
  }
}

// Brings the entry's chains in line with the plan: keeps chains already on a
// planned output, closes the surplus ones that have no use, then re-points
// the others and adds chains for outputs still missing. The closing comes
// first so a slow move or add never leaves an old output playing next to the
// new one. Always leaves at least one chain. Gives up
// (returns null) as soon as the apply is superseded or the capture stopped;
// every step leaves the chains consistent, so the next apply starts from the
// truth. Otherwise returns the names of planned outputs that could not be set up.
async function reconcileChains(tabId, entry, plan, isCurrent) {
  const failed = [];
  for (const chain of entry.chains) {
    // A timed-out setSinkId may have landed since; trust the context.
    if (typeof chain.ctx.sinkId === 'string') chain.sinkId = chain.ctx.sinkId;
  }
  const wantedIds = plan.sinks.map((sink) => sink.sinkId);
  const nameOf = (id) => (plan.sinks.find((sink) => sink.sinkId === id) || {}).name || '';
  const diff = diffSinks(entry.chains.map((chain) => chain.sinkId), wantedIds);

  // Close the surplus first. With nothing planned, one chain stays to play on
  // the default output.
  const doomed = diff.remove.slice();
  if (wantedIds.length === 0 && doomed.length > 0) {
    doomed.splice(doomed.includes('') ? doomed.indexOf('') : 0, 1);
  }
  for (const id of doomed) {
    const chain = entry.chains.find((c) => c.sinkId === id);
    if (!chain) continue;
    entry.chains = entry.chains.filter((c) => c !== chain);
    teardownChain(chain);
  }

  for (const { from, to } of diff.move) {
    const chain = entry.chains.find((c) => c.sinkId === from);
    if (!chain) continue;
    const ok = await trySetSink(chain, to);
    if (!isCurrent()) return null;
    if (ok) connectChain(chain);
    else failed.push(nameOf(to));
  }
  for (const id of diff.add) {
    if (!isCurrent()) return null;
    const chain = await addChain(tabId, entry);
    if (!isCurrent()) return null;
    if (!chain) {
      failed.push(nameOf(id));
      continue;
    }
    const ok = await trySetSink(chain, id);
    if (!isCurrent()) return null;
    if (ok) {
      connectChain(chain);
    } else {
      entry.chains = entry.chains.filter((c) => c !== chain);
      teardownChain(chain);
      failed.push(nameOf(id));
    }
  }

  // Chains that are not on a planned output: ones whose move failed, or a chain kept for the default output.
  const planned = new Set(wantedIds);
  const keepers = entry.chains.filter((chain) => planned.has(chain.sinkId));
  let others = entry.chains.filter((chain) => !planned.has(chain.sinkId));
  if (keepers.length === 0) {
    // Nothing planned works: the tab plays on the default output, on one chain.
    const fallback = others.find((chain) => chain.sinkId === '') || others[0];
    if (fallback) {
      others = others.filter((chain) => chain !== fallback);
      if (!(await trySetSink(fallback, ''))) {
        if (!isCurrent()) return null;
        entry.chains = entry.chains.filter((c) => c !== fallback);
        teardownChain(fallback);
        const fresh = await addChain(tabId, entry);
        if (!isCurrent()) return null;
        if (fresh) connectChain(fresh);
      } else {
        if (!isCurrent()) return null;
        connectChain(fallback);
      }
    }
  }
  if (!isCurrent()) return null;
  for (const chain of others) {
    entry.chains = entry.chains.filter((c) => c !== chain);
    teardownChain(chain);
  }
  if (entry.chains.length === 0) {
    // Defensive: a tab always has a chain, on the default output at worst.
    const fresh = await addChain(tabId, entry);
    if (!isCurrent()) return null;
    if (fresh) connectChain(fresh);
  }
  return failed;
}

// Resolves and applies the entry's outputs. Runs after the previous
// resolution of the same entry (deviceQueue) and gives up as soon as a newer
// one was queued or the capture was stopped or replaced, so the latest always
// wins.
async function applyOutput(tabId, entry, gen) {
  const isCurrent = () => captures.get(tabId) === entry && entry.deviceGen === gen;
  if (!isCurrent()) return;
  const names = wantedNames(entry.state);
  let devices = null;
  try {
    devices = await withTimeout(navigator.mediaDevices.enumerateDevices(),
      DEVICE_CALL_TIMEOUT_MS, 'enumerateDevices');
  } catch (err) {
    console.warn('Deci offscreen: enumerateDevices failed:', err);
  }
  if (!isCurrent()) return;
  let plan;
  if (!devices) {
    plan = defaultPlan(names);
  } else {
    plan = planSinks(devices, names);
    reportAccess(plan.readable);
  }
  // Without setSinkId the tab cannot be routed: it stays on the default output.
  if (typeof AudioContext.prototype.setSinkId !== 'function') plan = defaultPlan(names);

  const failed = await reconcileChains(tabId, entry, plan, isCurrent);
  if (failed === null || !isCurrent()) return;
  const planned = new Set(plan.sinks.map((sink) => sink.sinkId));
  const routedCount = entry.chains.filter((chain) => planned.has(chain.sinkId)).length;
  const { status, missing } = finalStatus(plan, routedCount, failed);
  reportStatus(tabId, entry, status, missing);
}

function routeOutput(tabId, entry) {
  const gen = ++entry.deviceGen;
  entry.deviceQueue = entry.deviceQueue
    .then(() => applyOutput(tabId, entry, gen))
    .catch((err) => console.warn(`Deci offscreen: routing tab ${tabId} failed:`, err));
  return entry.deviceQueue;
}

// Resolves once the entry's queue is idle, including resolutions queued
// while waiting (a devicechange or SET_STATE during a start).
async function routeSettled(entry) {
  let queue;
  do {
    queue = entry.deviceQueue;
    await queue;
  } while (queue !== entry.deviceQueue);
}

function routeAll(forceReport) {
  for (const [tabId, entry] of captures) {
    if (forceReport) entry.reportedStatus = null;
    routeOutput(tabId, entry);
  }
}

// Plugging or unplugging an output: re-resolve every capture, so a lost
// device falls back to the default and a returning one is routed again.
let deviceChangeTimer = null;
navigator.mediaDevices.addEventListener('devicechange', () => {
  clearTimeout(deviceChangeTimer);
  deviceChangeTimer = setTimeout(() => {
    deviceChangeTimer = null;
    routeAll(false);
  }, DEVICE_CHANGE_DEBOUNCE_MS);
});

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Liveness port: the service worker reconciles captures when it disconnects.
// It also drops when the worker sleeps, so reopen it on the next message.
let livenessPort = null;
function ensureLivenessPort() {
  if (livenessPort) return;
  try {
    livenessPort = chrome.runtime.connect({ name: 'deci-offscreen' });
    livenessPort.onDisconnect.addListener(() => { livenessPort = null; });
  } catch (err) {
    livenessPort = null;
  }
}
ensureLivenessPort();

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg || msg.target !== 'offscreen') return false;
  ensureLivenessPort();
  switch (msg.type) {
    case 'START_CAPTURE':
      startCapture(msg).then(
        () => sendResponse({ ok: true }),
        (err) => {
          console.error(`Deci offscreen: capture of tab ${msg.tabId} failed:`, err);
          sendResponse({ ok: false, error: String((err && err.message) || err) });
        }
      );
      return true; // async response
    case 'SET_STATE':
      sendResponse({ ok: setState(msg) });
      return false;
    case 'STOP_CAPTURE':
      sendResponse({ ok: stopCapture(msg.tabId) });
      return false;
    case 'LIST_CAPTURES':
      sendResponse([...captures.keys()]);
      return false;
    case 'RESOLVE_DEVICES':
      // Re-check access and every route, reporting even unchanged values.
      accessSent = null;
      checkAccess();
      routeAll(true);
      sendResponse({ ok: true });
      return false;
    default:
      sendResponse({ ok: false, error: `unknown type ${msg.type}` });
      return false;
  }
});
