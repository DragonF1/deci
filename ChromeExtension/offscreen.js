/*
 * Deci Audio Companion: offscreen document.
 * Owns one Web Audio graph (a "chain") per output of a captured tab:
 *   source > align > gain > 10 x BiquadFilter (EQ) > limiter > trim > destination
 * A tab on one output has one chain. A tab in multi-output mode has one chain
 * per distinct output, each in its own AudioContext with its own setSinkId and
 * its own source node from the same tab capture (the first chain reads the
 * capture stream itself, the others read clones of it). Volume, mute and EQ
 * are applied to every chain alike. The outputs differ in latency (a Bluetooth
 * headset is a couple of hundred ms behind a wired one), so the align delay of
 * each chain is set to make them sound together (see alignChains). The destination of each chain is routed
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
const DEVICE_MISSING_GRACE_MS = 4000; // a planned output gone from the device list keeps its chain this long
const RESUME_THROTTLE_MS = 2000; // a context Chrome keeps suspending is woken by its statechange handler this often at most
const MAX_EVENT_RESUMES = 5; // wakes in a row that did not hold before the handler gives up (a routing pass tries again)
const MAX_SINKS = 8; // outputs one tab can play on at once (background.js has the same cap)
const ALIGN_INTERVAL_MS = 1000; // how often the outputs of a multi-output tab are lined up
const ALIGN_TOLERANCE_SECONDS = 0.025; // a delay is only changed when it is off by more than this (a Bluetooth latency wobbles)
const ALIGN_MAX_SECONDS = 1; // the longest delay an align node holds; a wider spread between outputs is not trusted
const ALIGN_FIRST_TICKS = 2; // passes in a row that must want the same delay before the first correction after a chain connects
const ALIGN_TICKS = 3; // the same for every correction after that
const ALIGN_MIN_GAP_SECONDS = 5; // least audio time between two corrections of one chain (each one dips it)
const ALIGN_UNKNOWN_GRACE_SECONDS = 3; // a running chain without a reported latency holds the pass back this long after it connects
const MAX_TAP_LATENCY_SECONDS = 0.5; // the most a tap latency entry may claim; a larger value is not trusted
const MAX_TAP_ENTRIES = 8; // tap latency entries kept (background.js has the same cap)
const DIP_SECONDS = 0.03; // a change that would click (a delay step, a source swap) is made this long into a trim dip
const DIP_TIME_CONSTANT = 0.004; // setTargetAtTime time constant of the dip and of the return
const SWAP_SLACK_SECONDS = 0.002; // a source swap goes ahead once the audio clock is this close to the bottom of its dip
const MAX_SWAP_WAITS = 4; // times a swap waits for a lagging audio clock before it goes ahead anyway
// The default 'interactive' hint gives WebAudio Chrome's smallest output buffer (a few ms), so the
// render thread crackles whenever the Mac is loaded or swapping. 'playback' trades a few tens of ms
// of latency for a buffer large enough to ride out those stalls; a captured tab is not interactive.
const CONTEXT_OPTIONS = { latencyHint: 'playback' };

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

// tabId -> { stream, chains, state, deviceGen, deviceQueue, reportedStatus, starting }
//   chains: one per output; empty only briefly when the floor's rebuild fails (the next pass rebuilds):
//     { ctx, stream, ownsStream, source, align, gain, filters, limiter, trim, sinkId, name, routed, connected,
//       tornDown, graceTimer, graceExpired, resumeTimer, resumeStreak, resumeDeferred,
//       alignDelay, dipEnd, refreshTimer, connectedAt, alignWant, alignVotes, alignedAt }
//     sinkId is the output the chain's context plays on ('' = system default);
//     name is the output name that last routed it; ownsStream is true for a clone that dies with the chain;
//     source is null for a clone until connectChain makes it; tornDown marks a chain we closed ourselves;
//     graceTimer/graceExpired track a missing output (see reconcileChains);
//     resumeTimer/resumeStreak/resumeDeferred throttle the statechange wake (see eventResume);
//     alignDelay is the delay asked of align, dipEnd the context time its trim dip is over, refreshTimer a pending
//     source swap (see setAlignDelay, refreshSource); connectedAt is the context time it was last connected at,
//     alignWant/alignVotes the delay a correction is waiting on and the passes in a row that wanted it, alignedAt
//     the context time of the last correction, null since it connected (see nudgeAlign).
//   starting is true until startCapture has connected the first chain.
const captures = new Map();
const pendingStarts = new Map(); // tabId -> token of the newest in-flight start
let alignTimer = null; // the pending alignment pass, only while some capture has 2 or more chains

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
  chain.tornDown = true; // our own close: the statechange handler must not revive it
  clearGrace(chain);
  clearTimeout(chain.resumeTimer);
  chain.resumeTimer = null;
  clearTimeout(chain.refreshTimer);
  chain.refreshTimer = null;
  if (chain.ownsStream) stopTracks(chain.stream);
  for (const node of [chain.source, chain.align, chain.gain, ...chain.filters, chain.limiter, chain.trim]) {
    if (!node) continue; // a clone has no source until it is connected
    try { node.disconnect(); } catch (e) { /* not connected */ }
  }
  chain.ctx.close().catch(() => {});
}

