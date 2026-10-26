# Deci

Deci is a macOS menu bar app with a per-app volume mixer, a 10-band EQ, a native YouTube Music player, and a Chrome extension for per-tab volume. It is a fork of [FineTune](https://github.com/ronitsingh10/FineTune).

## Features

### Mixer and audio

- **Per-app volume**: a slider and mute for each app.
- **Per-app boost**: 2x, 3x or 4x gain for quiet apps.
- **Pinned apps**: keep chosen apps in the popup.
- **Ignored apps**: apps Deci does not control.
- **Scroll wheel**: scroll over a volume slider to change it.
- **Per-app output**: send an app to one output device.
- **Multi-device output**: play to several outputs at once.
- **Device priority**: rank your outputs. Deci uses the highest-ranked one that is connected.
- **Input devices**: volume controls for microphones and other inputs.
- **External displays**: monitor volume over HDMI or DisplayPort (DDC).
- **10-band EQ**: built-in and custom presets.
- **AutoEQ**: headphone profiles from the [AutoEq project](https://github.com/jaakkopasanen/AutoEq), or your own ParametricEQ.txt file.
- **Loudness compensation**: ISO 226:2023 equal-loudness contours.
- **Menu bar icon**: Default, Speaker, Device, Waveform or Equalizer.
- **URL schemes**: `deci://` and `advancedaudiocontrol://` links. See the [URL schemes guide](guide/url-schemes.md).

### Keyboard and media keys

- **Volume keys**: F11 and F12 change the volume by 10% per press. With Command the step is 5%, and with Command+Shift it is 1%. F10 mutes. The steps can be changed in Settings, from 1% to 50%.
- **Toggle popup**: a global shortcut opens and closes the Deci popup.
- **Music hotkeys**: global shortcuts to save the playing song to a playlist, like it, or dislike it. Disliking also skips the song.
- **Popup keys**: arrow keys move, M mutes, and Escape closes.

### YouTube Music

The player is in the Music popup, which has its own menu bar icon (shown by default).

- **Search and library**: search songs, albums and artists. Browse playlists, albums and Downloads.
- **Up next**: Play next, Add to queue and Remove from queue on any song.
- **Likes, dislikes and history**: like or dislike songs, and see what you have played.
- **Autoplay radio**: when Autoplay is on, playback continues with similar songs.
- **Offline downloads**: songs, playlists and albums. Downloads play with no network and without signing in.
- **Resume**: if you reopen Deci within an hour, it resumes the last song, the queue and the position.
- **Media keys**: F8 plays or pauses, F7 goes back and F9 skips forward. If the Chrome tab in front is playing, the keys control that tab. Otherwise they control the Deci player.

### Chrome tabs

- **Volume and mute**: per-tab volume and mute for Chrome tabs, through the bundled Deci Audio Companion extension. Works without turning the tab on.
- **Boost, EQ and output device**: turn a tab on from the Deci button in Chrome's toolbar, or with Alt+Shift+D (the suggested shortcut).

## Requirements

- macOS 15.4 or later, on Apple silicon or Intel. The DMG is a universal build.
- Optional: Google Chrome for Chrome tabs, and a Google account for YouTube Music.

## Install

1. Download `Deci-<version>.dmg` from the [latest release](https://github.com/DragonF1/deci/releases/latest).
2. Open the DMG and drag Deci into Applications.

Run Deci from `/Applications` or `~/Applications`. The Chrome helper registers automatically only from those two folders.

### First launch

Deci is not notarized by Apple, so macOS blocks the first launch once.

1. Open Deci. When macOS says it cannot verify the app, click Done.
2. Open System Settings > Privacy & Security, scroll to Security, click Open Anyway next to Deci, and confirm.

Terminal alternative: `xattr -dr com.apple.quarantine /Applications/Deci.app`

### Permissions

- **Screen & System Audio Recording** (required): Deci needs it to control each app's volume. Turn it on under System Settings > Privacy & Security > Screen & System Audio Recording.
- **Accessibility** (for the F10, F11 and F12 keys): Settings > Shortcuts > Media Keys shows a Grant button until it is on.

### Chrome extension (optional)

1. Open Settings from the gear button in the popup, then go to General. If the Chrome section says the extension is not connected, click Install Extension. Chrome must be installed first.
2. Deci copies the extension, puts its folder path on the clipboard, and opens chrome://extensions.
3. In Chrome, turn on Developer mode (top right), click Load unpacked, press Cmd+Shift+G, paste the path, press Return, then click Select.
4. The message in Settings goes away once Deci connects. If it stays, click Check Again.

To show tabs from incognito windows, turn on Incognito tabs in the same section, then turn on Allow in Incognito for Deci on chrome://extensions.

### YouTube Music (optional)

1. Open the Music popup and click Sign in.
2. Sign in to Google in the window Deci opens. If the account has several YouTube channels, pick the one to play as.
3. Deci keeps only youtube.com cookies, stored in the macOS Keychain.

### Updating

Download the new DMG from the latest release, quit Deci, and replace Deci in Applications.

## Note

Deci is unofficial. Its YouTube Music player is not affiliated with or endorsed by Google or YouTube.

## Building from source

Requires Xcode 26 or later.

```bash
open Deci.xcodeproj

# Or from the command line:
xcodebuild -project Deci.xcodeproj -scheme Deci -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

The Xcode build does not include the Chrome helper (`DeciHost`). To build a DMG that includes it, run `scripts/build-dmg.sh`. To install it into `/Applications/Deci.app`, run `scripts/install-chrome-host.sh`.

Guides: [AutoEQ](guide/autoeq.md), [URL schemes](guide/url-schemes.md), [Troubleshooting](guide/troubleshooting.md).

## Credits and license

Deci is a fork of [FineTune](https://github.com/ronitsingh10/FineTune) by Ronit Singh. It is licensed under GPL-3.0. See [LICENSE](LICENSE).
