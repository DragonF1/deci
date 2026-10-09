/*
 * Deci Audio Companion: device access page (permissions.html).
 * Opened by the service worker on OPEN_DEVICE_PERMISSION. Asks once for the
 * microphone permission, which is what lets the extension read output device
 * names (labels) for routing. Nothing is recorded: the stream is stopped the
 * moment it opens. Reports DEVICE_ACCESS { granted } to the service worker
 * (see background.js for the contract).
 */

const CLOSE_DELAY_MS = 1500;
const PSEUDO_OUTPUT_IDS = ['default', 'communications'];

const TEXT = {
  waiting: "Choose Allow in Chrome's prompt.",
  done: 'Done. Deci can now route tabs to other outputs. You can close this tab.',
  denied: 'Access was not allowed. If Chrome no longer asks, use the microphone icon in the address bar to allow it, then try again.',
  noMic: 'Chrome found no microphone, and it only reveals speaker names once one is allowed. Connect one (AirPods work), then try again.',
  failed: 'Chrome could not ask for access.'
};

const statusEl = document.getElementById('status');
const errorEl = document.getElementById('error');
const reasonEl = document.getElementById('error-reason');
const retryButton = document.getElementById('retry');

function report(granted) {
  chrome.runtime.sendMessage({ target: 'background', type: 'DEVICE_ACCESS', granted }).catch(() => {});
}

async function micPermissionState() {
  try {
    return (await navigator.permissions.query({ name: 'microphone' })).state;
  } catch (err) {
    return 'unknown';
  }
}

// The ground truth for "access": can this origin read output device labels?
async function labelsReadable() {
  try {
    const devices = await navigator.mediaDevices.enumerateDevices();
    return devices.some((d) => d.kind === 'audiooutput' &&
      !PSEUDO_OUTPUT_IDS.includes(d.deviceId) && d.label);
  } catch (err) {
    return false;
  }
}

function reasonFor(err) {
  const name = err && err.name;
  if (name === 'NotAllowedError' || name === 'SecurityError') return TEXT.denied;
  if (name === 'NotFoundError' || name === 'OverconstrainedError') return TEXT.noMic;
  return TEXT.failed;
}

function closeSelf() {
  chrome.tabs.getCurrent()
    .then((tab) => (tab && Number.isInteger(tab.id) ? chrome.tabs.remove(tab.id) : window.close()))
    .catch(() => window.close());
}

let requesting = false;

async function requestAccess() {
  if (requesting) return;
  requesting = true;
  retryButton.disabled = true;
  errorEl.hidden = true;
  statusEl.textContent = TEXT.waiting;

  let error = null;
  // Already granted: skip getUserMedia so the mic indicator never flashes.
  if ((await micPermissionState()) !== 'granted') {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      for (const track of stream.getTracks()) track.stop();
    } catch (err) {
      error = err;
    }
  }
  // A failure after the grant (mic busy, blocked by macOS) still leaves
  // labels readable, which is all Deci needs.
  const granted = !error || (await labelsReadable());
  report(granted);
  requesting = false;
  retryButton.disabled = false;

  if (granted) {
    statusEl.textContent = TEXT.done;
    setTimeout(closeSelf, CLOSE_DELAY_MS);
    return;
  }
  console.warn('Deci: device access not granted:', error);
  statusEl.textContent = '';
  reasonEl.textContent = reasonFor(error);
  errorEl.hidden = false;
  retryButton.focus();
}

retryButton.addEventListener('click', () => { requestAccess(); });
requestAccess();
