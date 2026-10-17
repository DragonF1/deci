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
 *                                      "page"     not captured, but its track has auto mode
 *                                                 on and its page routes media in-page
 *                                                 (volume, boost and EQ only, no device)
 *                                      "armed"    not captured, its track has auto mode on and
 *                                                 its web page routes nothing yet: volume,
 *                                                 boost and EQ are kept and apply once its
 *                                                 media routes. Never for a tab that sounds
 *                                                 with no media element seen, or whose frame
 *                                                 reported media it cannot route
 *                                      "none"     none of these
 *                                    (missing means an older extension: use captured;
 *                                     an older app reads "armed" as "none")
 *       volume: number 0..1,         (base volume, NOT multiplied by boost)
 *       boost: 1 | 2 | 3 | 4,
 *       muted: boolean,              (captured ? Deci gain mute : Chrome tab mute;
 *                                     mute is never done in-page)
 *       eqBands: [10 numbers, dB],
 *       deviceName: string,          ("" means system default; a CoreAudio device name)
 *       deviceStatus: string         one of:
 *                                      "default"  deviceName is "" (system default output)
 *                                      "pending"  deviceName set, tab not captured yet
 *                                                 (also for control "page": devices need capture)
 *                                      "routed"   captured and playing on the named device
 *                                      "notFound" captured, no output matches deviceName,
 *                                                 playing on system default meanwhile
 *                                      "noAccess" captured, device labels unreadable
 *                                                 (mic permission missing), playing on default
 *                                    (app treats unknown or missing values as "default")
 *     } ],
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
 *   SET_TAB_VOLUME { tabId, volume, boost }  volume 0..1, boost 1..4
 *   SET_TAB_MUTE { tabId, muted }
 *   SET_TAB_EQ { tabId, eqBands }            10 numbers in dB
 *   SET_TAB_DEVICE { tabId, deviceName }     "" = system default; applied with
 *                                            AudioContext.setSinkId while captured,
 *                                            stored and applied when capture starts
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
 *
 * TRACKING. The app can switch off what the extension reports about tabs. A tab is
 * HIDDEN when tracking.tabs is false, or when tracking.incognito is false and the tab is
 * incognito. A hidden tab is left out of TAB_LIST and gets no MEDIA_STATE, so its title,
 * URL and favicon never leave Chrome. TAB_LIST is still sent while everything is hidden
 * (with tabs: []), so the app sees the tracking echo and the connection stays alive; the
 * app resends SET_TRACKING when the echo differs from what it wants. Tracking changes only
 * what is reported: capture, auto mode, page control, badges and per-tab volume, boost,
 * EQ and device work exactly as before, and SET_TAB_* commands are still honored.
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
 * AUTO MODE. Enabling Deci on one tab (toolbar click or command) turns on auto mode
 * for that tab's track: "normal" tabs or "incognito" tabs, the two never mix. Tabs
 * of an auto track that are not captured get volume, boost and EQ from the content
 * script page-audio.js, which routes the page's media through Web Audio. Real
 * capture still wins when present. The toolbar action's context menu checkbox
 * 'deci-auto' turns a track off and on again.
 *
 * Content script (page-audio.js, no target field) <-> service worker:
 *   PAGE_HELLO {}                  page to worker, once per frame, when the frame first
 *                                  sees a media element. Reply { on: boolean, volume,
 *                                  boost, eqBands } ("on" = route this tab's media).
 *   PAGE_STATUS { routed: true }   page to worker, when the frame routes its first media
 *                                  element (again after being switched off and on). Sets
 *                                  the tab's pageControl, which makes control "page".
 *   PAGE_STATUS { routed: false, unreachable: true }
 *                                  page to worker, when a playing media element cannot be
 *                                  routed (encrypted, a stream, its own output device,
 *                                  cross-origin, or a source node the page owns). Sets the
 *                                  tab's pageUnreachable: no "armed" control.
 *   PAGE_STATUS { routed: false, unsafe: true }
 *                                  page to worker, when a routed element starts playing
 *                                  media Web Audio cannot read (silent until reload). The
 *                                  tab goes dry, loses pageControl, and the origin joins
 *                                  'pageBlocked': no frame of it is switched on again
 *                                  this browser session.
 *   PAGE_ASK { type: "PAGE_ASK" }  worker to every frame of a tab with no state yet, when
 *                                  auto turns on: frames that saw media send PAGE_HELLO
 *                                  again.
 *   PAGE_STATE { type: "PAGE_STATE", on, volume, boost, eqBands }
 *                                  worker to every frame of a tab (chrome.tabs.sendMessage)
 *                                  on volume, boost or EQ changes, when auto turns on or
 *                                  off, and when capture starts or stops. on = auto mode
 *                                  for the track AND the tab not captured. Off means the
 *                                  page plays dry (a routed element stays routed).
 *
 * Service worker <-> offscreen document messages carry target 'offscreen' or
 * target 'background'; each side ignores messages not addressed to it.
 *   to offscreen:  START_CAPTURE { tabId, streamId, volume, boost, muted, eqBands, deviceName }
 *                  SET_STATE { tabId, volume, boost, muted, eqBands, deviceName }
 *                                    (a changed deviceName re-resolves that capture's sink)
 *                  STOP_CAPTURE { tabId }
 *                  LIST_CAPTURES {}  (response: array of captured tab ids)
 *                  RESOLVE_DEVICES {}  re-check label access and re-resolve every capture,
 *                                      reporting DEVICE_ACCESS and each DEVICE_STATUS even
 *                                      when unchanged (sent when deviceAccess flips, and
 *                                      after adopting captures the worker did not know)
 *   to background: CAPTURE_ENDED { tabId }
 *                  DEVICE_STATUS { tabId, status }   status as in TAB_LIST deviceStatus
 *                                                    ("routed" | "notFound" | "noAccess" | "default")
 *                                                    sent when it changes for a capture, and
 *                                                    always first after a deviceName change
 *                  DEVICE_ACCESS { granted }         from offscreen (labels readable or not)
 *                                                    and from permissions.html (prompt result)
 *
 * Device resolution (offscreen): enumerateDevices() 'audiooutput', skipping the
 * 'default' and 'communications' pseudo entries; match deviceName against label:
 * exact, then label starting with deviceName + " (", then case-insensitive contains.
 * Re-resolved for every capture on navigator.mediaDevices 'devicechange'. No match or
 * no labels: setSinkId('') and report "notFound" / "noAccess".
 *
 * STORAGE
 *   chrome.storage.session  'tab:<id>'  -> { volume, boost, muted, eqBands, deviceName,
 *                                            deviceStatus, captured, pageControl, pageOrigin,
 *                                            pageMedia, pageUnreachable }
 *                           pageControl: a frame of the tab routes its media in-page.
 *                           pageMedia: a frame of the tab saw a media element (PAGE_HELLO).
 *                           pageUnreachable: a frame reported media it cannot route.
 *                           pageOrigin: origin of the tab URL when one of these was reported;
 *                           all three reset when the tab navigates to another origin.
 *   chrome.storage.local    'autoTracks' -> { normal: boolean, incognito: boolean }
 *                           (default both false; set true by a successful capture start from
 *                           a click or the command, either one changed by the menu checkbox)
 *   chrome.storage.local    'tracking' -> { tabs: boolean, incognito: boolean }
 *                           (written by SET_TRACKING only when the value changed; default
 *                           both true; read at worker start to merge a one-boolean
 *                           SET_TRACKING; never decides what a new port is told, see
 *                           PRIVACY GATE)
 *   chrome.storage.local    'options' -> { ytmAutoSwitch: boolean }
 *                           (written by SET_OPTIONS only when the value changed; read by
 *                           ytm-switch.js, which treats a missing value as true)
 *   chrome.storage.local    'deviceAccess' -> boolean (last known; default false)
 *   chrome.storage.session  'knownTabs' -> [tab ids that were audible this session]
 *   chrome.storage.session  'pageBlocked' -> [origins whose media turned unreadable in-page]
 *   chrome.storage.local    'siteDefaults' -> { hostname: { volume, boost } }
 *                           (only volume is applied, when capture starts)
 *     Written on volume or boost changes of a captured, page-controlled or armed,
 *     non-incognito tab.
 *     Read when a tab with no per-tab state yet starts capture or sends PAGE_HELLO.
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
const BADGE_COLOR_PAGE = '#6B7280';
const TITLE_OFF = "Deci: click to control this tab's audio";
const TITLE_ON = 'Deci: controlling this tab (click to stop)';
const TITLE_PAGE = 'Deci: controlling this tab in-page. Click for full capture (output device)';
const TITLE_ARMED = 'Deci: auto mode is on, this tab is controlled once it plays audio. Click for full capture (output device)';
const TITLE_UNREACHED = "Deci: auto mode can't reach this tab's audio. Click to control it";
const MENU_AUTO_ID = 'deci-auto';
const MENU_AUTO_TITLE = 'Control every tab automatically';
const PAGE_AUDIO_FILE = 'page-audio.js';
const DEVICE_STATUSES = ['default', 'pending', 'routed', 'notFound', 'noAccess'];
const REPORTED_DEVICE_STATUSES = ['default', 'routed', 'notFound', 'noAccess'];

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

function defaultState() {
  return {
    volume: 1,
    boost: 1,
    muted: false,
    eqBands: new Array(EQ_BAND_COUNT).fill(0),
    deviceName: '',
    deviceStatus: 'default',
    captured: false,
    pageControl: false,
    pageOrigin: '',
    pageMedia: false,
    pageUnreachable: false
  };
}

// deviceStatus before the offscreen document has reported one.
function unresolvedDeviceStatus(s) {
  return s.deviceName ? 'pending' : 'default';
}

// deviceStatus as sent in TAB_LIST: the stored (last reported) value only
// counts while the tab is captured and a device is chosen.
function listDeviceStatus(s, captured) {
  if (!s.deviceName) return 'default';
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
  s.captured = raw.captured === true;
  s.pageControl = raw.pageControl === true;
  s.pageOrigin = typeof raw.pageOrigin === 'string' ? raw.pageOrigin : '';
  s.pageMedia = raw.pageMedia === true;
  s.pageUnreachable = raw.pageUnreachable === true;
  s.deviceStatus = s.captured && DEVICE_STATUSES.includes(raw.deviceStatus)
    ? raw.deviceStatus : unresolvedDeviceStatus(s);
  return s;
}

// Everything the offscreen graph needs (sent in START_CAPTURE and SET_STATE).
function audioFields(s) {
  return {
    volume: s.volume,
    boost: s.boost,
    muted: s.muted,
    eqBands: s.eqBands.slice(),
    deviceName: s.deviceName
  };
}

function sameAudio(a, b) {
  return a.volume === b.volume && a.boost === b.boost && a.muted === b.muted &&
    a.deviceName === b.deviceName && a.eqBands.every((v, i) => v === b.eqBands[i]);
}

function hostOf(url) {
  try { return new URL(url).hostname || null; } catch (e) { return null; }
}

function originOf(url) {
  try { return new URL(url).origin; } catch (e) { return ''; }
}

// Auto mode keeps normal and incognito tabs apart.
function trackOf(tab) {
  return tab && tab.incognito ? 'incognito' : 'normal';
}

// How Deci controls a tab: real capture, the in-page fallback (auto mode on
// for the tab's track and a frame routes its media), or not at all. This is
// the TAB_LIST "control" field. st may be undefined (no state yet).
function controlOf(st, track, tracks) {
  if (st && st.captured) return 'capture';
  return st && st.pageControl && tracks[track] ? 'page' : 'none';
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
// Auto mode tracks (chrome.storage.local 'autoTracks'), warm in memory:
// loaded by ready(), so anything that awaited it can read autoTracks.
// ---------------------------------------------------------------------------

let autoTracks = { normal: false, incognito: false };
let autoTracksLoaded = false;

function normalizeAutoTracks(raw) {
  const r = raw && typeof raw === 'object' ? raw : {};
  return { normal: r.normal === true, incognito: r.incognito === true };
}

async function loadAutoTracks() {
  if (autoTracksLoaded) return;
  // A failed read leaves the flags unloaded (off for now, read again next
  // time), so a later write cannot overwrite the stored other track.
  const stored = await chrome.storage.local.get('autoTracks');
  if (autoTracksLoaded) return;
  autoTracks = normalizeAutoTracks(stored.autoTracks);
  autoTracksLoaded = true;
}

// controlOf for a real tab, with the live track flags.
// controlOf plus "armed": a web page of an auto track that routes nothing
// yet but will once it plays. Not armed while it sounds with no media
// element seen (Web Audio or plugins, which page-audio never reaches) or
// after a frame reported media it cannot route.
function tabControl(st, tab) {
  const control = controlOf(st, trackOf(tab), autoTracks);
  if (control !== 'none' || !tab || !isPageUrl(tab.url) || !pageAllowed(tab)) return control;
  if (st && st.pageUnreachable) return 'none';
  if (tab.audible && !(st && st.pageMedia)) return 'none';
  return 'armed';
}

// Captured or routing in-page right now (what lists a silent tab).
function isActiveControl(control) {
  return control === 'capture' || control === 'page';
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
      await loadAutoTracks().catch(logError('autoTracks read'));
      const all = await chrome.storage.session.get(null);
      const store = { tabs: new Map(), known: new Set(), blocked: new Set() };
      for (const [key, value] of Object.entries(all)) {
        if (!key.startsWith('tab:')) continue;
        const id = Number(key.slice(4));
        if (Number.isInteger(id)) store.tabs.set(id, normalizeState(value));
      }
      if (Array.isArray(all.pageBlocked)) {
        for (const origin of all.pageBlocked) if (typeof origin === 'string') store.blocked.add(origin);
      }
      if (Array.isArray(all.knownTabs)) {
        for (const id of all.knownTabs) if (Number.isInteger(id)) store.known.add(id);
      }
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
  if (!creatingOffscreen) {
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
}

async function sendToOffscreen(message) {
  try {
    return await chrome.runtime.sendMessage({ ...message, target: 'offscreen' });
  } catch (err) {
    console.warn(`Deci: offscreen ${message.type} failed:`, errorText(err));
    return undefined;
  }
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
  page: { text: 'ON', color: BADGE_COLOR_PAGE, title: TITLE_PAGE },
  armed: { text: 'ON', color: BADGE_COLOR_PAGE, title: TITLE_ARMED },
  unreached: { text: '', color: null, title: TITLE_UNREACHED },
  off: { text: '', color: null, title: TITLE_OFF }
};

// mode: 'capture' | 'page' | 'armed' | 'unreached' | 'off'
function setBadge(tabId, mode) {
  const ignore = () => {};
  const badge = BADGES[mode] || BADGES.off;
  chrome.action.setBadgeText({ tabId, text: badge.text }).catch(ignore);
  if (badge.color) chrome.action.setBadgeBackgroundColor({ tabId, color: badge.color }).catch(ignore);
  chrome.action.setTitle({ tabId, title: badge.title }).catch(ignore);
}

// A tab's badge: ON (blue) when captured, ON (grey) when its control is
// "page" or "armed", so a new tab shows at once that Deci has it, and on
// non-web tabs of an auto track. A web page whose sound auto mode cannot
// reach shows no ON (the app shows it as not controlled), nor does a
// blocked origin. st may be undefined.
function badgeFor(st, tab) {
  const control = tabControl(st, tab);
  if (control !== 'none') return control;
  if (!pageAllowed(tab)) return 'off';
  return isPageUrl(tab.url) ? 'unreached' : 'armed';
}

// Re-derives a tab's badge from its stored state and its track's auto flag.
async function refreshBadge(store, tabId) {
  const tab = await getTab(tabId);
  if (tab) setBadge(tabId, badgeFor(store.tabs.get(tabId), tab));
}

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
      sendPageState(tabId, st, null); // dry: the capture owns the gain
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
    sendPageState(tabId, st, null);
    adopted = true;
  }
  // Adopted captures may have reported their device status to nobody.
  if (adopted) sendToOffscreen({ type: 'RESOLVE_DEVICES' });
}

function markUncaptured(store, tabId) {
  setBadge(tabId, 'off');
  const st = store.tabs.get(tabId);
  if (!st) return;
  if (st.captured) {
    st.captured = false;
    st.deviceStatus = unresolvedDeviceStatus(st);
    persistTab(tabId, st);
    if (st.muted) chrome.tabs.update(tabId, { muted: true }).catch(() => {});
    schedulePush();
  }
  // Back to in-page control when the tab's track has auto mode on.
  resumePageMode(store, tabId).catch(logError('resume page mode'));
}

async function stopCapture(store, tabId) {
  const st = store.tabs.get(tabId);
  // Read before the stream stops so the page gets its gain back right after,
  // with no wait in between (the tab plays unprocessed until then).
  const tab = await getTab(tabId);
  // Mute through the tabs API before releasing the stream so a muted tab
  // never blips back at full level.
  if (st && st.muted) await chrome.tabs.update(tabId, { muted: true }).catch(() => {});
  await sendToOffscreen({ type: 'STOP_CAPTURE', tabId });
  if (st && tab) sendPageState(tabId, { ...st, captured: false }, tab);
  markUncaptured(store, tabId);
}

// Resolves true when the capture started.
async function startCapture(store, tabId, streamId) {
  const tab = await getTab(tabId);
  if (!tab) return false;

  const existing = store.tabs.get(tabId);
  // The new capture reports its own device status; drop any stale one.
  if (existing) existing.deviceStatus = unresolvedDeviceStatus(existing);
  const next = existing ? { ...existing, eqBands: existing.eqBands.slice() } : defaultState();
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
  // The page goes dry before the capture graph is live, so a boosted tab is
  // never boosted twice (until then it plays unprocessed, not doubled).
  const pageWet = !!autoTracks[trackOf(tab)];
  if (pageWet) await sendPageState(tabId, { ...next, captured: true }, tab);
  const resp = await sendToOffscreen({ type: 'START_CAPTURE', tabId, streamId, ...sent });
  if (!resp || !resp.ok) {
    console.warn(`Deci: capture of tab ${tabId} failed:`, resp ? resp.error : 'no response');
    if (pageWet) sendPageState(tabId, store.tabs.get(tabId) || next, tab); // back to page control
    return false;
  }

  // Merge with anything the app changed while the capture was starting.
  const current = store.tabs.get(tabId);
  const final = current ? { ...current, muted: apiMuted, captured: true } : { ...next, captured: true };
  store.tabs.set(tabId, final);
  persistTab(tabId, final);
  if (current && !sameAudio(final, sent)) {
    sendToOffscreen({ type: 'SET_STATE', tabId, ...audioFields(final) });
  }
  // Unmute via the API only after the gain (muted) owns the audio.
  if (apiMuted) chrome.tabs.update(tabId, { muted: false }).catch(() => {});
  setBadge(tabId, 'capture');
  // The capture owns the gain now: the page goes dry so it is not applied twice.
  if (autoTracks[trackOf(tab)]) sendPageState(tabId, final, tab);
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
      sendPageState(tabId, healed, null);
      sendToOffscreen({ type: 'RESOLVE_DEVICES' }); // its status may have gone unrecorded
      schedulePush();
      return;
    }
    console.warn(`Deci: cannot capture tab ${tabId}:`, result.error);
    return;
  }
  // A capture started by hand turns auto mode on for the tab's track.
  if (await startCapture(store, tabId, result.id)) {
    const tab = await getTab(tabId);
    // Not awaited: applying to every tab must not hold this tab's toggle guard.
    if (tab) setAutoTrack(trackOf(tab), true).catch(logError('auto mode on'));
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
async function setDeviceStatus(tabId, status) {
  const store = await ready();
  const st = store.tabs.get(tabId);
  if (!st || st.deviceStatus === status) return;
  st.deviceStatus = status;
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
      setDeviceStatus(msg.tabId, msg.status).catch(logError('DEVICE_STATUS'));
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
// Auto mode: tabs that are not captured get volume, boost and EQ in-page
// ---------------------------------------------------------------------------

function isPageUrl(url) {
  return typeof url === 'string' && /^https?:/i.test(url);
}

// Whether page-audio may route media of this tab's page.
function pageAllowed(tab) {
  return !!tab && !!autoTracks[trackOf(tab)] && !(storeSync && storeSync.blocked.has(originOf(tab.url)));
}

// Tells every frame of a tab what to do. Errors are ignored: "Receiving end
// does not exist" is normal for tabs without the content script. tab may be
// null for a captured tab (always dry). Resolves once the frames have it.
function sendPageState(tabId, st, tab) {
  const on = !st.captured && pageAllowed(tab);
  return chrome.tabs.sendMessage(tabId, {
    type: 'PAGE_STATE',
    on,
    volume: st.volume,
    boost: st.boost,
    eqBands: st.eqBands.slice()
  }).catch(() => {});
}

// The tab's state, created when it has none: volume seeded from the site
// default, as startCapture does for a new tab.
async function ensureTabState(store, tab) {
  const existing = store.tabs.get(tab.id);
  if (existing) return existing;
  const st = defaultState();
  const site = await getSiteDefault(tab.url);
  if (site) st.volume = site.volume;
  // Another path may have created the state while the site default was read.
  const raced = store.tabs.get(tab.id);
  if (raced) return raced;
  store.tabs.set(tab.id, st);
  persistTab(tab.id, st);
  return st;
}

// After a capture ends, a tab on an auto track goes back to page mode.
async function resumePageMode(store, tabId) {
  const tab = await getTab(tabId);
  const st = store.tabs.get(tabId);
  if (!tab) return;
  setBadge(tabId, badgeFor(st, tab));
  if (st && autoTracks[trackOf(tab)]) sendPageState(tabId, st, tab);
}

// Manifest content scripts never reach tabs that were open before the
// extension was installed or reloaded, so those are injected by hand. Errors
// (closed tab, restricted page) are expected.
async function injectPageAudio(tabId) {
  try {
    await chrome.scripting.executeScript({ target: { tabId, allFrames: true }, files: [PAGE_AUDIO_FILE] });
  } catch (e) { /* not injectable */ }
}

// Brings one tab in line with its track's flag. A tab with no state gets no
// state here: its frames that saw media ask for it (PAGE_ASK, then
// PAGE_HELLO), the others when their first media appears.
async function applyAutoToTab(store, tab, on) {
  const st = store.tabs.get(tab.id);
  if (!on && st && (st.pageControl || st.pageUnreachable)) {
    st.pageControl = false; // rows fall back
    st.pageUnreachable = false; // frames report again when auto turns back on
    persistTab(tab.id, st);
  }
  setBadge(tab.id, badgeFor(st, tab));
  if (on) {
    if (!isPageUrl(tab.url) || tab.discarded) return;
    await injectPageAudio(tab.id);
  }
  if (st) sendPageState(tab.id, st, tab);
  else if (on) chrome.tabs.sendMessage(tab.id, { type: 'PAGE_ASK' }).catch(() => {});
}

async function applyAutoTrack(store, track) {
  const on = autoTracks[track];
  const tabs = await chrome.tabs.query({});
  await Promise.all(tabs
    .filter((t) => Number.isInteger(t.id) && t.id >= 0 && trackOf(t) === track)
    .map((t) => applyAutoToTab(store, t, on).catch(logError(`auto mode for tab ${t.id}`))));
  schedulePush();
}

async function setAutoTrack(track, on) {
  const store = await ready();
  await loadAutoTracks(); // throws when the stored flags still cannot be read
  if (autoTracks[track] !== on) {
    autoTracks = { ...autoTracks, [track]: on };
    chrome.storage.local.set({ autoTracks }).catch(logError('autoTracks write'));
    syncAutoMenu();
    await applyAutoTrack(store, track);
  }
  syncAutoMenu();
}

// PAGE_HELLO: a frame saw its first media element and asks what to do.
async function pageHello(tab) {
  const store = await ready();
  if (!pageAllowed(tab) || removedTabs.has(tab.id)) return { on: false };
  const st = await ensureTabState(store, tab);
  if (!st.pageMedia || st.pageOrigin !== originOf(tab.url)) {
    markPage(st, tab, 'pageMedia');
    setBadge(tab.id, badgeFor(st, tab));
    schedulePush();
  }
  if (st.captured) return { on: false };
  return { on: true, volume: st.volume, boost: st.boost, eqBands: st.eqBands.slice() };
}

// Sets one of the per-origin page flags (see STORAGE) for the tab's origin.
function markPage(st, tab, flag) {
  const origin = originOf(tab.url);
  if (st.pageOrigin !== origin) {
    st.pageControl = false;
    st.pageMedia = false;
    st.pageUnreachable = false;
    st.pageOrigin = origin;
  }
  st[flag] = true;
  persistTab(tab.id, st);
}

// PAGE_STATUS: a frame of the tab routes its media in-page.
async function pageRouted(tab) {
  const store = await ready();
  if (!pageAllowed(tab) || removedTabs.has(tab.id)) return;
  const st = await ensureTabState(store, tab);
  markPage(st, tab, 'pageControl');
  setBadge(tab.id, badgeFor(st, tab));
  schedulePush();
}

// PAGE_STATUS unreachable: a frame of the tab plays media it cannot route.
async function pageCannotRoute(tab) {
  const store = await ready();
  if (!pageAllowed(tab) || removedTabs.has(tab.id)) return;
  const st = await ensureTabState(store, tab);
  if (st.pageUnreachable && st.pageOrigin === originOf(tab.url)) return;
  markPage(st, tab, 'pageUnreachable');
  setBadge(tab.id, badgeFor(st, tab));
  schedulePush();
}

// PAGE_STATUS unsafe: a routed element of the tab plays media Web Audio
// cannot read. Nothing brings that element back but a reload, so the tab
// goes dry and its origin is never routed again this session.
async function pageUnsafe(tab) {
  const store = await ready();
  const origin = originOf(tab.url);
  console.warn(`Deci: in-page audio stopped for ${origin || 'a page'}: a routed element turned unreadable; reload the tab to restore it`);
  if (origin && !store.blocked.has(origin)) {
    store.blocked.add(origin);
    chrome.storage.session.set({ pageBlocked: [...store.blocked] }).catch(logError('session write'));
  }
  const st = store.tabs.get(tab.id);
  if (!st) return;
  if (st.pageControl) {
    st.pageControl = false;
    persistTab(tab.id, st);
  }
  setBadge(tab.id, badgeFor(st, tab));
  sendPageState(tab.id, st, tab);
  schedulePush();
}

// Messages from the content script: no target field, the sender is a tab.
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  const tab = sender && sender.tab;
  if (!msg || !tab || !Number.isInteger(tab.id) || tab.id < 0) return false;
  if (msg.type === 'PAGE_HELLO') {
    pageHello(tab).then(sendResponse, (err) => {
      logError('PAGE_HELLO')(err);
      sendResponse({ on: false });
    });
    return true; // answered asynchronously
  }
  if (msg.type === 'PAGE_STATUS') {
    if (msg.routed === true) pageRouted(tab).catch(logError('PAGE_STATUS'));
    else if (msg.unsafe === true) pageUnsafe(tab).catch(logError('PAGE_STATUS unsafe'));
    else if (msg.unreachable === true) pageCannotRoute(tab).catch(logError('PAGE_STATUS unreachable'));
    sendResponse({ ok: true });
  }
  return false;
});

// The toolbar action's right-click menu: one checkbox for the active tab's track.
function createAutoMenu() {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: MENU_AUTO_ID,
      type: 'checkbox',
      title: MENU_AUTO_TITLE,
      contexts: ['action'],
      checked: false
    }, () => {
      if (chrome.runtime.lastError) console.warn('Deci: menu create failed:', chrome.runtime.lastError.message);
      syncAutoMenu();
    });
  });
}

