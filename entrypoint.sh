#!/usr/bin/env bash
set -uo pipefail

DISPLAY_NUM="${DISPLAY_NUM:-:0}"
RESOLUTION="${RESOLUTION:-1920x1080}"
GPU_BUSID="${GPU_BUSID:-PCI:0:16:0}"
VNC_PORT="${VNC_PORT:-5900}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
WS_PORT="${OBS_WEBSOCKET_PORT:-4455}"
WIDTH="${RESOLUTION%x*}"
HEIGHT="${RESOLUTION#*x}"

export DISPLAY="$DISPLAY_NUM"
APP_HOME=/home/app
XDG=/tmp/xdg-app

log() { echo "[entrypoint] $*"; }

as_app() {
  runuser -u app -- env \
    HOME="$APP_HOME" \
    PATH="/usr/bin:/bin" \
    DISPLAY="$DISPLAY" \
    XDG_RUNTIME_DIR="$XDG" \
    XDG_CACHE_HOME="$APP_HOME/.cache" \
    PULSE_SERVER="unix:$XDG/pulse/native" \
    QT_QPA_PLATFORM=xcb \
    QT_XCB_NO_XI2_MOUSE=1 \
    QT_X11_NO_MITSHM=1 \
    "$@"
}

cleanup() {
  log "shutting down..."
  obs_pid="$(pgrep -x obs || true)"
  if [ -n "$obs_pid" ]; then
    log "sending SIGTERM to obs (pid $obs_pid), waiting for clean shutdown..."
    kill -TERM "$obs_pid" 2>/dev/null || true
    for i in $(seq 1 70); do
      kill -0 "$obs_pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$obs_pid" 2>/dev/null; then
      log "obs did not exit in time, forcing"
      kill -KILL "$obs_pid" 2>/dev/null || true
    fi
  fi
  pkill -TERM -P $$ 2>/dev/null || true
  [ -n "${XORG_PID:-}" ] && kill "$XORG_PID" 2>/dev/null || true
}
trap cleanup TERM INT EXIT

for dev in /dev/dri/card* /dev/dri/renderD*; do
  [ -e "$dev" ] || continue
  gid="$(stat -c '%g' "$dev")"
  group="$(getent group "$gid" | cut -d: -f1)"
  if [ -z "$group" ]; then
    group="dri_$gid"
    groupadd -g "$gid" "$group"
  fi
  usermod -aG "$group" app
  log "granted app access to $dev (group $group, gid $gid)"
done

mkdir -p "$XDG" "$APP_HOME/.cache" "$APP_HOME/.config/obs-studio"
chown -R app:app "$XDG" "$APP_HOME/.cache"
chown app:app "$APP_HOME/.config" "$APP_HOME/.config/obs-studio" 2>/dev/null || true
chmod 700 "$XDG"

# Reset the StreamWizard profile's basic.ini (recording-path lockdown,
# encoder defaults) to the shipped golden state on every boot. global.ini
# is deliberately NOT force-reset here: OBS rewrites it itself to track
# which scene collection is actually active, and overwriting that every
# boot caused a reset loop (OBS could never find the scene collection
# global.ini pointed at, so it kept recreating a fresh one - scenes never
# persisted across restarts). global.ini is only seeded once, like the
# websocket config below. plugin_config/logs/crashes/basic/scenes are
# left alone for the same reason - OBS, not us, owns their contents.
GOLDEN_CFG=/opt/obs-golden-config/obs-studio
if [ -d "$GOLDEN_CFG" ]; then
  rsync -a --delete \
    --exclude 'plugin_config/' --exclude 'logs/' --exclude 'crashes/' \
    --exclude 'basic/scenes/' --exclude 'global.ini' \
    "$GOLDEN_CFG/" "$APP_HOME/.config/obs-studio/"
  if [ ! -f "$APP_HOME/.config/obs-studio/global.ini" ] && [ -f "$GOLDEN_CFG/global.ini" ]; then
    cp "$GOLDEN_CFG/global.ini" "$APP_HOME/.config/obs-studio/global.ini"
  fi
  chown -R app:app "$APP_HOME/.config/obs-studio"
  log "restored golden OBS config (StreamWizard profile reset to shipped state)"
fi

