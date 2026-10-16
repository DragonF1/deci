/*
 * Deci Audio Companion: YouTube Music "Listen on this device?" (content script,
 * music.youtube.com top frame).
 *
 * When the account plays somewhere else, YouTube Music pauses here and asks
 * "Listen on this device?" with "Not now" and "Switch". With the option on
 * (chrome.storage.local 'options'.ytmAutoSwitch, written by SET_OPTIONS from the
 * app, missing = on) this script clicks "Switch" as soon as the dialog shows.
 *
 * The dialog is found by its text, not by YouTube's element names, so a markup
 * change does not make it click some other dialog: it must mention this device or
 * another device, and the button clicked must read "Switch". English UI only.
 *
 * At most MAX_CLICKS clicks per CLICK_WINDOW_MS, then it rests for BREAK_MS, so a
 * dialog a click cannot dismiss is never clicked forever. A copy left behind by an
 * extension reload (chrome.runtime.id gone) stops for good.
 */
(function () {
  'use strict';

  const DIALOG_SELECTOR = 'tp-yt-paper-dialog, [role="dialog"], [role="alertdialog"], yt-confirm-dialog-renderer';
  const BUTTON_SELECTOR = 'button, [role="button"], tp-yt-paper-button, yt-button-renderer, yt-button-shape';
  const DIALOG_TEXT = /listen on this device|being used on another device/i;
  const SWITCH_TEXT = /^switch$/i;
  const CHECK_DELAY_MS = 150;
  const SAFETY_POLL_MS = 3000; // in case a show slips past the observed attributes
  const CLICK_COOLDOWN_MS = 1500;
  const MAX_CLICKS = 3;
  const CLICK_WINDOW_MS = 60000;
  const BREAK_MS = 5 * 60000;

  let enabled = true;
  let observer = null;
  let pollTimer = 0;
  let checkTimer = 0;
  let lastClickAt = 0;
  let recentClicks = [];
  let restUntil = 0;

  function isShown(el) {
    return el.isConnected && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden';
  }

  // The innermost element that reads "Switch" (a renderer wraps the real button).
  function findSwitchButton(dialog) {
    let match = null;
    for (const el of dialog.querySelectorAll(BUTTON_SELECTOR)) {
      if (SWITCH_TEXT.test((el.innerText || el.textContent || '').trim()) && isShown(el)) match = el;
    }
    return match;
  }

  // False (and counted) once the click budget for the window is spent.
  function mayClick(now) {
    if (now < restUntil) return false;
    recentClicks = recentClicks.filter((t) => now - t < CLICK_WINDOW_MS);
    if (recentClicks.length < MAX_CLICKS) return true;
    restUntil = now + BREAK_MS;
    recentClicks = [];
    console.warn('Deci: YouTube Music "Switch" clicked ' + MAX_CLICKS + ' times without effect, pausing');
    return false;
  }

  function check() {
    checkTimer = 0;
    if (!chrome.runtime || !chrome.runtime.id) {
      apply(false); // orphaned by an extension reload: storage and the toggle are gone
      return;
    }
    const now = Date.now();
    if (!enabled || now - lastClickAt < CLICK_COOLDOWN_MS) return;
    for (const dialog of document.querySelectorAll(DIALOG_SELECTOR)) {
      if (!isShown(dialog) || !DIALOG_TEXT.test(dialog.innerText || '')) continue;
      const button = findSwitchButton(dialog);
      if (!button || !mayClick(now)) return;
      lastClickAt = now;
      recentClicks.push(now);
      button.click();
      return;
    }
  }

  function scheduleCheck() {
    if (!checkTimer) checkTimer = setTimeout(check, CHECK_DELAY_MS);
  }

  function apply(next) {
    enabled = next;
    if (enabled && !observer) {
      observer = new MutationObserver(scheduleCheck);
      observer.observe(document.documentElement, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['opened', 'hidden', 'aria-hidden']
      });
      pollTimer = setInterval(scheduleCheck, SAFETY_POLL_MS);
      scheduleCheck();
    } else if (!enabled && observer) {
      observer.disconnect();
      observer = null;
      clearInterval(pollTimer);
      pollTimer = 0;
      clearTimeout(checkTimer);
      checkTimer = 0;
    }
  }

  const readOption = (options) => !(options && options.ytmAutoSwitch === false);

  chrome.storage.local.get('options')
    .then(({ options }) => apply(readOption(options)))
    .catch(() => apply(false)); // unknown wish: do not click

  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === 'local' && changes.options) apply(readOption(changes.options.newValue));
  });
})();
