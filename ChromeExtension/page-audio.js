/*
 * Deci Audio Companion: in-page audio (content script, every frame).
 * The fallback for tabs that are not tab-captured while auto mode is on: the
 * frame's media elements are routed through one small Web Audio graph so the
 * tab still gets volume, boost and EQ:
 *
 *   sources > input > volume > 10 x BiquadFilter (EQ) > limiter > trim > wet >
 *                 \__ dry ___________________________________________________/ > destination
 *
 * Idle until the frame sees a media element: no message, no AudioContext.
 * Elements are routed only once they play (the source has settled by then).
 * Mute is not handled here (the worker uses the tab mute). Messages are in
 * the contract at the top of background.js (PAGE_HELLO, PAGE_STATUS,
 * PAGE_STATE, PAGE_ASK).
 *
 * Safety: a routed element cannot be un-routed, and Web Audio plays silence
 * for media it may not read. So nothing doubtful is routed, an element that
 * later turns unreadable is reported (the worker turns the tab dry and stops
 * routing on that origin), and a copy cut off from the extension (reload or
 * update) goes dry for good: dry is unity and unprocessed, never silent.
 *
 * Wrapped in a function because the same file can run twice in one isolated
 * world (manifest content script plus executeScript), and a second top-level
 * const would throw.
 */
