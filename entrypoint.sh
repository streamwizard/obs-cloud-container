#!/usr/bin/env bash
set -uo pipefail

# ROLE selects which of two things this container instance is:
#   gpu-xserver - the one real, GPU-bound Xorg per physical GPU (holds the
#                 NVIDIA DRM master lease). Exactly one of these per node.
#   instance (default) - a headless OBS instance. Runs its own lightweight
#                 Xvfb (no GPU, no VT, no DRM master - so any number of
#                 these can coexist) and renders through the shared
#                 gpu-xserver via `vglrun`. See xorg.conf.template and the
#                 VirtualGL comments below for why: NVIDIA only allows one
#                 exclusive DRM master per physical GPU, so N containers
#                 each running their own nvidia-driven Xorg cannot share
#                 one card - VirtualGL lets many Xvfb-backed instances
#                 share the one real GPU-bound Xorg instead.
ROLE="${ROLE:-instance}"

DISPLAY_NUM="${DISPLAY_NUM:-:10}"
RESOLUTION="${RESOLUTION:-1920x1080}"
GPU_BUSID="${GPU_BUSID:-PCI:0:16:0}"
VNC_PORT="${VNC_PORT:-5900}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
WS_PORT="${OBS_WEBSOCKET_PORT:-4455}"
WIDTH="${RESOLUTION%x*}"
HEIGHT="${RESOLUTION#*x}"

# Fixed display number of the shared gpu-xserver's real Xorg - a singleton
# per node, so this never needs to be configurable per instance.
GPU_XSERVER_DISPLAY=":0"
GPU_XSOCKET_DIR=/opt/gpu-xsocket

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

if [ "$ROLE" = "gpu-xserver" ]; then
  cleanup() {
    log "shutting down gpu-xserver..."
    [ -n "${XORG_PID:-}" ] && kill "$XORG_PID" 2>/dev/null || true
  }
  trap cleanup TERM INT EXIT

  sed -e "s/__WIDTH__/$WIDTH/" -e "s/__HEIGHT__/$HEIGHT/" \
      -e "s#__BUSID__#$GPU_BUSID#" \
      /etc/X11/xorg.conf.template > /etc/X11/xorg.conf

  # A prior Xorg run can leave a stale lock behind if the container was
  # killed rather than stopped cleanly.
  DISPLAY_NUM_BARE="${GPU_XSERVER_DISPLAY#:}"
  LOCK_FILE="/tmp/.X${DISPLAY_NUM_BARE}-lock"
  SOCK_FILE="/tmp/.X11-unix/X${DISPLAY_NUM_BARE}"
  if [ -e "$LOCK_FILE" ]; then
    lock_pid="$(cat "$LOCK_FILE" 2>/dev/null | tr -d '[:space:]')"
    if [ -z "$lock_pid" ] || ! kill -0 "$lock_pid" 2>/dev/null; then
      log "removing stale X lock for display $GPU_XSERVER_DISPLAY (pid $lock_pid not running)"
      rm -f "$LOCK_FILE" "$SOCK_FILE"
    fi
  fi

  log "starting shared GPU Xorg on $GPU_XSERVER_DISPLAY ($RESOLUTION, $GPU_BUSID)"
  Xorg "$GPU_XSERVER_DISPLAY" -config /etc/X11/xorg.conf -ac -nolisten tcp \
       -novtswitch -sharevts -logfile /tmp/xorg.log vt1 &
  XORG_PID=$!

  for i in $(seq 1 40); do
    if DISPLAY="$GPU_XSERVER_DISPLAY" as_app xset q >/dev/null 2>&1; then break; fi
    if ! kill -0 "$XORG_PID" 2>/dev/null; then
      log "ERROR: Xorg died during startup. Last log lines:"; tail -n 40 /tmp/xorg.log; exit 1
    fi
    sleep 0.5
  done
  if ! DISPLAY="$GPU_XSERVER_DISPLAY" as_app xset q >/dev/null 2>&1; then
    log "ERROR: X server never became ready. Xorg log:"; tail -n 40 /tmp/xorg.log; exit 1
  fi
  log "shared GPU Xorg is up. Renderer: $(DISPLAY="$GPU_XSERVER_DISPLAY" as_app glxinfo 2>/dev/null | grep -m1 'OpenGL renderer' || echo 'glxinfo unavailable')"

  wait "$XORG_PID"
  exit $?
