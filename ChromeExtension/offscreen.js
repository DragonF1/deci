/*
 * Deci Audio Companion: offscreen document.
 * Owns one Web Audio graph per captured tab:
 *   source > gain > 10 x BiquadFilter (EQ) > limiter > trim > destination
 * The destination of each graph is routed to the tab's output device with
 * AudioContext.setSinkId (resolved by device name, re-resolved on
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

// tabId -> { stream, ctx, source, gain, filters, limiter, trim, state,
//            deviceGen, deviceQueue, reportedStatus }
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
      : (typeof base.deviceName === 'string' ? base.deviceName : '')
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

function teardown(entry) {
  stopTracks(entry.stream);
  for (const node of [entry.source, entry.gain, ...entry.filters, entry.limiter, entry.trim]) {
    try { node.disconnect(); } catch (e) { /* not connected */ }
  }
  entry.ctx.close().catch(() => {});
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

  const entry = {
    stream, ctx, source, gain, filters, limiter, trim, state,
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
  // Pick the sink before anything reaches the destination, so a routed tab
  // never blips on the default output first (capped for slow devices).
  routeOutput(tabId, entry);
  // A fresh context already plays on the default output, so only a named
  // device is worth waiting for.
  if (entry.state.deviceName) {
    await Promise.race([routeSettled(entry), delay(FIRST_ROUTE_TIMEOUT_MS)]);
  }
  // Stopped, ended or replaced meanwhile: that path already tore it down.
  if (captures.get(tabId) !== entry) throw new Error('capture stopped while starting');
  trim.connect(ctx.destination);
}

function setState(msg) {
  const entry = captures.get(msg.tabId);
  if (!entry) return false;
  const next = mergeState(entry.state, msg);
  const now = entry.ctx.currentTime;
  entry.gain.gain.setTargetAtTime(targetGain(next), now, SMOOTHING_SECONDS);
  for (let i = 0; i < entry.filters.length; i++) {
    if (next.eqBands[i] !== entry.state.eqBands[i]) {
      entry.filters[i].gain.setTargetAtTime(next.eqBands[i], now, SMOOTHING_SECONDS);
    }
  }
  const deviceChanged = next.deviceName !== entry.state.deviceName;
  entry.state = next;
  if (deviceChanged) {
    // The service worker shows "pending" after a device change, so the
    // first result for the new name is always reported.
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

let accessSent = null; // last DEVICE_ACCESS value this document sent

function reportAccess(granted) {
  if (accessSent === granted) return;
  accessSent = granted;
  chrome.runtime.sendMessage({ target: 'background', type: 'DEVICE_ACCESS', granted })
    .catch(() => { if (accessSent === granted) accessSent = null; });
}

function reportStatus(tabId, entry, status) {
  if (entry.reportedStatus === status) return;
  entry.reportedStatus = status;
  chrome.runtime.sendMessage({ target: 'background', type: 'DEVICE_STATUS', tabId, status })
    .catch(() => { if (entry.reportedStatus === status) entry.reportedStatus = null; });
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

// Resolves and applies the entry's sink. Runs after the previous resolution
// of the same entry (deviceQueue) and gives up as soon as a newer one was
// queued or the capture was stopped or replaced, so the latest always wins.
async function applyOutput(tabId, entry, gen) {
  const isCurrent = () => captures.get(tabId) === entry && entry.deviceGen === gen;
  if (!isCurrent()) return;
  const name = entry.state.deviceName;
  let devices = null;
  try {
    devices = await withTimeout(navigator.mediaDevices.enumerateDevices(),
      DEVICE_CALL_TIMEOUT_MS, 'enumerateDevices');
  } catch (err) {
    console.warn('Deci offscreen: enumerateDevices failed:', err);
  }
  if (!isCurrent()) return;
  let sinkId = '';
  let status = name ? 'notFound' : 'default';
  if (devices) {
    const result = matchOutput(devices, name);
    reportAccess(result.readable);
    sinkId = result.sinkId;
    status = result.status;
  }
  const ctx = entry.ctx;
  if (typeof ctx.setSinkId !== 'function') {
    if (sinkId) status = 'notFound'; // cannot route: stays on the default output
  } else if (ctx.sinkId !== sinkId) {
    try {
      await withTimeout(ctx.setSinkId(sinkId), DEVICE_CALL_TIMEOUT_MS, 'setSinkId');
    } catch (err) {
      if (!isCurrent()) return;
      console.warn(`Deci offscreen: setSinkId for tab ${tabId} failed:`, err);
      status = name ? 'notFound' : 'default';
      if (ctx.sinkId !== '') {
        await withTimeout(ctx.setSinkId(''), DEVICE_CALL_TIMEOUT_MS, 'setSinkId').catch(() => {});
      }
    }
  }
  if (!isCurrent()) return;
  reportStatus(tabId, entry, status);
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
