#!/usr/bin/env bash
# Twitch returns status.result == "warning" for sub-spec GPUs (RTX 2070 vs the
# recommended RTX 3070+ for dual-format 1080p). OBS pops a modal Yes/No
# QMessageBox titled "Warning" ("Do you want to continue streaming?") and BLOCKS
# go-live until a human clicks Yes (GoLiveAPI_Network.cpp::HandleGoLiveApiErrors).
# There is no setting to skip it; headless/obs-websocket starts otherwise hang.
# QMessageBox::exec() runs a nested event loop, so X stays responsive and we can
# press the default (Yes) button. Runs as 'app' on OBS's X display, outside bwrap.
set -u
export DISPLAY="${DISPLAY:-:0}"

while :; do
  for wid in $(xdotool search --name '^Warning$' 2>/dev/null); do
    cls="$(xdotool getwindowclassname "$wid" 2>/dev/null || true)"
    [ "$cls" = "obs" ] || continue
    xdotool windowactivate --sync "$wid" key --clearmodifiers Return 2>/dev/null || true
  done
  sleep 0.5
done