fi

# --- ROLE=instance (default) below ---

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
  [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null || true
}
trap cleanup TERM INT EXIT

mkdir -p "$XDG" "$APP_HOME/.cache" "$APP_HOME/.config/obs-studio"
chown -R app:app "$XDG" "$APP_HOME/.cache" "$APP_HOME/.config/obs-studio"
chmod 700 "$XDG"

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

# Install any extra OBS plugins dropped into the host-plugins/ mount
# (docker-compose.yml maps it to /opt/extra-plugins, read-only) without
# needing an image rebuild. Real OBS plugins ship in one of two layouts
# depending on the author/build, both confirmed by extracting actual
# release packages rather than guessed:
#   1. System-wide (.deb-style: Aitum, Move, Source Profiler, Source
#      Clone): a bare .so for obs-plugins/, plus a <name>/ data dir for
#      locale files. This MUST run as root, before the bwrap jail below,
#      since bwrap --ro-bind's /usr at the state it's in when bwrap
#      launches - anything copied in after that point would not be
#      visible to OBS inside the jail.
#   2. Per-user (manual-install-style: Advanced Masks, Composite Blur):
#      a <name>/ folder containing bin/64bit/<name>.so and data/ (locale
#      + shaders/etc). These install straight into
#      ~/.config/obs-studio/plugins/, which is already a writable bwrap
#      bind, so timing relative to the jail doesn't matter for these.
EXTRA_PLUGINS_DIR=/opt/extra-plugins
OBS_PLUGINS_DIR=/usr/lib/x86_64-linux-gnu/obs-plugins
OBS_PLUGIN_DATA_DIR=/usr/share/obs/obs-plugins
if [ -d "$EXTRA_PLUGINS_DIR/obs-plugins" ]; then
  cp -a "$EXTRA_PLUGINS_DIR/obs-plugins/." "$OBS_PLUGINS_DIR/"
  chmod -R a+rX "$OBS_PLUGINS_DIR"
  log "installed extra plugin binaries from $EXTRA_PLUGINS_DIR/obs-plugins"
fi
if [ -d "$EXTRA_PLUGINS_DIR/data" ]; then
  mkdir -p "$OBS_PLUGIN_DATA_DIR"
  cp -a "$EXTRA_PLUGINS_DIR/data/." "$OBS_PLUGIN_DATA_DIR/"
  chmod -R a+rX "$OBS_PLUGIN_DATA_DIR"
  log "installed extra plugin data from $EXTRA_PLUGINS_DIR/data"
fi
if [ -d "$EXTRA_PLUGINS_DIR/user-plugins" ]; then
  USER_PLUGINS_DST="$APP_HOME/.config/obs-studio/plugins"
  mkdir -p "$USER_PLUGINS_DST"
  cp -a "$EXTRA_PLUGINS_DIR/user-plugins/." "$USER_PLUGINS_DST/"
  chown -R app:app "$USER_PLUGINS_DST"
  chmod -R a+rX "$USER_PLUGINS_DST"
  log "installed extra per-user plugins from $EXTRA_PLUGINS_DIR/user-plugins"
fi

# Link the shared gpu-xserver's X11 socket into our own (still
# container-local) /tmp/.X11-unix under its fixed display number, so
# `vglrun`/VGL_DISPLAY can reach it by the ordinary X11 unix-socket path
# without needing to share all of /tmp/.X11-unix (which stays container-
# local for CEF's own singleton socket) across every instance.
mkdir -p /tmp/.X11-unix
GPU_XSOCKET_BARE="${GPU_XSERVER_DISPLAY#:}"
if [ -S "$GPU_XSOCKET_DIR/X${GPU_XSOCKET_BARE}" ]; then
  ln -sf "$GPU_XSOCKET_DIR/X${GPU_XSOCKET_BARE}" "/tmp/.X11-unix/X${GPU_XSOCKET_BARE}"
