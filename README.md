# Advanced Audio Control

Advanced per-app volume mixer, multi-device audio router, parametric EQ, and audio enhancer for macOS.

Control the volume of every app independently, boost quiet ones up to 4x, route audio to different output devices simultaneously, and shape your sound with 10-band EQ and AutoEQ headphone correction. Lives right in your menu bar.

## Features

### 🎚 Volume Control
- **Per-App Volume** — Individual sliders and mute for each application
- **Per-App Volume Boost** — 2x / 3x / 4x gain presets for quiet media
- **Pinned Apps** — Keep apps visible in the menu bar even when not playing audio
- **Ignore Apps** — Completely bypass apps from audio tapping
- **Scroll-Wheel Volume** — Hover any slider in the popup, HUD, or EQ panel and scroll to adjust

### ⌨️ Keyboard & Media Keys
- **Global Volume Hotkeys** — Bind custom keys for App Volume Up / Down / Mute
- **Toggle Popup from Anywhere** — Global shortcut to toggle the menu bar extra
- **Configurable Step Size** — Coarse, Normal, Fine, or Extra-Fine adjustment steps
- **Keyboard Navigation** — Arrow keys to navigate rows and adjust levels, M to mute, Esc to close

### 🔀 Multi-Device Audio Routing
- **Multi-Device Output** — Route audio to multiple devices simultaneously
- **Per-App Output Routing** — Direct apps to different outputs or follow system default
- **Device Priority & Auto-Restore** — Priority ordering and automatic reconnection restore

### 🎛 EQ & Acoustic Correction
- **10-Band EQ** — Parametric equalization with custom user presets
- **AutoEQ Headphone Correction** — Integrated profile database and ParametricEQ.txt import
- **Loudness Compensation** — ISO 226 equal-loudness contour bass/treble compensation at low volumes

### 🖥 Display & Device Control
- **Input Device Control** — Monitor and adjust microphone levels
- **External Display Volume via DDC** — Adjust monitor volume over HDMI/DisplayPort
- **Customizable Menu Bar Icons** — Default, Speaker, Waveform, or Equalizer styles
- **URL Schemes** — Control volume and routing programmatically via `advancedaudiocontrol://`

## Requirements

- macOS 15.0 (Sequoia) or later
- Audio capture permission (prompted on first launch)

## Building from Source

```bash
open AdvancedAudioControl.xcodeproj
```

Or using `xcodebuild`:

```bash
xcodebuild -project AdvancedAudioControl.xcodeproj -scheme AdvancedAudioControl -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

## License

[GPL v3](LICENSE)
