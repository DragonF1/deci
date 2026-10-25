/*
 * Deci Audio Companion: plain volume (content script, page world, every frame,
 * document_start).
 *
 * Plain control for a tab Deci does not capture (TAB MODES in background.js):
 * every audio and video element of the frame plays at the page's own volume
 * times the tab's plain level. No AudioContext and no audio graph: only the
 * element's own volume property.
 *
 * HTMLMediaElement.prototype.volume is wrapped. Writing a number in 0..1 stores
 * it as the page's value and puts value * level on the element; reading returns
 * the page's value, so the page never sees the scaling. Anything else goes to
 * Chrome's own setter, which raises its usual error (or converts the value, as
 * it would). An element the page never touched is picked up when it plays, when
 * it starts loading (in the document or in any shadow root), when the page sets
 * its autoplay, or when the level changes (a document scan), and its current
 * volume becomes the page's value. A change made with the element's built-in
 * controls (a volumechange that no write through the setter explains) becomes the
 * page's value too, kept at or under the level.
 *
 * The level comes from plain-bridge.js as a CustomEvent '__deci_plain_volume__'
 * on document, detail a number in 0..1. This script never sends anything back.
 * It starts at 1, which changes nothing. Installed once per frame: a second copy
 * (an injection into a frame that already has one) does nothing.
 */
