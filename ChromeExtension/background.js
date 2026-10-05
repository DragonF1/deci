let port = null;

// Volume last applied to each tab this service-worker lifetime, used both to
// report a tab's current volume back to the app and to skip re-applying
// per-site memory to a tab the app is already driving.
const tabVolumes = new Map();

const PER_SITE_STORAGE_KEY = 'perSiteVolume';

function hostFromUrl(urlString) {
  try {
    const u = new URL(urlString);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
    return u.hostname || null;
  } catch {
    return null;
  }
}

async function getPerSiteVolume(host) {
  if (!host) return null;
  const data = await chrome.storage.local.get([PER_SITE_STORAGE_KEY]);
  const perSite = data[PER_SITE_STORAGE_KEY] || {};
  return typeof perSite[host] === 'number' ? perSite[host] : null;
}

// 100% means "no override": matches the default, so it's just deleted
// instead of stored, keeping the map from growing on every untouched site.
async function setPerSiteVolume(host, volume) {
  if (!host) return;
  const data = await chrome.storage.local.get([PER_SITE_STORAGE_KEY]);
  const perSite = data[PER_SITE_STORAGE_KEY] || {};
  if (volume === 1.0) {
    delete perSite[host];
  } else {
    perSite[host] = volume;
  }
  await chrome.storage.local.set({ [PER_SITE_STORAGE_KEY]: perSite });
}

function applyVolumeToTab(tabId, volume) {
  tabVolumes.set(tabId, volume);
  return chrome.scripting.executeScript({
    target: { tabId, allFrames: true },
    func: applyPageVolume,
    args: [volume]
  }).catch((err) => console.error('Scripting error:', err));
}

// Runs inside the tab. Applies one gain to every media element on the page,
// remembers it so elements added later get the same gain.
function applyPageVolume(vol) {
  const applyTo = (el) => {
    if (el.dataset.originalVolume === undefined) {
      el.dataset.originalVolume = el.volume;
    }
    const baseVol = parseFloat(el.dataset.originalVolume);

    if (vol <= 1.0) {
      el.volume = Math.min(1.0, baseVol * vol);
      if (el.__gainNode) {
        el.__gainNode.gain.value = 1.0;
      }
      return;
    }

    // Boost: element at its own volume, Web Audio gain for the extra.
    el.volume = Math.min(1.0, baseVol);
    if (!el.__audioCtx) {
      try {
        const ctx = new AudioContext();
        const source = ctx.createMediaElementSource(el);
        const gain = ctx.createGain();
        // DynamicsCompressorNode works on real sample values, not a fixed
        // [-1, 1] lookup curve, so it can't clamp-and-flatline the way a
        // custom WaveShaperNode curve did across every gain past ~150%.
        // Same settings a known-working open-source booster ships with.
        const limiter = ctx.createDynamicsCompressor();
        limiter.threshold.value = -3;
        limiter.knee.value = 0;
        limiter.ratio.value = 20;
        limiter.attack.value = 0.003;
        limiter.release.value = 0.1;
        source.connect(gain);
        gain.connect(limiter);
        limiter.connect(ctx.destination);
        el.__audioCtx = ctx;
        el.__gainNode = gain;
        // chrome.scripting injection carries no user gesture, so a freshly
        // created context can be stuck 'suspended' until the element's own
        // play event (a real, page-level gesture-tied event) resumes it.
        el.addEventListener('play', () => {
          if (ctx.state === 'suspended') ctx.resume().catch(() => {});
        });
      } catch (err) {
        // Cross-origin media or an element already owned by another
        // AudioContext cannot be boosted; leave it at 100%.
        console.warn('Boost unavailable for element:', err);
        return;
      }
    }
    if (el.__audioCtx.state === 'suspended') {
      el.__audioCtx.resume().catch(() => {});
    }
    el.__gainNode.gain.value = vol;
  };

  window.__currentSetVolume = vol;
  document.querySelectorAll('video, audio').forEach(applyTo);

  if (!window.__audioObserver) {
    window.__audioObserver = new MutationObserver((mutations) => {
      const current = window.__currentSetVolume;
      if (current === undefined) return;
      mutations.forEach((m) => {
        m.addedNodes.forEach((node) => {
          if (!(node instanceof Element)) return;
          if (node.tagName === 'VIDEO' || node.tagName === 'AUDIO') {
            applyTo(node);
          }
          node.querySelectorAll?.('video, audio').forEach(applyTo);
        });
      });
    });
    window.__audioObserver.observe(document.documentElement, { childList: true, subtree: true });
  }
}