// Shows the auto flag of the track of the tab in front.
function syncAutoMenu() {
  ready().then(async () => {
    const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
    chrome.contextMenus.update(MENU_AUTO_ID, { checked: !!autoTracks[trackOf(tab)] }, () => {
      void chrome.runtime.lastError; // the item does not exist yet on first install
    });
  }).catch(() => {});
}

chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId !== MENU_AUTO_ID) return;
  (async () => {
    const target = tab || (await chrome.tabs.query({ active: true, lastFocusedWindow: true }))[0];
    // The live flag, not info.checked: the checkbox may show another window's track.
    const track = trackOf(target);
    await setAutoTrack(track, !autoTracks[track]);
  })().catch(logError('auto menu'));
});

chrome.tabs.onActivated.addListener(({ tabId }) => {
  syncAutoMenu();
  ready().then((store) => refreshBadge(store, tabId)).catch(logError('badge refresh'));
});

// A new tab of an auto track shows ON before it loads anything.
chrome.tabs.onCreated.addListener((tab) => {
  if (!Number.isInteger(tab.id) || tab.id < 0) return;
  ready().then((store) => setBadge(tab.id, badgeFor(store.tabs.get(tab.id), tab))).catch(logError('badge'));
});
chrome.windows.onFocusChanged.addListener(() => syncAutoMenu());

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
    const control = tabControl(st, t);
    // A page-controlled tab is listed like a captured one; an armed one only once known.
    if (!t.audible && !isActiveControl(control) && !store.known.has(t.id)) continue;
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
    deviceAccess: access === true
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
    // The page flags belong to the origin that reported them.
    if (st && (st.pageControl || st.pageMedia || st.pageUnreachable) && 'url' in changeInfo &&
      originOf(changeInfo.url) !== st.pageOrigin) {
      st.pageControl = false;
      st.pageMedia = false;
      st.pageUnreachable = false;
      persistTab(tabId, st);
      schedulePush();
    }
    const control = tabControl(st, tab);
    // Navigation can reset per-tab action state, the new origin may be blocked,
    // and sound with no media element seen ends "armed".
    if ('status' in changeInfo || 'url' in changeInfo || 'audible' in changeInfo) setBadge(tabId, badgeFor(st, tab));
    if (changeInfo.audible === true && !store.known.has(tabId)) {
      store.known.add(tabId);
      persistKnown(store);
    }
    if (listChange && (tab.audible || isActiveControl(control) || store.known.has(tabId))) schedulePush();
  }).catch(logError('tab update'));
});

