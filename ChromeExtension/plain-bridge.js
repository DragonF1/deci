/*
 * Deci Audio Companion: plain volume bridge (content script, every frame,
 * document_start).
 *
 * Carries the tab's plain level (TAB MODES in background.js) from the service
 * worker to plain-volume.js in the page world of the same frame. On load it asks
 * with PLAIN_HELLO and passes the reply's factor on; after that it passes on each
 * PLAIN_VOLUME push. The page world copy gets the level as a CustomEvent
 * '__deci_plain_volume__' on document whose detail is the number. A hello reply
 * that a push overtook is dropped, since the push is newer. It asks again when
 * the page comes back from the back/forward cache (pushes sent meanwhile never
 * arrived) and when a prerendered page is shown.
 *
 * A copy left behind by an extension reload (chrome.runtime.id gone) does
 * nothing; the service worker injects a fresh one when a push finds no bridge.
 */
(function () {
  'use strict';

  // The manifest copy and an injected one share this isolated world.
  if (globalThis.__deciPlainBridge) return;
  globalThis.__deciPlainBridge = true;

  const EVENT = '__deci_plain_volume__';

  let pushes = 0; // PLAIN_VOLUME messages seen, so a stale hello reply can tell

  function alive() {
    try {
      return !!(chrome.runtime && chrome.runtime.id);
    } catch (err) {
      return false;
    }
  }

  function relay(factor) {
    if (typeof factor !== 'number' || !(factor >= 0 && factor <= 1)) return;
    document.dispatchEvent(new CustomEvent(EVENT, { detail: factor }));
  }

  function ask() {
    if (!alive()) return;
    const before = pushes;
    try {
      chrome.runtime.sendMessage({ type: 'PLAIN_HELLO' }).then((reply) => {
        if (pushes === before && reply) relay(reply.factor);
      }, () => { /* the extension went away, or the worker could not answer */ });
    } catch (err) {
      // The extension context is gone.
    }
  }

  try {
    chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
      if (!msg || msg.type !== 'PLAIN_VOLUME' || msg.target !== undefined) return false;
      pushes++;
      relay(msg.factor);
      // The worker waits for this before it releases a capture.
      sendResponse({ ok: true });
      return false;
    });
  } catch (err) {
    return; // the extension context is gone
  }

  window.addEventListener('pageshow', (event) => {
    if (event.persisted) ask();
  });
  if (document.prerendering) document.addEventListener('prerenderingchange', ask, { once: true });
  ask();
})();