(function () {
  'use strict';

  // Same values as offscreen.js, so a page-controlled tab sounds like a captured one.
  const FREQUENCIES = [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
  const FILTER_Q = 1.41;
  const SMOOTHING_SECONDS = 0.015; // setTargetAtTime time constant
  const EQ_LIMIT_DB = 30;
  const LIMITER = { threshold: -1, knee: 0, ratio: 20, attack: 0.003, release: 0.25 };
  // Cancels the limiter's automatic makeup gain (derivation in offscreen.js).
  const TRIM_GAIN = Math.pow(10, (LIMITER.threshold + (0 - LIMITER.threshold) / LIMITER.ratio) * 0.6 / 20);

  const HAVE_METADATA = 1; // HTMLMediaElement.readyState
  const RESUME_WAIT_MS = 300;
  const ORPHAN_CHECK_MS = 2000;
  const MEDIA_EVENTS = ['loadstart', 'play', 'playing', 'encrypted'];

  // -------------------------------------------------------------------------
  // Eligibility (pure)
  // -------------------------------------------------------------------------

  // Opaque origins ('null') never count as same-origin.
  function sameOrigin(src, loc) {
    if (!loc || !loc.origin || loc.origin === 'null') return false;
    try { return new URL(src, loc.href).origin === loc.origin; } catch (e) { return false; }
  }

  // Whether routing el through Web Audio is safe. Web Audio outputs silence
  // for CORS cross-origin media and createMediaElementSource cannot be undone,
  // so an element is only routed when its audio is known to be readable.
  // Encrypted (EME) media and elements playing to their own output device
  // (sinkId) are left alone.
  // el: { srcObject, currentSrc, src, crossOrigin, readyState, mediaKeys, sinkId },
  // loc: { href, origin }.
  function isEligible(el, loc) {
    if (el.srcObject || el.mediaKeys || el.sinkId) return false;
    const src = el.currentSrc || el.src || '';
    if (!src) return false; // nothing loading yet: wait for the next event
    if (/^(blob|data):/i.test(src)) return true; // MSE players and inline media
    if (sameOrigin(src, loc)) return true;
    // A crossOrigin attribute plus loaded metadata means the CORS load worked.
    return typeof el.crossOrigin === 'string' && el.readyState >= HAVE_METADATA;
  }

  // A plain same-origin src can still redirect to another origin, which Web
  // Audio would read as silence: such a src is checked with a request first.
  // With a crossOrigin attribute a redirect needs CORS, so no check is needed.
  function needsProbe(el, loc) {
    const src = el.currentSrc || el.src || '';
    return typeof el.crossOrigin !== 'string' && !/^(blob|data):/i.test(src) && sameOrigin(src, loc);
  }

  // Whether a routed element now plays something Web Audio cannot read. An
  // element with a crossOrigin attribute never does: a failed CORS check
  // fails its whole load instead.
  function turnedUnsafe(el, loc) {
    if (el.mediaKeys) return true;
    const src = el.currentSrc || el.src || '';
    if (!src || el.srcObject || typeof el.crossOrigin === 'string') return false;
    return !isEligible(el, loc);
  }

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = { isEligible, sameOrigin, needsProbe, turnedUnsafe };
    return;
  }
  if (globalThis.__deciPageAudio) return;
  globalThis.__deciPageAudio = true;

  // -------------------------------------------------------------------------
  // State from the service worker
  // -------------------------------------------------------------------------

  let state = { on: false, volume: 1, boost: 1, eqBands: new Array(FREQUENCIES.length).fill(0) };
  let pushed = false;   // a PAGE_STATE arrived, so an older PAGE_HELLO reply is stale
  let greeted = false;  // PAGE_HELLO sent
  let reported = false; // PAGE_STATUS sent for the current on period
  let sawMedia = false;  // the frame has seen a media element
  let blocked = false;   // a routed element turned unsafe: route nothing more
  let orphaned = false;  // cut off from the extension: dry for good

  function clampNumber(value, min, max, fallback) {
    const n = Number(value);
    return Number.isFinite(n) ? Math.min(max, Math.max(min, n)) : fallback;
  }

  // Merges the defined fields of msg over base and clamps them (as offscreen.js does).
  function mergeState(base, msg) {
    const bands = Array.isArray(msg.eqBands) ? msg.eqBands : [];
    return {
      on: msg.on === true,
      volume: clampNumber(msg.volume, 0, 1, base.volume),
      boost: Math.round(clampNumber(msg.boost, 1, 4, base.boost)),
      eqBands: base.eqBands.map((old, i) => clampNumber(bands[i], -EQ_LIMIT_DB, EQ_LIMIT_DB, old))
    };
  }

  async function send(message) {
    return chrome.runtime.sendMessage(message);
  }

  // chrome.runtime.id is gone once the extension reloads, updates or is removed.
  function extensionAlive() {
    try { return !!(chrome.runtime && chrome.runtime.id); } catch (e) { return false; }
  }

  // -------------------------------------------------------------------------
  // Web Audio graph (one per frame, created with the first routed element)
  // -------------------------------------------------------------------------

  let ctx = null;
  let graph = null;
  let hasRouted = false;
  let needsRoute = false; // an eligible element waited for a running context
  const routed = new WeakMap();    // element -> its source node
  const routing = new WeakSet();   // routing in progress
  const unroutable = new WeakSet(); // the page owns a source node for it, or it is encrypted
  const probes = new Map(); // same-origin src -> Promise<boolean> (answers without a redirect)
  let orphanTimer = null;

  function createGraph(c) {
    const input = c.createGain();
    const volume = c.createGain();
    const filters = FREQUENCIES.map((frequency, i) => {
      const filter = c.createBiquadFilter();
      if (i === 0) filter.type = 'lowshelf';
      else if (i === FREQUENCIES.length - 1) filter.type = 'highshelf';
      else filter.type = 'peaking';
      filter.frequency.value = frequency;
      filter.Q.value = FILTER_Q;
      return filter;
    });
    const limiter = c.createDynamicsCompressor();
    limiter.threshold.value = LIMITER.threshold;
    limiter.knee.value = LIMITER.knee;
    limiter.ratio.value = LIMITER.ratio;
    limiter.attack.value = LIMITER.attack;
    limiter.release.value = LIMITER.release;
    const trim = c.createGain();
    trim.gain.value = TRIM_GAIN;
    const wet = c.createGain();
    const dry = c.createGain();

    input.connect(volume);
    let prev = volume;
    for (const filter of filters) {
      prev.connect(filter);
      prev = filter;
    }
    prev.connect(limiter);
    limiter.connect(trim);
    trim.connect(wet);
    wet.connect(c.destination);
    input.connect(dry);
    dry.connect(c.destination);

    const g = { input, volume, filters, wet, dry };
    paintGraph(g, c, true);
    return g;
  }

  // Pushes the current state into the graph: set directly when the graph is
  // new, smoothed otherwise (no clicks).
  function paintGraph(g, c, immediate) {
    const set = (param, value) => {
      if (immediate) param.value = value;
      else param.setTargetAtTime(value, c.currentTime, SMOOTHING_SECONDS);
    };
    set(g.volume.gain, state.volume * state.boost);
    g.filters.forEach((filter, i) => set(filter.gain, state.eqBands[i]));
    set(g.wet.gain, state.on ? 1 : 0);
    set(g.dry.gain, state.on ? 0 : 1);
  }

  function getContext() {
    if (ctx) return ctx;
    try {
      ctx = new AudioContext();
    } catch (err) {
      console.warn('Deci: cannot create an AudioContext:', err);
      return null;
    }
    // Routed media is silent while the context is not running: keep it running.
    ctx.addEventListener('statechange', () => {
      if (hasRouted && ctx.state !== 'running') ctx.resume().catch(() => {});
      else if (ctx.state === 'running' && needsRoute && state.on) routePending();
    });
    return ctx;
  }

  // The context once it is running, or null: a suspended one (autoplay policy)
  // gets a short chance to resume.
  async function runningContext() {
    const c = getContext();
    if (!c) return null;
    if (c.state !== 'running') {
      await Promise.race([
        c.resume().catch(() => {}),
        new Promise((resolve) => setTimeout(resolve, RESUME_WAIT_MS))
      ]);
    }
    return c.state === 'running' ? c : null;
  }

  function probeSrc(src) {
    let probe = probes.get(src);
    if (!probe) {
      probe = fetch(src, { method: 'HEAD', redirect: 'manual', cache: 'no-store' })
        .then((r) => r.type === 'basic' && r.ok)
        .catch(() => false);
      probes.set(src, probe);
    }
    return probe;
  }

  function attach(c, el) {
    if (!graph) graph = createGraph(c);
    let source;
    try {
      source = c.createMediaElementSource(el);
    } catch (err) {
      // InvalidStateError: the page already owns a source node for this element.
      unroutable.add(el);
      if (!err || err.name !== 'InvalidStateError') console.warn('Deci: cannot route a media element:', err);
      return;
    }
    source.connect(graph.input);
    routed.set(el, source);
    hasRouted = true;
    // A new source (src change, <source> fallback, encryption) may be unreadable.
    for (const type of ['loadstart', 'loadedmetadata', 'encrypted']) el.addEventListener(type, () => checkRouted(el));
    if (orphanTimer === null) orphanTimer = setInterval(checkAlive, ORPHAN_CHECK_MS);
    reportRouted();
  }

  async function route(el) {
    const probed = needsProbe(el, location) ? el.currentSrc || el.src : null;
    if (probed !== null && !(await probeSrc(probed))) return;
    const c = await runningContext();
    if (!c) {
      needsRoute = true; // retried when the context starts, or on pointerdown or keydown
      return;
    }
    // The world may have changed while waiting.
    if (!state.on || blocked || orphaned || routed.has(el) || !isEligible(el, location)) return;
    if (needsProbe(el, location) && (el.currentSrc || el.src) !== probed) return; // retried on the next playing
    attach(c, el);
  }

  function consider(el) {
    if (!state.on || blocked || orphaned || routed.has(el) || unroutable.has(el) || routing.has(el)) return;
    if (!isEligible(el, location)) return;
    routing.add(el);
    route(el)
      .catch((err) => console.warn('Deci: routing a media element failed:', err))
      .finally(() => routing.delete(el));
  }

  // Elements that play now; paused ones are routed when they start.
  function routePending() {
    needsRoute = false;
    for (const el of document.querySelectorAll('video, audio')) {
      if (!el.paused) consider(el);
    }
  }

  // A routed element cannot be un-routed, so one that turned unreadable is
  // reported: the worker turns the tab dry and routes nothing more on this
  // origin, and a reload brings the sound back.
  function checkRouted(el) {
    if (orphaned || !turnedUnsafe(el, location)) return;
    console.warn('Deci: a routed media element now plays a source Web Audio cannot read; reload the tab to restore it:', el.currentSrc || el.src);
    if (blocked) return;
    blocked = true;
    needsRoute = false;
    send({ type: 'PAGE_STATUS', routed: false, unsafe: true }).catch(() => {});
  }

  // A copy cut off from the extension can never be told anything again:
  // it goes dry for good and only keeps its context running for the
  // elements it routed.
  function goOrphan() {
    orphaned = true;
    needsRoute = false;
    state = { ...state, on: false };
    if (graph) paintGraph(graph, ctx, false);
    if (orphanTimer !== null) clearInterval(orphanTimer);
    orphanTimer = null;
    for (const type of MEDIA_EVENTS) document.removeEventListener(type, onMediaEvent, true);
    removeEventListener('pageshow', onPageShow);
  }

  function checkAlive() {
    if (!orphaned && !extensionAlive()) goOrphan();
    return !orphaned;
  }

  function reportRouted() {
    if (!hasRouted || reported || !state.on || blocked) return;
    reported = true;
    send({ type: 'PAGE_STATUS', routed: true }).catch(() => { reported = false; });
  }

  function applyState(msg) {
    if (!checkAlive()) return;
    state = mergeState(state, msg);
    if (graph) paintGraph(graph, ctx, false);
    if (state.on) {
      routePending();
      reportRouted();
    } else {
      reported = false; // told again when switched back on
    }
  }

  // -------------------------------------------------------------------------
  // Wiring
  // -------------------------------------------------------------------------

  // The first media element of the frame wakes the worker.
  function greet() {
    if (greeted || !checkAlive()) return;
    greeted = true;
    send({ type: 'PAGE_HELLO' }).then((reply) => {
      if (reply && !pushed) applyState(reply);
    }).catch(() => {
      greeted = false;
      checkAlive();
    });
  }

  // Asks the worker again, dropping whatever it said before.
  function regreet() {
    pushed = false;
    greeted = false;
    reported = false;
    if (sawMedia) greet();
  }

  function onMediaEvent(event) {
    const el = event.target;
    if (!(el instanceof HTMLMediaElement) || !checkAlive()) return;
    sawMedia = true;
    if (event.type === 'encrypted') {
      if (routed.has(el)) checkRouted(el);
      else unroutable.add(el);
      return;
    }
    greet();
    if (event.type === 'playing') consider(el);
  }

  // A user gesture is what lets a suspended context start.
  function onGesture() {
    if (ctx && hasRouted && ctx.state !== 'running') ctx.resume().catch(() => {});
    if (needsRoute && state.on && checkAlive()) routePending();
  }

  // Restored from the back/forward cache: messages sent while the page was
  // cached never arrived. Dry until the worker answers, so a tab captured in
  // the meantime never gets its gain twice.
  function onPageShow(event) {
    if (!event.persisted || orphaned) return;
    state = { ...state, on: false };
    if (graph) paintGraph(graph, ctx, true);
    regreet();
  }

  chrome.runtime.onMessage.addListener((msg) => {
    if (!msg || orphaned) return;
    if (msg.type === 'PAGE_ASK') regreet();
    if (msg.type !== 'PAGE_STATE') return;
    pushed = true;
    applyState(msg);
  });

  for (const type of MEDIA_EVENTS) document.addEventListener(type, onMediaEvent, true);
  for (const type of ['pointerdown', 'keydown']) document.addEventListener(type, onGesture, true);
  addEventListener('pageshow', onPageShow);

  // Injected into an existing tab: media may already be loaded or playing.
  for (const el of document.querySelectorAll('video, audio')) {
    if (!el.currentSrc && !el.src && el.paused) continue;
    sawMedia = true;
    greet();
    if (!el.paused) consider(el);
  }
})();