else
  log "ERROR: shared GPU X server socket $GPU_XSOCKET_DIR/X${GPU_XSOCKET_BARE} not found - is the gpu-xserver container running?"
  exit 1
fi

# A prior Xvfb run can leave a stale lock behind if the container was
# killed rather than stopped cleanly.
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

log "starting Xvfb on $DISPLAY ($RESOLUTION)"
Xvfb "$DISPLAY" -screen 0 "${WIDTH}x${HEIGHT}x24" -nolisten tcp &
XVFB_PID=$!

for i in $(seq 1 40); do
  if as_app xset q >/dev/null 2>&1; then break; fi
  if ! kill -0 "$XVFB_PID" 2>/dev/null; then
    log "ERROR: Xvfb died during startup."; exit 1
  fi
  sleep 0.5
done
if ! as_app xset q >/dev/null 2>&1; then
  log "ERROR: Xvfb never became ready."; exit 1
fi
log "Xvfb is up on $DISPLAY."

# Hard-fail if VirtualGL can't reach the shared gpu-xserver and give us
# real NVIDIA-accelerated rendering - better a loud startup failure than
# a silent fallback to software/Mesa rendering that just looks slow.
VGL_RENDERER="$(as_app env VGL_DISPLAY="$GPU_XSERVER_DISPLAY" vglrun +v glxinfo 2>&1 | grep -m1 'OpenGL renderer')"
log "VirtualGL renderer check: ${VGL_RENDERER:-(no output from vglrun glxinfo)}"
case "$VGL_RENDERER" in
  *NVIDIA*) log "confirmed hardware-accelerated rendering via shared GPU X server" ;;
  *)
    log "ERROR: VirtualGL did not report an NVIDIA renderer - check that the gpu-xserver container is healthy"
    exit 1
    ;;
esac

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
# /usr/bin/vglrun (and friends) are symlinks into /opt/VirtualGL - bind the
# real target too, since --ro-bind /usr above doesn't pull in /opt.
[ -d /opt/VirtualGL ] && BWRAP_ARGS+=(--ro-bind /opt/VirtualGL /opt/VirtualGL)
# /tmp/.X11-unix/X0 (below) is a symlink into the shared gpu-xserver socket
# volume - bind the real target too, so the jail can actually resolve it.
[ -d "$GPU_XSOCKET_DIR" ] && BWRAP_ARGS+=(--ro-bind "$GPU_XSOCKET_DIR" "$GPU_XSOCKET_DIR")
# `--dev /dev` gives the jail its own minimal synthetic /dev (null, zero,
# full, random, urandom, tty, pts, ...). OBS's own GL rendering now goes
# through the shared gpu-xserver via VirtualGL (see VGL_DISPLAY above), so
# this jail no longer needs direct /dev/dri/* access - only /dev/nvidia*
# for NVENC hardware encode, which is a separate CUDA/NVENC context
# unrelated to display/modesetting ownership.
for dev in /dev/nvidia*; do
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
# CEF needs a writable /tmp: Chromium's process singleton creates its
# SingletonSocket in a temp dir under /tmp, and crashpad/other helpers also
# write there. Without this, /tmp is caught by `--remount-ro /` below and
# CefInitialize() fails with "Exit code: 21", so no browser source renders.
# A private tmpfs is its own mount, so --remount-ro / does not touch it
# (same as /dev). Mounted before the X11 bind so the socket dir layers on top.
BWRAP_ARGS+=(--tmpfs /tmp)
[ -d /tmp/.X11-unix ] && BWRAP_ARGS+=(--bind /tmp/.X11-unix /tmp/.X11-unix)
# CEF (browser source) uses /dev/shm for IPC between its browser/GPU/renderer
# processes. bwrap's --dev /dev creates a minimal synthetic devtmpfs that does
# not include /dev/shm, so we bind the host's /dev/shm explicitly.
[ -d /dev/shm ] && BWRAP_ARGS+=(--bind /dev/shm /dev/shm)
BWRAP_ARGS+=(
  --bind "$XDG" "$XDG"
  --dir "$APP_HOME"
  --bind "$APP_HOME/.config/obs-studio" "$APP_HOME/.config/obs-studio"
  --bind "$APP_HOME/.cache" "$APP_HOME/.cache"
  --bind "$APP_HOME/media" "$APP_HOME/media"
  --chdir "$APP_HOME"
  # Pass browser flags directly into the jail so they bypass the as_app env
  # whitelist. --no-sandbox skips chrome-sandbox (safe inside Docker with
  # seccomp/apparmor=unconfined). --disable-gpu prevents the GPU process from
  # racing with the blacklisted-driver detection. /dev/shm is bound rw above,
  # so CEF uses it for IPC/shared memory (do NOT add --disable-dev-shm-usage:
  # it forces shm onto /tmp).
  --setenv OBS_BROWSER_EXTRA_FLAGS "--no-sandbox --disable-gpu"
  --setenv VGL_DISPLAY "$GPU_XSERVER_DISPLAY"
)

