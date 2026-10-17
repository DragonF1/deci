#!/bin/bash
# Tap soak: runs the Debug build through tap configs and logs every exact-zero
# input run, to find a tap setup that coreaudiod's 10 s cycle does not kill.
#
# Needs a known-continuous source on the default output while it runs, e.g. a
# 19 kHz tone at -50 dBFS in a Chrome tab and in QuickTime (inaudible, never
# exact zero), so any [ZERORUN] onset for those apps is a dead tap.
#
#   scripts/soak-taps.sh [minutes per config, default 15]
#
# Env: DECI_SOAK_APP (Debug Deci.app), DECI_SOAK_DIR (output dir with a
# settings/ copy), DECI_SOAK_CONFIGS (default "A B C").
#   A  baseline (device-stream taps for follows-default apps)
#   B  DECI_DEBUG_TAP_SOURCE=mixdown
#   C  DECI_DEBUG_TAP_DRIFT=on
# Every config runs with DECI_DEBUG_ZERO_LOG=1 and DECI_DEBUG_REFRESH_S=7, so
# Deci's own refresh loop can be told apart from coreaudiod's 10 s cycle.
# If A shows no onset it runs a second A block; still none means the rig does
# not reproduce the bug and the script stops (exit 2).
#
# The app is launched through LaunchServices (open -n --env): run straight from
# a shell, TCC charges audio capture to the shell's responsible process and no
# tap is created. A fresh tap's first callbacks are zeros, so onsets with
# prevCb=n/a (startup runs) are not counted as deaths.
#
# The onset count is only a first cut. A paused player (YouTube Music) leaves
# its output stream running and writes exact zeros, so check <cfg>-playback.log
# before calling an onset a death: in the 2026-10-17 soak every long Chrome run
# began 0.3-0.5 s after a Playing->Paused and ended at Paused->Playing, because
# the tone tab had stopped feeding Chrome. Keep the tone tab open and check it
# is still playing. A looping WAV also shows one short run per loop.
set -u

MIN=${1:-15}
BUNDLE=${DECI_SOAK_APP:-/Volumes/Storage/_build/deci/Build/Products/Debug/Deci.app}
APP=$BUNDLE/Contents/MacOS/Deci
OUT=${DECI_SOAK_DIR:-/Volumes/Storage/_build/scratch/deci-soak}
CONFIGS=${DECI_SOAK_CONFIGS:-"A B C"}

[ -x "$APP" ] || { echo "No Debug build at $APP"; exit 1; }
[ -f "$OUT/settings/settings.json" ] || { echo "No settings copy in $OUT/settings"; exit 1; }
# Two Decis would tap the same apps twice.
pgrep -qf '/Applications/Deci.app/Contents/MacOS/Deci$' && { echo "Quit the installed Deci first"; exit 1; }

config_env() {
  case $1 in
    A*) ;;
    B*) echo "DECI_DEBUG_TAP_SOURCE=mixdown" ;;
    C*) echo "DECI_DEBUG_TAP_DRIFT=on" ;;
  esac
}

# run_config <name> <minutes>: sets ONSETS to the Chrome/QuickTime onset count.
run_config() {
  local name=$1 minutes=$2 start end extra onsets
  local -a envs=(--env "DECI_DEBUG_SETTINGS_DIR=$OUT/settings" --env DECI_DEBUG_ZERO_LOG=1 --env DECI_DEBUG_REFRESH_S=7)
  extra=$(config_env "$name")
  [ -n "$extra" ] && envs+=(--env "$extra")
  start=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$start] config $name for $minutes min ${extra:-(baseline)}"
  open -n -g "${envs[@]}" "$BUNDLE" || { echo "launch failed"; exit 1; }
  sleep $((minutes * 60))
  pkill -f "$APP" 2>/dev/null
  sleep 3
  end=$(date '+%Y-%m-%d %H:%M:%S')
  /usr/bin/log show --style compact --start "$start" --end "$end" \
    --predicate 'subsystem == "com.abraham.Deci" AND (eventMessage CONTAINS "[ZERORUN]" OR eventMessage CONTAINS "[SOAK]" OR eventMessage CONTAINS "[WATCHDOG]")' \
    >"$OUT/$name-deci.log"
  /usr/bin/log show --style compact --start "$start" --end "$end" \
    --predicate 'process == "coreaudiod" AND eventMessage CONTAINS "RTAID"' \
    >"$OUT/$name-rtaid.log"
  /usr/bin/log show --style compact --start "$start" --end "$end" \
    --predicate 'process == "mediaremoted" AND eventMessage CONTAINS "PlaybackState changed"' \
    >"$OUT/$name-playback.log"
  onsets=$(grep -E '\[ZERORUN\] onset' "$OUT/$name-deci.log" | grep -E 'Chrome|QuickTime' | grep -cv 'prevCb=n/a')
  echo "[$end] config $name done: $onsets Chrome/QuickTime onsets"
  ONSETS=$onsets
}

for cfg in $CONFIGS; do
  run_config "$cfg" "$MIN"
  if [ "$cfg" = A ] && [ "$ONSETS" -eq 0 ]; then
    run_config A2 "$MIN"
    if [ "$ONSETS" -eq 0 ]; then
      echo "No dead tap in $((MIN * 2)) min of baseline: the rig does not reproduce the bug."
      exit 2
    fi
  fi
done
echo "Soak done. Logs in $OUT"