// Each injected function runs standalone in the tab (chrome.scripting only
// serializes the one function passed to it, not helpers it calls), so the
// "which element does the popover control" pick is duplicated inline below:
// whichever media element is actively playing, else whichever has a real
// duration, else the first one.

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

const knownAudioTabs = new Set();

function sendTabList() {
  if (!port) {
    // A tab event may have just revived a suspended service worker; use it
    // to get back to the host rather than wait for the reconnect alarm.
    connectToNativeHost();
    return;
  }
  chrome.tabs.query({}, (tabs) => {
    if (!port || !tabs) return;
    tabs.forEach((t) => {
      if (t.audible) {
        knownAudioTabs.add(t.id);
      }
    });
    const audioTabs = tabs.filter((t) => t.audible || knownAudioTabs.has(t.id));
    port.postMessage({
      type: 'TAB_LIST',
      tabs: audioTabs.map((t) => ({
        id: t.id,
        title: t.title || '',
        favIconUrl: t.favIconUrl || '',
        volume: tabVolumes.get(t.id) ?? 1.0
      }))
    });
  });
}

function connectToNativeHost() {
  if (port) return;
  try {
    port = chrome.runtime.connectNative('com.abraham.deci');
  } catch (err) {
    try {
      port = chrome.runtime.connectNative('com.example.advancedaudiocontrol');
    } catch (err2) {
      console.error('Native host unavailable:', err2);
      return;
    }
  }
  chrome.alarms.clear('reconnect');

  port.onMessage.addListener((msg) => {
    if (msg.type === 'SET_TAB_VOLUME') {
      applyVolumeToTab(msg.tabId, msg.volume);
      chrome.tabs.get(msg.tabId, (tab) => {
        if (chrome.runtime.lastError || !tab) return;
        setPerSiteVolume(hostFromUrl(tab.url), msg.volume);
      });
    } else if (msg.type === 'GET_TABS') {
      sendTabList();
    } else if (msg.type === 'GET_MEDIA_STATE') {
      chrome.scripting.executeScript({
        target: { tabId: msg.tabId },
        func: getMediaState
      }).then((results) => {
        const state = results && results[0] && results[0].result;
        if (state && port) {
          port.postMessage({ type: 'MEDIA_STATE', tabId: msg.tabId, ...state });
        }
      }).catch((err) => console.error('Scripting error:', err));
    } else if (msg.type === 'TOGGLE_PLAYBACK') {
      chrome.scripting.executeScript({
        target: { tabId: msg.tabId },
        func: togglePlayback
      }).catch((err) => console.error('Scripting error:', err));
    }
  });

  port.onDisconnect.addListener(() => {
    console.log('Disconnected from native host');
    port = null;
    // A setTimeout dies with the service worker; an alarm outlives it.
    chrome.alarms.create('reconnect', { delayInMinutes: 0.5, periodInMinutes: 0.5 });
  });

  sendTabList();
}

// Keep the app's tab list current without it having to poll.
chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.status === 'complete' && tab.url) {
    // A full page load just finished, including navigating an already-known
    // tab to a different site: reload that origin's remembered volume (or
    // reset to 100% if it has none) so a stale volume from whatever site
    // used to be in this tab never carries over.
    getPerSiteVolume(hostFromUrl(tab.url)).then((stored) => {
      applyVolumeToTab(tabId, stored ?? 1.0).then(() => sendTabList());
    });
    return;
  }
  if (changeInfo.audible === true && !tabVolumes.has(tabId)) {
    // A tab the app hasn't driven yet just started making sound without a
    // navigation event firing first (e.g. the service worker restarted
    // after the tab was already open): apply this site's remembered volume
    // before the app's own row appears at 100%.
    getPerSiteVolume(hostFromUrl(tab.url)).then((stored) => {
      if (stored !== null) {
        applyVolumeToTab(tabId, stored).then(() => sendTabList());
      } else {
        sendTabList();
      }
    });
    return;
  }
  if ('audible' in changeInfo || 'title' in changeInfo || 'favIconUrl' in changeInfo) {
    sendTabList();
  }
});
chrome.tabs.onRemoved.addListener((tabId) => {
  tabVolumes.delete(tabId);
  knownAudioTabs.delete(tabId);
  sendTabList();
});
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === 'reconnect') connectToNativeHost();
});

connectToNativeHost();