# Settings lockdown was tried here as read-only bwrap binds over
# user.ini/basic.ini/the websocket config, layered on top of the writable
# .config/obs-studio bind above. Reverted: OBS doesn't just read these
# files, it re-saves them at various points (e.g. switching to a profile
# re-saves that profile's basic.ini; obs-websocket periodically re-saves
# its own config.json) - with the file read-only, that save fails and gets
# logged as a non-fatal error (confirmed for the websocket config; never
# fully ruled out for basic.ini, since a separate bug - the lockdown
# plugin deleteLater()'ing widgets OBS itself holds raw pointers to - was
# the confirmed cause of the profile-switch crash and got fixed
# separately, see plugin/src/lockdown-plugin.cpp). Config is instead
# seeded by the obs-instance-manager: before this container starts it
# pulls the S3 template (base layer: plugins, default profile/scenes)
# plus the instance's own saved config into the bind-mounted
# .config/obs-studio dir - so nothing needs to be read-only *during* a
# session.

# bwrap's own synthetic root (anything not explicitly bound above, e.g. /)
# is writable by default, which let OBS's file dialogs create new folders
# directly under "/" - harmless on disk (it's an in-memory mount, gone on
# restart) but a real lockdown/UX gap (browsing "/" should not look
# writable). --remount-ro applies to a mount point already bound above;
# it must come after all the real --bind/--dev-bind entries, and does not
# recurse into the writable mounts layered on top of it
# (.config/obs-studio, .cache, media, $XDG), which stay read-write.
#
# /dev (from `--dev /dev` above) is its OWN separate mount, not a child of
# root in the way that matters here, so remounting root read-only doesn't
# touch it - confirmed in testing: folder creation was blocked at "/" but
# still worked under "/dev". Remounting /dev read-only too is safe: the
# read-only flag blocks creating/deleting entries in that mount, but does
# not block read/write I/O on the device nodes already bound into it
# (GPU/NVENC access goes through the device driver, not mount permissions).
BWRAP_ARGS+=(--remount-ro /dev --remount-ro /)

log "launching OBS (idle, no auto-stream), jailed via bwrap, rendering via VirtualGL"
rm -rf "$APP_HOME/.config/obs-studio/.sentinel" 2>/dev/null || true
as_app dbus-run-session -- bwrap "${BWRAP_ARGS[@]}" vglrun obs --disable-missing-files-check &
OBS_PID=$!

( for i in $(seq 1 30); do
    if as_app xdotool search --class obs >/dev/null 2>&1; then
      sleep 1
      as_app wmctrl -r OBS -b add,maximized_vert,maximized_horz 2>/dev/null || true
      break
    fi
    sleep 1
  done ) &

# Auto-confirm Twitch Enhanced Broadcasting go-live warnings so obs-websocket
# stream starts don't hang on a modal nobody can click.
as_app /usr/local/bin/obs-go-live-autoconfirm.sh &

wait "$OBS_PID"
