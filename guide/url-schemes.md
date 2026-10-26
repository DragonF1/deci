# URL Schemes

Control Deci from Terminal, shell scripts, [Shortcuts](https://support.apple.com/guide/shortcuts-mac), [Raycast](https://raycast.com), or any app that can open URLs. This makes it easy to automate volume changes, build keyboard shortcuts, or integrate Deci into your workflow.

Deci registers the `deci://` scheme. The older `advancedaudiocontrol://` and `finetune://` schemes also work. The examples below use `deci://`.

## Actions

| Action | Format | Description |
|--------|--------|-------------|
| Set volume | `deci://set-volumes?app=BUNDLE_ID&volume=PERCENT` | Set volume from 0 to 100 |
| Step volume | `deci://step-volume?app=BUNDLE_ID&direction=up` | Nudge volume up or down by one 5% slider step |
| Set mute | `deci://set-mute?app=BUNDLE_ID&muted=true` | Mute or unmute an app |
| Toggle mute | `deci://toggle-mute?app=BUNDLE_ID` | Toggle mute state |
| Set device | `deci://set-device?app=BUNDLE_ID&device=DEVICE_UID` | Route an app to a specific output |
| Reset | `deci://reset` | Reset active apps to 100% and unmuted. Add `?app=BUNDLE_ID` to reset specific apps. |

## Examples

```bash
# Set Spotify to 50% volume
open "deci://set-volumes?app=com.spotify.client&volume=50"

# Set different volumes for different apps at once
open "deci://set-volumes?app=com.spotify.client&volume=80&app=com.hnc.Discord&volume=40"

# Mute multiple apps at once
open "deci://set-mute?app=com.spotify.client&muted=true&app=com.apple.Music&muted=true"

# Step Discord volume down
open "deci://step-volume?app=com.hnc.Discord&direction=down"

# Route an app to a specific device
open "deci://set-device?app=com.spotify.client&device=YOUR_DEVICE_UID"

# Reset everything
open "deci://reset"
```

## Use Cases

**Meeting mode**: mute everything except your video call app:

```bash
open "deci://set-mute?app=com.spotify.client&muted=true&app=com.apple.Music&muted=true"
```

**Focus playlist**: set music to a low background level and silence notifications:

```bash
open "deci://set-volumes?app=com.spotify.client&volume=30&app=com.apple.systemuiserver&volume=0"
```

**Gaming setup**: keep the game at full volume and lower Discord. Boost (above 100%) is set in Deci itself, since the URL range is 0 to 100:

```bash
open "deci://set-volumes?app=com.game.example&volume=100&app=com.hnc.Discord&volume=40"
```

These commands work in Terminal, shell scripts, Automator, Raycast script commands, macOS Shortcuts (using "Open URL"), and any other tool that can open URLs.

## Finding Bundle IDs

App names shown in Deci map to bundle IDs. Common ones:

| App | Bundle ID |
|-----|-----------|
| Spotify | `com.spotify.client` |
| Apple Music | `com.apple.Music` |
| Chrome | `com.google.Chrome` |
| Safari | `com.apple.Safari` |
| Discord | `com.hnc.Discord` |
| Slack | `com.tinyspeck.slackmacgap` |
| Zoom | `us.zoom.xos` |
| Firefox | `org.mozilla.firefox` |
| Arc | `company.thebrowser.Browser` |

To find any app's bundle ID:

```bash
osascript -e 'id of app "App Name"'
```

## Finding Device UIDs

In Deci, click the pencil icon to enter edit mode, click the **info button** on a device row to open the device inspector, then click the copy button next to the UID to put it on the clipboard.