function teardown(entry) {
  stopTracks(entry.stream);
  const chains = entry.chains;
  entry.chains = [];
  for (const chain of chains) teardownChain(chain);
  syncAlign();
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
//
// The first chain has its source from the start. A clone (ownsStream) gets its source in connectChain, so it
// only exists once the output is set and the chain is about to be heard.
function buildChain(ctx, stream, ownsStream, state, routed) {
  const source = ownsStream ? null : ctx.createMediaStreamSource(stream);
  const align = ctx.createDelay(ALIGN_MAX_SECONDS);
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

  if (source) source.connect(align);
  align.connect(gain);
  let prev = gain;
  for (const filter of filters) {
    prev.connect(filter);
    prev = filter;
  }
  prev.connect(limiter);
  limiter.connect(trim);

  const chain = {
    ctx, stream, ownsStream, source, align, gain, filters, limiter, trim, sinkId: '', name: '', routed, connected: false,
    tornDown: false, graceTimer: null, graceExpired: false, resumeTimer: null, resumeStreak: 0, resumeDeferred: false,
    alignDelay: 0, dipEnd: 0, refreshTimer: null, connectedAt: 0, alignWant: null, alignVotes: 0, alignedAt: null
  };
  // Chrome stops a context on its own at times (a device error, a headset changing profile).
  ctx.addEventListener('statechange', () => onChainState(chain));
  // The output restarted without going through trySetSink (a setSinkId that timed out and landed later, Chrome
  // moving a default-output context to a new default device): the same stale backlog. A swap already pending
  // covers this one too.
  ctx.addEventListener('sinkchange', () => refreshSource(chain));
  return chain;
}

// A context changed state. One that stopped is woken (eventResume); one that is running again has a backlog in
// its source from the stop, which refreshSource replaces.
function onChainState(chain) {
  const running = chain.ctx.state === 'running';
  eventResume(chain);
  if (running) refreshSource(chain);
}

// Wakes a context that is not running, unless we closed it. Best effort.
function wakeChain(chain) {
  const state = chain.ctx.state;
  if (chain.tornDown || state === 'running' || state === 'closed') return;
  chain.ctx.resume().catch(() => {});
}

// The wake a routing pass gives a chain: the slow retry, and a fresh allowance for eventResume.
function resumeChain(chain) {
  chain.resumeStreak = 0;
  wakeChain(chain);
}

// The wake for a context that just suspended. A device that keeps failing suspends the context again after
// every wake, and each wake opens the output once more (a headset hears that as a drop), so this wakes at
// most once per RESUME_THROTTLE_MS: a suspension inside the window is wakened when it ends. After
// MAX_EVENT_RESUMES wakes in a row that did not hold it stops, until a routing pass or a calm window.
function eventResume(chain) {
  if (chain.tornDown || chain.ctx.state !== 'suspended') return;
  if (chain.resumeTimer) {
    chain.resumeDeferred = true;
    return;
  }
  if (chain.resumeStreak >= MAX_EVENT_RESUMES) return;
  chain.resumeStreak++;
  wakeChain(chain);
  chain.resumeTimer = setTimeout(() => {
    chain.resumeTimer = null;
    const again = chain.resumeDeferred && chain.ctx.state === 'suspended';
    chain.resumeDeferred = false;
    if (again) eventResume(chain);
    else chain.resumeStreak = 0; // a whole window without a new suspension: calm again
  }, RESUME_THROTTLE_MS);
}

// Lets a chain be heard. Idempotent. A clone gets its source here (see buildChain). If the source cannot be
// made the chain stays silent and the next routing pass tries again.
function connectChain(chain) {
  if (chain.connected || chain.tornDown) return;
  if (!chain.source) {
    try {
      const source = chain.ctx.createMediaStreamSource(chain.stream);
      source.connect(chain.align);
      chain.source = source;
    } catch (err) {
      console.warn('Deci offscreen: attaching the source of an extra output failed:', err);
      return;
    }
  }
  chain.trim.connect(chain.ctx.destination);
  chain.connected = true;
  chain.connectedAt = chain.ctx.currentTime;
  chain.alignedAt = null; // the first correction after it connects is quicker (see nudgeAlign)
  clearVotes(chain);
}

// Dips a chain's trim to near silence, for a change that would click if it were heard. It starts once a dip still
// running is over, and returns the context time at which the trim is down and the change can be made. Nothing else
// automates the trim (setState does the gain and the EQ), so the only dip it can meet is another one.
function dipTrim(chain) {
  const start = Math.max(chain.ctx.currentTime, chain.dipEnd);
  chain.trim.gain.setTargetAtTime(0, start, DIP_TIME_CONSTANT);
  chain.dipEnd = start + DIP_SECONDS;
  return chain.dipEnd;
}

// A source node buffers its stream in a FIFO of its own (about 180 ms). Once the node has been pulled, any stop in
// the pulling (the context suspended, its output restarted by setSinkId) leaves a backlog there that is never
// trimmed and plays as extra delay for good. A new source starts empty, so a heard chain swaps its source for a
// new one under a trim dip. A chain nobody hears has not been pulled, so it keeps its source. One swap at a time:
// a trigger while one is pending is covered by it.
function refreshSource(chain) {
  if (!chain.connected || chain.tornDown || !chain.source || chain.refreshTimer || chain.ctx.state === 'closed') return;
  waitToSwap(chain, dipTrim(chain), 0);
}

// The swap is timed on the wall clock but the dip runs on the audio clock, which can lag it (a slow device start, a
// suspend, a render stall). A swap that fires before the audio clock is down in the dip waits out the rest of it, up
// to MAX_SWAP_WAITS times, so it is made under the dip; a context that is not running has no dip to wait for. The
// trim comes back no earlier than the end of the dip, whatever the clocks say: a restore that sorted before a
// dip queued behind another one would leave the trim at 0.
function waitToSwap(chain, step, waits) {
  const ctx = chain.ctx;
  chain.refreshTimer = setTimeout(() => {
    chain.refreshTimer = null;
    if (chain.tornDown) return;
    if (ctx.state === 'running' && waits < MAX_SWAP_WAITS && ctx.currentTime < step - SWAP_SLACK_SECONDS) {
      waitToSwap(chain, step, waits + 1);
      return;
    }
    try {
      const next = ctx.createMediaStreamSource(chain.stream);
      next.connect(chain.align);
      const old = chain.source;
      chain.source = next;
      old.disconnect();
    } catch (err) {
      console.warn('Deci offscreen: swapping the source failed:', err);
    }
    // A later dip (a delay change queued meanwhile) brings the trim back itself.
    if (chain.dipEnd === step) chain.trim.gain.setTargetAtTime(TRIM_GAIN, Math.max(ctx.currentTime, step), DIP_TIME_CONSTANT);
  }, Math.max(0, (step - ctx.currentTime) * 1000));
}

// ---------------------------------------------------------------------------
// Output alignment
// ---------------------------------------------------------------------------

// The Deci app taps the audio of some outputs (a Core Audio process tap) and plays it again, which delays that
// output by an amount Chrome cannot see. The app measures it per tapped device and sends it as SET_TAP_LATENCY;
// each message replaces the list. [{ deviceName, seconds }], empty when no output is tapped.
let tapLatency = [];
// deviceId -> label of the audio outputs the last enumerateDevices() listed, 'default' included. A chain on the
// default output has no name of its own (see chainLabels), so its label is read from here.
let outputLabels = new Map();

// A tap latency list as sent by the app: entries with a non-blank string deviceName and a finite number of seconds
// from 0 to MAX_TAP_LATENCY_SECONDS, the first MAX_TAP_ENTRIES of them, as fresh objects. Anything else is dropped.
// Pure.
function sanitizeTapLatency(devices) {
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

// SET_TAP_LATENCY: replaces the list and lets the alignment timer pick it up. A change moves nothing at once: the
// next passes see the new latencies and correct under the usual tolerance, vote and gap rules (see nudgeAlign).
function setTapLatency(devices) {
  tapLatency = sanitizeTapLatency(devices);
  syncAlign();
}

function noteOutputLabels(devices) {
  const next = new Map();
  for (const device of Array.isArray(devices) ? devices : []) {
    if (device && device.kind === 'audiooutput' && typeof device.deviceId === 'string' &&
        typeof device.label === 'string' && device.label !== '') {
      next.set(device.deviceId, device.label);
    }
  }
  outputLabels = next;
}

// The names an output of a chain goes by, best first. chain.name is the name that routed it: the one the app asked
// for, which can be shorter than Chrome's label for the device (matchOutput takes "contains"). A chain on the
// default output has no name (''), so it is known by the label of the 'default' device entry instead
// ("Default - WH-1000XM5"). The label of the chain's own sink comes second.
function chainLabels(chain) {
  const labels = [];
  if (typeof chain.name === 'string' && chain.name !== '') labels.push(chain.name);
  const onDefault = chain.sinkId === '' || chain.sinkId === 'default';
  const label = outputLabels.get(onDefault ? 'default' : chain.sinkId);
  if (label && !labels.includes(label)) labels.push(label);
  return labels;
}

// The tap entry for an output label, by the rules matchOutput uses to find a device from a name: the entry's
// deviceName equals the label, else the label starts with deviceName + " (", else contains it (any case).
function matchTapEntry(label) {
  const lower = label.toLowerCase();
  return tapLatency.find((entry) => label === entry.deviceName) ||
    tapLatency.find((entry) => label.startsWith(`${entry.deviceName} (`)) ||
    tapLatency.find((entry) => lower.includes(entry.deviceName.toLowerCase())) ||
    null;
}

// Seconds the tap adds to a chain's output; 0 when no entry matches it.
function extraLatency(chain) {
  if (tapLatency.length === 0) return 0;
  for (const label of chainLabels(chain)) {
    const entry = matchTapEntry(label);
    if (entry) return entry.seconds;
  }
  return 0;
}

// Seconds from a chain's graph to its speaker, the tap's included; 0 when unknown (the context is not running, or
// Chrome has not reported an output latency yet). The tap adds to a known latency only: an unknown one stays 0,
// so the unknown-latency handling in alignChains is unchanged.
function chainLatency(chain) {
  const out = chain.ctx.outputLatency;
  if (chain.ctx.state !== 'running' || !Number.isFinite(out) || out <= 0) return 0;
  return (chain.ctx.baseLatency || 0) + out + extraLatency(chain);
}

// Sets the delay at the head of a chain. A heard chain dips its trim around the step so it does not click, a
// chain nobody hears yet is set directly. The trim comes back even if the step throws.
function setAlignDelay(chain, seconds) {
  const value = Math.min(ALIGN_MAX_SECONDS, Math.max(0, seconds));
  if (value === chain.alignDelay) return;
  if (!chain.connected) {
    chain.align.delayTime.value = value;
    chain.alignDelay = value;
    return;
  }
  const step = dipTrim(chain);
  try {
    chain.align.delayTime.setValueAtTime(value, step);
    chain.alignDelay = value;
  } finally {
    chain.trim.gain.setTargetAtTime(TRIM_GAIN, Math.max(chain.ctx.currentTime, step), DIP_TIME_CONSTANT);
  }
}

function clearVotes(chain) {
  chain.alignWant = null;
  chain.alignVotes = 0;
}

// Whether a chain makes sound: heard, and its context running. A suspended or closed context, or a chain held for
// a missing output, is silent whatever its latency says.
function isHeard(chain) {
  return chain.connected && !chain.tornDown && !chain.graceTimer && chain.ctx.state === 'running';
}

// Moves a chain's delay toward the delay it is wanted at, once the want has held. A correction dips the chain, and
// the reported latency wobbles (it comes in steps, and a Bluetooth sink can move by more than the tolerance), so
// nothing moves for a want that is within ALIGN_TOLERANCE_SECONDS of the delay in place, nor until the same want
// (within the tolerance) has come up on ALIGN_TICKS passes in a row (ALIGN_FIRST_TICKS for the first correction
// after the chain connects), nor within ALIGN_MIN_GAP_SECONDS of the last correction of this chain.
function nudgeAlign(chain, want) {
  if (Math.abs(want - chain.alignDelay) <= ALIGN_TOLERANCE_SECONDS) {
    clearVotes(chain);
    return;
  }
  if (chain.alignWant !== null && Math.abs(want - chain.alignWant) <= ALIGN_TOLERANCE_SECONDS) {
    chain.alignVotes++;
  } else {
    chain.alignWant = want;
    chain.alignVotes = 1;
  }
  const first = chain.alignedAt === null;
  const now = chain.ctx.currentTime;
  if (chain.alignVotes < (first ? ALIGN_FIRST_TICKS : ALIGN_TICKS)) return;
  if (!first && now - chain.alignedAt < ALIGN_MIN_GAP_SECONDS) return;
  chain.alignedAt = now;
  clearVotes(chain);
  setAlignDelay(chain, want);
}

// One alignment pass over a capture. The faster outputs are delayed to match the slowest: a chain's delay is the
// largest latency among the capture's heard chains minus its own (see nudgeAlign for when it is moved). Only
// chains that make sound take part. A running chain that has not reported a latency holds the whole pass back for
// ALIGN_UNKNOWN_GRACE_SECONDS after it connects, and is left out after that rather than freezing the others; the
// pass is also skipped when the spread is more than ALIGN_MAX_SECONDS. With fewer than 2 chains that report a
// latency there is nothing to line up with, and the delays go back to 0. A capture down to one chain does it at once.
function alignChains(entry) {
  const chains = entry.chains;
  if (chains.length < 2) {
    for (const chain of chains) {
      clearVotes(chain);
      setAlignDelay(chain, 0);
    }
    return;
  }
  const heard = chains.filter(isHeard);
  const latency = new Map(heard.map((chain) => [chain, chainLatency(chain)]));
  const skip = () => chains.forEach(clearVotes); // a skipped pass breaks every run of agreeing ones
  if (heard.some((chain) => latency.get(chain) === 0 && chain.ctx.currentTime - chain.connectedAt < ALIGN_UNKNOWN_GRACE_SECONDS)) {
    skip();
    return;
  }
  const known = heard.filter((chain) => latency.get(chain) > 0);
  if (known.length < 2) {
    for (const chain of chains) nudgeAlign(chain, 0);
    return;
  }
  const target = Math.max(...known.map((chain) => latency.get(chain)));
  if (target - Math.min(...known.map((chain) => latency.get(chain))) > ALIGN_MAX_SECONDS) {
    skip();
    return;
  }
  for (const chain of known) nudgeAlign(chain, target - latency.get(chain));
}

function alignSafely(tabId, entry) {
  try {
    alignChains(entry);
  } catch (err) {
    console.warn(`Deci offscreen: aligning the outputs of tab ${tabId} failed:`, err);
  }
}

function alignTick() {
  alignTimer = null;
  for (const [tabId, entry] of captures) alignSafely(tabId, entry);
  syncAlign();
}

// Keeps the alignment timer in step with the captures: pending while one has 2 or more chains, stopped when none
// does. A self-rescheduling setTimeout, not an interval. When it stops, a chain left alone with a delay gets it
// reset here, since no tick is coming to do it.
function syncAlign() {
  if ([...captures.values()].some((entry) => entry.chains.length >= 2)) {
    if (!alignTimer) alignTimer = setTimeout(alignTick, ALIGN_INTERVAL_MS);
    return;
  }
  clearTimeout(alignTimer);
  alignTimer = null;
  for (const [tabId, entry] of captures) alignSafely(tabId, entry);
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
    ctx = new AudioContext(CONTEXT_OPTIONS);
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
    deviceGen: 0, deviceQueue: Promise.resolve(), reportedStatus: null, starting: true
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
  entry.starting = false;
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
// A context already running on that output is left alone: setSinkId would restart its stream.
async function trySetSink(chain, sinkId) {
  const current = typeof chain.ctx.sinkId === 'string' ? chain.ctx.sinkId : chain.sinkId;
  // A context Chrome stopped still reports its sink, so only a running one is taken at its word.
  if (current === sinkId && chain.ctx.state === 'running') {
    chain.sinkId = sinkId;
    chain.routed = true;
    return true;
  }
  try {
    await withTimeout(chain.ctx.setSinkId(sinkId), DEVICE_CALL_TIMEOUT_MS, 'setSinkId');
    chain.sinkId = sinkId;
    chain.routed = true;
    refreshSource(chain); // the move restarted the output, so what the source buffered meanwhile is stale
    return true;
  } catch (err) {
    console.warn(`Deci offscreen: setSinkId ${JSON.stringify(sinkId)} failed:`, err);
    if (typeof chain.ctx.sinkId === 'string') chain.sinkId = chain.ctx.sinkId;
    return false;
  } finally {
    // After the move, and only if it is still stopped: waking it first would open the old output for nothing.
    resumeChain(chain);
  }
}

// A context for the output sinkId ('' = the default). One for a known output is built on it, which skips starting
// on the default device and the restart a later setSinkId costs. If the constructor throws, the plain one is used;
// trySetSink still checks where the context really plays.
function newContext(sinkId) {
  if (sinkId) {
    try {
      return new AudioContext({ ...CONTEXT_OPTIONS, sinkId });
    } catch (err) {
      console.warn(`Deci offscreen: AudioContext on ${JSON.stringify(sinkId)} failed, starting on the default output:`, err);
    }
  }
  return new AudioContext(CONTEXT_OPTIONS);
}

// Adds a chain for one more output: a new context fed by a clone of the
// capture stream. The chain is registered at once (so SET_STATE reaches it)
// and stays silent until its output is set. sinkId is that output, when it is
// already known. Returns null when it could not be built or started.
async function addChain(tabId, entry, sinkId = '') {
  let ctx = null;
  let stream = null;
  try {
    ctx = newContext(sinkId);
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

function clearGrace(chain) {
  clearTimeout(chain.graceTimer);
  chain.graceTimer = null;
  chain.graceExpired = false;
}

// Whether a chain that would be closed may stay open: its output is one the
// tab still asks for (in plan.missing) and has been gone for less than
// DEVICE_MISSING_GRACE_MS. A chain whose output was unticked has no claim, and
// neither has one whose context Chrome already re-routed to the default output
// (it would double the tab there).
function canHold(chain, plan) {
  return plan.missing.includes(chain.name) && !chain.graceExpired && chain.ctx.sinkId !== '';
}

// True while canHold. A headset flipping profile drops off the device list
// and comes back, and closing and reopening its context each time can flip it
// again. The first call starts the clock and, when it runs out, applies again
// so the chain is closed even if nothing else happens.
function inGrace(tabId, entry, chain, plan) {
  if (!canHold(chain, plan)) return false;
  if (!chain.graceTimer) {
    chain.graceTimer = setTimeout(() => {
      chain.graceTimer = null;
      chain.graceExpired = true;
      if (!chain.tornDown && captures.get(tabId) === entry) routeOutput(tabId, entry);
    }, DEVICE_MISSING_GRACE_MS);
  }
  return true;
}

// A chain just set on an output (name, '' for the default): heard at once, and
// no longer waiting out a missing device.
function landChain(chain, name) {
  chain.name = name;
  clearGrace(chain);
  connectChain(chain);
}

// Brings the entry's chains in line with the plan: keeps chains already on a
// planned output, closes the surplus ones that have no use, then re-points
// the others and adds chains for outputs still missing. The closing comes
// first so a slow move or add never leaves an old output playing next to the
// new one. Always leaves at least one chain. A chain whose output went missing
// from the device list is held for DEVICE_MISSING_GRACE_MS before it is closed
// (see inGrace); under a fallback plan (labels unreadable, nothing matched) the
// held chains are left exactly as they are, and a chain is never held while
// another is moved onto the default output. A chain is heard as soon as it is set on its output, so a
// superseded apply never leaves one routed but silent. Gives up
// (returns null) as soon as the apply is superseded or the capture stopped;
// every step leaves the chains consistent, so the next apply starts from the
// truth. Otherwise returns the names of planned outputs that could not be set up.
async function reconcileChains(tabId, entry, plan, isCurrent) {
  const failed = [];
  for (const chain of entry.chains.slice()) {
    if (chain.ctx.state === 'closed') {
      // Chrome closed it, not us, and a closed context cannot come back: drop
      // it, and the diff below builds a new chain on its output.
      entry.chains = entry.chains.filter((c) => c !== chain);
      teardownChain(chain);
      continue;
    }
    resumeChain(chain);
    // A timed-out setSinkId may have landed since; trust the context.
    if (typeof chain.ctx.sinkId === 'string') chain.sinkId = chain.ctx.sinkId;
  }
  const wantedIds = plan.sinks.map((sink) => sink.sinkId);
  const nameOf = (id) => (plan.sinks.find((sink) => sink.sinkId === id) || {}).name || '';
  for (const chain of entry.chains) {
    // On a planned output: its device is here, so any grace period is over.
    if (wantedIds.includes(chain.sinkId)) {
      chain.name = nameOf(chain.sinkId);
      clearGrace(chain);
    }
  }
  // A fallback plan is no reason to touch a chain whose output is only missing for now (a headset whose
  // labels blank during a profile flip): if every chain off the planned outputs can be held, hold them all
  // and change nothing, so no setSinkId restarts a stream and nothing doubles on the default output.
  if (plan.status !== 'routed') {
    const off = entry.chains.filter((chain) => !wantedIds.includes(chain.sinkId));
    if (off.length > 0 && off.every((chain) => canHold(chain, plan))) {
      for (const chain of off) inGrace(tabId, entry, chain, plan);
      return failed;
    }
  }
  const diff = diffSinks(entry.chains.map((chain) => chain.sinkId), wantedIds);
  // Once a chain plays on the default output, no other chain is held next to it.
  let onDefault = diff.move.some((move) => move.to === '') || diff.add.includes('');

  // Close the surplus first. With nothing planned, one chain stays to play on
  // the default output.
  const doomed = diff.remove.slice();
  if (wantedIds.length === 0 && doomed.length > 0) {
    doomed.splice(doomed.includes('') ? doomed.indexOf('') : 0, 1);
  }
  const held = new Set();
  for (const id of doomed) {
    const chain = entry.chains.find((c) => c.sinkId === id && !held.has(c));
    if (!chain) continue;
    if (!onDefault && inGrace(tabId, entry, chain, plan)) {
      held.add(chain);
      continue;
    }
    entry.chains = entry.chains.filter((c) => c !== chain);
    teardownChain(chain);
  }

  for (const { from, to } of diff.move) {
    const chain = entry.chains.find((c) => c.sinkId === from);
    if (!chain) continue;
    const ok = await trySetSink(chain, to);
    if (ok) landChain(chain, nameOf(to)); // before the bail: a superseded apply must not leave it silent
    if (!isCurrent()) return null;
    if (!ok) failed.push(nameOf(to));
  }
  for (const id of diff.add) {
    if (!isCurrent()) return null;
    const chain = await addChain(tabId, entry, id);
    if (!isCurrent()) return null;
    if (!chain) {
      failed.push(nameOf(id));
      continue;
    }
    const ok = await trySetSink(chain, id);
    if (ok) landChain(chain, nameOf(id));
    if (!isCurrent()) return null;
    if (!ok) {
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
        if (fresh) {
          connectChain(fresh);
          onDefault = true;
        }
        if (!isCurrent()) return null;
      } else {
        landChain(fallback, '');
        onDefault = true;
        if (!isCurrent()) return null;
      }
    }
  }
  if (!isCurrent()) return null;
  for (const chain of others) {
    if (!onDefault && inGrace(tabId, entry, chain, plan)) continue;
    entry.chains = entry.chains.filter((c) => c !== chain);
    teardownChain(chain);
  }
  if (entry.chains.length === 0) {
    // Defensive: a tab always has a chain, on the default output at worst.
    const fresh = await addChain(tabId, entry);
    if (fresh) connectChain(fresh);
    if (!isCurrent()) return null;
  }
  // A chain routed on a planned output is heard, whatever an earlier superseded
  // apply left undone (the keep path above never connects).
  for (const chain of entry.chains) {
    if (chain.routed && planned.has(chain.sinkId)) connectChain(chain);
  }
  return failed;
}

// Resolves and applies the entry's outputs. Runs after the previous
// resolution of the same entry (deviceQueue) and gives up as soon as a newer
// one was queued or the capture was stopped or replaced, so the latest always
// wins.
async function resolveOutput(tabId, entry, gen) {
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
  if (devices) noteOutputLabels(devices); // fresh whether or not this pass is still wanted
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
  // Only a chain that is routed and heard counts as playing on its output.
  const routedCount = entry.chains.filter((chain) =>
    planned.has(chain.sinkId) && chain.routed && chain.connected).length;
  const { status, missing } = finalStatus(plan, routedCount, failed);
  reportStatus(tabId, entry, status, missing);
}

// A captured tab is muted locally, so a live capture must never be left with
// nothing connected: it would play nowhere. Connects one chain on the default
// output (building one if needed). Left alone while startCapture is still
// choosing the first output, which connects the first chain itself, and by a
// pass that a newer one superseded (gen), which would only move a chain to the
// default output for the newer pass to move it back.
async function ensureAudible(tabId, entry, gen) {
  const alive = () => captures.get(tabId) === entry;
  if (!alive() || entry.starting || entry.deviceGen !== gen) return;
  const live = entry.chains.filter((chain) => chain.ctx.state !== 'closed');
  if (live.some((chain) => chain.connected)) return;
  try {
    const chain = live.find((c) => c.sinkId === '') || live[0];
    if (chain) {
      if (await trySetSink(chain, '')) {
        landChain(chain, '');
        return;
      }
      if (!alive()) return;
      // Release the chain that would not move, or it lingers silent next to the new one.
      entry.chains = entry.chains.filter((c) => c !== chain);
      teardownChain(chain);
    }
    if (!alive()) return;
    const fresh = await addChain(tabId, entry);
    if (fresh) landChain(fresh, '');
  } catch (err) {
    console.warn(`Deci offscreen: restoring the default output of tab ${tabId} failed:`, err);
  }
}

// One routing pass, then the floor: it runs however the pass ended (done, given
// up for a newer one, or failed).
async function applyOutput(tabId, entry, gen) {
  try {
    await resolveOutput(tabId, entry, gen);
  } finally {
    await ensureAudible(tabId, entry, gen);
    syncAlign(); // chains came or went
  }
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
    case 'SET_TAP_LATENCY':
      // Global, not per tab (no tabId): the tap latency of each tapped output device. Not part of mergeState.
      setTapLatency(msg.devices);
      sendResponse({ ok: true });
      return false;
    default:
      sendResponse({ ok: false, error: `unknown type ${msg.type}` });
      return false;
  }
});