(function () {
  'use strict';

  const EVENT = '__deci_plain_volume__';
  const INSTALLED = Symbol.for(EVENT);
  const SELECTOR = 'audio, video';
  const MIN_PRUNE_AT = 256; // tracked entries before the first sweep for collected elements

  if (typeof HTMLMediaElement !== 'function') return;
  const proto = HTMLMediaElement.prototype;
  if (proto[INSTALLED]) return;
  const volumeDesc = Object.getOwnPropertyDescriptor(proto, 'volume');
  const playDesc = Object.getOwnPropertyDescriptor(proto, 'play');
  if (!volumeDesc || typeof volumeDesc.get !== 'function' || typeof volumeDesc.set !== 'function' ||
    !volumeDesc.configurable || !playDesc || typeof playDesc.value !== 'function' || !playDesc.configurable) return;
  Object.defineProperty(proto, INSTALLED, { value: true });

  // Chrome's own functions, called as plain functions so a page that replaces
  // them (or Function.prototype.call) later changes nothing here.
  const call = Function.prototype.call;
  const getVolume = call.bind(volumeDesc.get);
  const setVolume = call.bind(volumeDesc.set);
  const play = call.bind(playDesc.value);
  const query = call.bind(Document.prototype.querySelectorAll);
  const dispatch = call.bind(EventTarget.prototype.dispatchEvent);
  const listen = call.bind(EventTarget.prototype.addEventListener);
  const Ref = WeakRef;
  const PlainEvent = Event;
  const later = setTimeout;
  const min = Math.min;
  const max = Math.max;

  const base = new WeakMap(); // element -> the page's own volume
  const tracked = new Set(); // a WeakRef to every element in base
  let pruneAt = MIN_PRUNE_AT;
  let factor = 1;

  // Adds an element just put in base. Every so often drops the entries of
  // collected elements, so a page that makes a new Audio per sound stays small.
  function remember(el) {
    tracked.add(new Ref(el));
    if (tracked.size < pruneAt) return;
    for (const ref of tracked) if (ref.deref() === undefined) tracked.delete(ref);
    pruneAt = max(MIN_PRUNE_AT, tracked.size * 2);
  }

  // First sight of an element: its volume so far is the page's own.
  function track(el) {
    const v = getVolume(el); // throws for anything but a media element
    base.set(el, v);
    remember(el);
    if (factor !== 1) setVolume(el, v * factor);
  }

  function trackQuietly(el) {
    if (base.has(el)) return;
    try { track(el); } catch (err) { /* not a media element */ }
  }

  const accessors = {
    get volume() {
      const v = base.get(this);
      return v === undefined ? getVolume(this) : v;
    },
    set volume(value) {
      const el = this;
      if (typeof value === 'number' && value >= 0 && value <= 1) {
        const before = getVolume(el); // throws for anything but a media element
        const old = base.get(el);
        const scaled = value * factor;
        setVolume(el, scaled);
        base.set(el, value);
        if (old === undefined) remember(el);
        // Chrome fires volumechange only when the element's own volume moved.
        // When the page's value moved and that did not (level 0), the page still
        // gets the event it would have had.
        if (before === scaled && value !== (old === undefined ? before : old)) {
          later(() => dispatch(el, new PlainEvent('volumechange')), 0);
        }
        return;
      }
      // NaN, infinities and values out of range get Chrome's own error. A value
      // Chrome converts (a numeric string, say) is read back as the page's value.
      setVolume(el, value);
      const v = getVolume(el);
      const known = base.has(el);
      base.set(el, v);
      if (!known) remember(el);
      if (factor !== 1) setVolume(el, v * factor);
    }
  };
  const wrapped = Object.getOwnPropertyDescriptor(accessors, 'volume');
  Object.defineProperty(proto, 'volume', {
    get: wrapped.get,
    set: wrapped.set,
    enumerable: volumeDesc.enumerable,
    configurable: true
  });

  // Picked up before the original runs, so it never starts at the unscaled level.
  const methods = {
    play() {
      trackQuietly(this);
      return play(this);
    }
  };
  Object.defineProperty(proto, 'play', {
    value: methods.play,
    writable: playDesc.writable,
    enumerable: playDesc.enumerable,
    configurable: true
  });

  function applyAll() {
    for (const ref of tracked) {
      const el = ref.deref();
      if (el === undefined) {
        tracked.delete(ref);
        continue;
      }
      const want = base.get(el) * factor;
      if (getVolume(el) !== want) setVolume(el, want);
    }
    const found = query(document, SELECTOR);
    for (let i = 0; i < found.length; i++) trackQuietly(found[i]);
  }

  // Capture phase on window: runs before any listener the page adds.
  listen(window, EVENT, (event) => {
    event.stopImmediatePropagation(); // not the page's business
    const next = event.detail;
    if (typeof next !== 'number' || !(next >= 0 && next <= 1) || next === factor) return;
    factor = next;
    applyAll();
  }, true);

  // Autoplay and the built-in play button never call play().
  const onStart = (event) => trackQuietly(event.target);

  function onVolumeChange(event) {
    const el = event.target;
    const page = base.get(el);
    if (page === undefined) {
      trackQuietly(el);
      return;
    }
    const v = getVolume(el);
    if (v === page * factor) return; // a write through the setter, or only muted changed
    // The built-in controls: v is what the element plays at now.
    const next = factor > 0 ? min(1, v / factor) : v;
    base.set(el, next);
    if (v !== next * factor) setVolume(el, next * factor);
  }

  // Capture phase, so these run before any listener the page adds and see media
  // events (which do not bubble) from anywhere under the target. Media events
  // stop at a shadow root, so every shadow root gets its own set below.
  function watch(target) {
    listen(target, 'loadstart', onStart, true);
    listen(target, 'play', onStart, true);
    listen(target, 'volumechange', onVolumeChange, true);
  }
  watch(window);

  // Every new shadow root, open or closed, is watched from the start: a player
  // kept in one that autoplays is picked up like any other.
  const attachDesc = Object.getOwnPropertyDescriptor(Element.prototype, 'attachShadow');
  if (attachDesc && typeof attachDesc.value === 'function' && attachDesc.configurable) {
    const attach = call.bind(attachDesc.value);
    const shadow = {
      attachShadow(init) {
        const root = attach(this, init);
        watch(root);
        return root;
      }
    };
    Object.defineProperty(Element.prototype, 'attachShadow', {
      value: shadow.attachShadow,
      writable: attachDesc.writable,
      enumerable: attachDesc.enumerable,
      configurable: true
    });
  }

  // An element that is never put in the document (new Audio() set to autoplay)
  // fires its events nowhere this script listens, so it is picked up here.
  const autoplayDesc = Object.getOwnPropertyDescriptor(proto, 'autoplay');
  if (autoplayDesc && typeof autoplayDesc.set === 'function' && autoplayDesc.configurable) {
    const setAutoplay = call.bind(autoplayDesc.set);
    const flags = {
      set autoplay(value) {
        trackQuietly(this);
        setAutoplay(this, value);
      }
    };
    Object.defineProperty(proto, 'autoplay', {
      get: autoplayDesc.get,
      set: Object.getOwnPropertyDescriptor(flags, 'autoplay').set,
      enumerable: autoplayDesc.enumerable,
      configurable: true
    });
  }
})();