rm -f "$APP_HOME/.config/obs-studio/plugin_config/obs-browser/SingletonLock" \
      "$APP_HOME/.config/obs-studio/plugin_config/obs-browser/SingletonSocket" \
      "$APP_HOME/.config/obs-studio/plugin_config/obs-browser/SingletonCookie"

WS_CFG="$APP_HOME/.config/obs-studio/plugin_config/obs-websocket/config.json"
if [ ! -f "$WS_CFG" ]; then
  mkdir -p "$(dirname "$WS_CFG")"
  if [ -z "${OBS_WEBSOCKET_PASSWORD:-}" ]; then
    OBS_WEBSOCKET_PASSWORD="$(head -c 24 /dev/urandom | base64)"
    PW_FILE="$APP_HOME/.config/obs-studio/.websocket_password"
    printf '%s\n' "$OBS_WEBSOCKET_PASSWORD" > "$PW_FILE"
    chmod 600 "$PW_FILE"
    chown app:app "$PW_FILE"
    log "no OBS_WEBSOCKET_PASSWORD set; generated a random password and saved it to $PW_FILE (not logged)"
  fi
  cat > "$WS_CFG" <<EOF
{
    "alerts_enabled": false,
    "auth_required": true,
    "first_load": false,
    "server_enabled": true,
    "server_password": "${OBS_WEBSOCKET_PASSWORD}",
    "server_port": ${WS_PORT}
}
EOF
  chown -R app:app "$APP_HOME/.config/obs-studio/plugin_config"
  log "seeded obs-websocket config (enabled, auth required, port ${WS_PORT})"
fi

sed -e "s/__WIDTH__/$WIDTH/" -e "s/__HEIGHT__/$HEIGHT/" \
    -e "s#__BUSID__#$GPU_BUSID#" \
    /etc/X11/xorg.conf.template > /etc/X11/xorg.conf

# A prior Xorg run can leave a stale lock behind if the container was
# killed rather than stopped cleanly (restart: unless-stopped reuses the
# same writable layer, so /tmp isn't wiped between runs).
DISPLAY_NUM_BARE="${DISPLAY_NUM#:}"
LOCK_FILE="/tmp/.X${DISPLAY_NUM_BARE}-lock"
SOCK_FILE="/tmp/.X11-unix/X${DISPLAY_NUM_BARE}"
if [ -e "$LOCK_FILE" ]; then
  lock_pid="$(cat "$LOCK_FILE" 2>/dev/null | tr -d '[:space:]')"
  if [ -z "$lock_pid" ] || ! kill -0 "$lock_pid" 2>/dev/null; then
    log "removing stale X lock for display $DISPLAY_NUM (pid $lock_pid not running)"
    rm -f "$LOCK_FILE" "$SOCK_FILE"
  fi
fi

log "starting Xorg on $DISPLAY ($RESOLUTION, $GPU_BUSID)"
Xorg "$DISPLAY" -config /etc/X11/xorg.conf -ac -nolisten tcp \
     -novtswitch -sharevts -logfile /tmp/xorg.log vt1 &
XORG_PID=$!

for i in $(seq 1 40); do
  if as_app xset q >/dev/null 2>&1; then break; fi
  if ! kill -0 "$XORG_PID" 2>/dev/null; then
    log "ERROR: Xorg died during startup. Last log lines:"; tail -n 40 /tmp/xorg.log; exit 1
  fi
  sleep 0.5
done
if ! as_app xset q >/dev/null 2>&1; then
  log "ERROR: X server never became ready. Xorg log:"; tail -n 40 /tmp/xorg.log; exit 1
fi
log "X is up. Renderer: $(as_app glxinfo 2>/dev/null | grep -m1 'OpenGL renderer' || echo 'glxinfo unavailable')"

as_app openbox &
sleep 1
as_app xsetroot -solid black

cat > "$XDG/headless.pa" <<'PA'
load-module module-native-protocol-unix
load-module module-null-sink sink_name=obs_sink sink_properties=device.description=OBS_Output
set-default-sink obs_sink
PA
chown app:app "$XDG/headless.pa"
as_app pulseaudio -n --file="$XDG/headless.pa" --exit-idle-time=-1 --daemonize=yes 2>/dev/null || true
sleep 1
as_app pactl info >/dev/null 2>&1 && log "pulse up (sink: obs_sink)" || log "pulse unavailable (non-fatal; browser-source audio is internal to OBS)"

