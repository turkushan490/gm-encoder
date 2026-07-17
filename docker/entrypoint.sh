#!/usr/bin/env bash
# =============================================================================
# entrypoint.sh  -  set up user/permissions (Unraid style) then run the watcher
# =============================================================================
set -uo pipefail

# ---- timezone ----
if [[ -n "${TZ:-}" && -f "/usr/share/zoneinfo/${TZ}" ]]; then
    ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime
    echo "$TZ" > /etc/timezone
fi

umask "${UMASK:-022}"

# ---- create a non-root user matching PUID/PGID (Unraid = 99:100) ----
PUID="${PUID:-99}"
PGID="${PGID:-100}"

if ! getent group "$PGID" >/dev/null 2>&1; then
    groupadd -g "$PGID" gmenc 2>/dev/null || true
fi
GRP_NAME="$(getent group "$PGID" | cut -d: -f1)"; GRP_NAME="${GRP_NAME:-gmenc}"

if ! getent passwd "$PUID" >/dev/null 2>&1; then
    useradd -o -u "$PUID" -g "$PGID" -M -d /config -s /usr/sbin/nologin gmenc 2>/dev/null || true
fi
USR_NAME="$(getent passwd "$PUID" | cut -d: -f1)"; USR_NAME="${USR_NAME:-gmenc}"

# ---- give the user access to the render node (for QSV/VAAPI) ----
for dev in /dev/dri/renderD128 /dev/dri/renderD129 /dev/dri/card0 /dev/dri/card1; do
    if [[ -e "$dev" ]]; then
        gid="$(stat -c %g "$dev" 2>/dev/null || echo '')"
        if [[ -n "$gid" ]]; then
            grp="$(getent group "$gid" | cut -d: -f1)"
            [[ -z "$grp" ]] && { grp="render_$gid"; groupadd -g "$gid" "$grp" 2>/dev/null || true; }
            usermod -aG "$grp" "$USR_NAME" 2>/dev/null || true
        fi
    fi
done

mkdir -p "$CONFIG_DIR" "$OUTPUT_DIR" 2>/dev/null || true
chown -R "$PUID:$PGID" "$CONFIG_DIR" 2>/dev/null || true

echo "[entrypoint] running as ${USR_NAME}(${PUID}):${GRP_NAME}(${PGID}), umask ${UMASK}"

# ---- web GUI (background, auto-restart) ----
(
  while true; do
    gosu "$PUID:$PGID" python3 /app/server.py
    echo "[entrypoint] web server exited, restarting in 3s..."
    sleep 3
  done
) &

# ---- watch/encode loop (foreground; container lives as long as this does) ----
exec gosu "$PUID:$PGID" /app/watch.sh
