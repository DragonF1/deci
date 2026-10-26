# Troubleshooting

## No sound / audio stops working

Deci requires the **Screen & System Audio Recording** permission to capture and route app audio.

1. Open **System Settings** → **Privacy & Security** → **Screen & System Audio Recording**
2. Find Deci in the list and enable it
3. If audio still doesn't work, quit and reopen Deci

If you previously denied the permission prompt, you'll need to enable it manually from System Settings.

## App not appearing

Deci shows apps that are **actively playing audio**, plus any apps you have pinned. If an app isn't visible:

- Make sure the app is actually producing sound (start playback)
- Check if the app is hidden. Open **edit mode** (pencil icon) and look for the eye icon next to the app name. A crossed-out eye means the app is being ignored.
- Some apps use helper processes for audio. Try restarting the app.

## App causing audio issues

Some apps don't work well with CoreAudio process taps, particularly audio processors, DAWs, VoIP tools, and apps that do their own low-level audio routing. Symptoms include distorted audio, echo, or audio cutting out.

**Fix:** Open **edit mode** (pencil icon) and click the eye icon to ignore the problematic app. This tears down the process tap entirely for that app, so it goes back to normal macOS audio routing.

Common apps that may need to be ignored:
- Audio Hijack, Loopback, and other Rogue Amoeba apps
- Some VoIP/conferencing tools with custom audio engines
- FaceTime, WhatsApp, and other calling apps (tapping can break echo cancellation, causing volume ducking)

## Volume slider not working

There are two cases.

**Per-app slider.** Some apps use helper processes to play audio rather than the main app process, so the slider you see might be controlling the wrong process. Try restarting the app.

**Per-device slider.** When you open a device, Deci picks a volume backend automatically:

- **Hardware**: the device reports a native volume control (most USB DACs, AirPods, built-in speakers).
- **DDC**: an external display that responds to the monitor-control protocol.
- **Software**: Deci attenuates inside its own audio graph.

Auto-detection gets it right for most devices, but some USB DACs and HDMI/DisplayPort outputs advertise a hardware slider that doesn't actually move the output level. If the device slider doesn't change the volume, open the device details (the info button on the device row in edit mode) and turn on **Use Deci's software volume**. Deci remembers the choice per device.

## Audio device not switching automatically

Deci uses a **device priority list** to decide which output device to use. When a device connects, Deci only switches to it if it's ranked higher than the current device. When a device disconnects, Deci falls back to the next highest-priority device that's still connected.

By default, devices are added to the bottom of the list in the order they're first seen. Since your Mac's built-in speakers are always connected, they end up at the top (highest priority), so Deci won't auto-switch to headphones, external speakers, or other devices when they connect.

**This is a one-time setup.** Once you set your preferred order, it's saved and works across app restarts.

**How to reorder:**

1. Click the **pencil icon** in the menu bar popup to enter edit mode
2. **Drag** devices to reorder, or **click the priority number** and type a new position
3. Click the **checkmark** to exit edit mode. Your order is saved.

The device at position 1 has the highest priority. Deci will always prefer the highest-priority device that's currently connected.

Input and output devices have **separate priority lists**. Switch between them using the Output and Input tabs in edit mode.

> **Note:** For AirPods, taking them out of your ears and putting them back in (without the case) is handled by macOS Automatic Ear Detection. Deci doesn't interfere with that.

## Input devices not showing

Deci's input device monitoring requires separate microphone permission.

1. Open **System Settings** → **Privacy & Security** → **Microphone**
2. Find Deci and enable it
3. Restart Deci

## Media keys don't control Deci

Media keys (F10 / F11 / F12) are on by default and require the **Accessibility** permission so Deci can observe the keystrokes.

1. Open **System Settings** → **Privacy & Security** → **Accessibility**
2. Enable Deci in the list. If it's already on, turn it off and back on.
3. Open Deci **Settings** → **Shortcuts** → **Media Keys**, make sure **Media Keys Control** is on, and pick a **HUD Style** (Tahoe or Classic)

## Volume HUD not appearing

- The HUD appears when media keys change the volume, so check that **Media Keys Control** is on in Settings → **Shortcuts** → **Media Keys**. Deci has no separate on/off switch for the HUD.
- Switch HUD styles if one isn't rendering. **Tahoe** is a small pill at the top right. **Classic** is a panel at the bottom center with 16 segments.

## EQ not applying / sounds the same

- The EQ is enabled by default. Check that the **switch** in the EQ panel header is on.
- The default preset is **Flat** (all bands at 0 dB), which makes no audible changes. Select a different preset or adjust the bands manually.
- EQ is **per-app**, not per-device. Make sure you're adjusting the EQ for the correct app.
- If using AutoEQ headphone correction, that's separate from the 10-band EQ. Verify a profile is assigned to the correct device via the wand icon.

## Audio quality sounds degraded

- Check if volume boost is set above 1x. High boost levels can cause clipping on loud passages.
- If using EQ, large boosts across multiple bands can push levels too high. Try pulling bands down instead of boosting others up.
- AutoEQ profiles apply their Preamp value before the filters. The 10-band EQ has no preamp, so keep the total gain in mind.
- Reset all app volumes to 100% and unmuted: `open "deci://reset"` in Terminal. This resets volume and mute only, not EQ or device settings.