log "starting x11vnc on :$VNC_PORT and noVNC on :$NOVNC_PORT"
as_app x11vnc -display "$DISPLAY" -forever -shared -nopw -noshm -noxdamage \
       -repeat -rfbport "$VNC_PORT" -quiet &
for i in $(seq 1 20); do
  (exec 3<>/dev/tcp/127.0.0.1/"$VNC_PORT") 2>/dev/null && { exec 3>&- 3<&-; break; }
  sleep 0.5
done
websockify "$NOVNC_PORT" "localhost:$VNC_PORT" >/tmp/websockify.log 2>&1 &

mkdir -p "$APP_HOME/media"
chown app:app "$APP_HOME/media"

# Jail OBS in its own mount namespace so file pickers (Add Source, Open,
# Import, ...) can only see its config/cache and the media folder, not the
# rest of the image. Everything else stays read-only or absent. /etc is
# bound in whole (no secrets live there in this image) so fonts, certs and
# NSS lookups keep working; /dev is a synthetic minimal tree, see below.
BWRAP_ARGS=(
  --unshare-pid
  --die-with-parent
  --proc /proc
  --dev /dev
  --ro-bind /usr /usr
  --ro-bind /etc /etc
)
# `--dev /dev` gives the jail its own minimal synthetic /dev (null, zero,
# full, random, urandom, tty, pts, ...). On top of that we explicitly
# allowlist only the GPU/NVENC device nodes OBS actually needs, instead of
# binding the whole host /dev tree. /dev/video* (v4l2loopback, used for
# OBS's virtual camera output) and /dev/snd (unused; audio goes over the
# pulseaudio unix socket) are deliberately left out of the jail's view.
for dev in /dev/dri/card* /dev/dri/renderD* /dev/nvidia*; do
  [ -e "$dev" ] && BWRAP_ARGS+=(--dev-bind "$dev" "$dev")
done
[ -d /sys ] && BWRAP_ARGS+=(--ro-bind /sys /sys)
for d in bin sbin lib lib64; do
  if [ -L "/$d" ]; then
    BWRAP_ARGS+=(--symlink "$(readlink "/$d")" "/$d")
  elif [ -d "/$d" ]; then
    BWRAP_ARGS+=(--ro-bind "/$d" "/$d")
  fi
done
[ -d /tmp/.X11-unix ] && BWRAP_ARGS+=(--bind /tmp/.X11-unix /tmp/.X11-unix)
BWRAP_ARGS+=(
  --bind "$XDG" "$XDG"
  --dir "$APP_HOME"
  --bind "$APP_HOME/.config/obs-studio" "$APP_HOME/.config/obs-studio"
  --bind "$APP_HOME/.cache" "$APP_HOME/.cache"
  --bind "$APP_HOME/media" "$APP_HOME/media"
  --chdir "$APP_HOME"
)

# Settings lockdown was tried here as read-only bwrap binds over
# global.ini/basic.ini/the websocket config, layered on top of the
# writable .config/obs-studio bind above. Reverted: OBS doesn't just read
# these files, it re-saves them at various points (e.g. switching to a
# profile re-saves that profile's basic.ini; obs-websocket periodically
# re-saves its own config.json) - with the file read-only, that save
# fails, and for basic.ini specifically that crashed the whole obs process
# (observed: switching to the StreamWizard profile killed the container).
# Settings immutability across restarts is instead handled entirely by
# the golden-config rsync restore above, which resets these files on
# every boot without needing them to be read-only *during* a session.

log "launching OBS (idle, no auto-stream), jailed via bwrap"
rm -rf "$APP_HOME/.config/obs-studio/.sentinel" 2>/dev/null || true
as_app dbus-run-session -- bwrap "${BWRAP_ARGS[@]}" obs --disable-missing-files-check &
OBS_PID=$!

( for i in $(seq 1 30); do
    if as_app xdotool search --class obs >/dev/null 2>&1; then
      sleep 1
      as_app wmctrl -r OBS -b add,maximized_vert,maximized_horz 2>/dev/null || true
      break
    fi
    sleep 1
  done ) &

wait "$OBS_PID"