function forgetTab(tabId) {
  removedTabs.add(tabId);
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
// the tab is captured, and schedules a TAB_LIST push.
async function updateTabState(tabId, mutate) {
  const store = await ready();
  const tab = await getTab(tabId);
  if (!tab) return null;
  const st = store.tabs.get(tabId) || defaultState();
  mutate(st);
  store.tabs.set(tabId, st);
  persistTab(tabId, st);
  if (st.captured) sendToOffscreen({ type: 'SET_STATE', tabId, ...audioFields(st) });
  else if (autoTracks[trackOf(tab)]) sendPageState(tabId, st, tab);
  schedulePush();
  return { st, tab };
}

function setTabDevice(tabId, deviceName) {
  return updateTabState(tabId, (st) => {
    if (st.deviceName === deviceName) return;
    st.deviceName = deviceName;
    // "pending" until the offscreen document reports for the new name
    // (it always reports first after a change).
    st.deviceStatus = unresolvedDeviceStatus(st);
  });
}

async function setTabVolume(tabId, volume, boost) {
  const result = await updateTabState(tabId, (st) => {
    st.volume = clampVolume(volume);
    if (boost !== undefined) st.boost = clampBoost(boost);
  });
  if (!result) return;
  const { st, tab } = result;
  if (tabControl(st, tab) !== 'none' && !tab.incognito) {
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
    if (port === p) port = null;
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
chrome.runtime.onInstalled.addListener(() => {
  connect();
  createAutoMenu();
  // Tabs already open never get the manifest content script: inject into
  // the tracks that are on (install, update and reload all land here).
  ready().then((store) => Promise.all(
    Object.keys(autoTracks).filter((track) => autoTracks[track]).map((track) => applyAutoTrack(store, track))
  )).catch(logError('inject on install'));
});

// ---------------------------------------------------------------------------
// Worker startup
// ---------------------------------------------------------------------------

chrome.alarms.clear(LEGACY_ALARM).catch(() => {});
chrome.alarms.get(RECONNECT_ALARM).then((alarm) => {
  if (!alarm) return chrome.alarms.create(RECONNECT_ALARM, { periodInMinutes: 0.5 });
  return undefined;
}).catch(logError('alarm setup'));

ready().catch(logError('startup state load'));
loadTracking().catch(logError('tracking read'));
syncAutoMenu();
// Never throws (async); if the Permissions API is unusable here, the
// offscreen document and permissions.html still report access.
watchMicPermission().catch(() => {});
connect();
