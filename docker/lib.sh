#!/usr/bin/env bash
# =============================================================================
# lib.sh  -  shared state contract for the watch loop, encoder and web server.
#
# All coordination happens through JSON files in $CONFIG_DIR so the (bash)
# watch/encode side and the (python) web server can talk without a socket.
# =============================================================================

: "${CONFIG_DIR:=/config}"
: "${INPUT_DIR:=/input}"
: "${OUTPUT_DIR:=/output}"

SETTINGS_JSON="$CONFIG_DIR/settings.json"   # persistent, GUI-editable settings
RUNTIME_JSON="$CONFIG_DIR/runtime.json"     # runtime flags: {paused:bool}
STATUS_JSON="$CONFIG_DIR/status.json"       # live status (watch/encode -> GUI)
QUEUE_JSON="$CONFIG_DIR/queue.json"         # manual jobs (GUI -> watch): [paths]
HISTORY_JSONL="$CONFIG_DIR/history.jsonl"   # completed jobs (append)
CURRENT_PGID="$CONFIG_DIR/current.pgid"     # pgid of the running encoder (stop)
STOP_FLAG="$CONFIG_DIR/stop_current"        # exists => stop the current job
LOGFILE="$CONFIG_DIR/gm-encoder.log"

init_state() {
    mkdir -p "$CONFIG_DIR" "$OUTPUT_DIR" 2>/dev/null || true
    [[ -f "$RUNTIME_JSON" ]] || echo '{"paused":false}' > "$RUNTIME_JSON"
    [[ -f "$QUEUE_JSON"   ]] || echo '[]'               > "$QUEUE_JSON"
    [[ -f "$STATUS_JSON"  ]] || echo '{"state":"idle"}' > "$STATUS_JSON"
    touch "$HISTORY_JSONL" 2>/dev/null || true
}

jlog() {
    local line; line="$(date '+%Y-%m-%d %H:%M:%S') | $*"
    echo "$line"
    echo "$line" >> "$LOGFILE" 2>/dev/null || true
}

# cfg KEY  -> value from settings.json if present & non-null, else env $KEY
cfg() {
    local key="$1" val=""
    if [[ -f "$SETTINGS_JSON" ]]; then
        val="$(jq -r --arg k "$key" '.[$k] // empty' "$SETTINGS_JSON" 2>/dev/null)"
    fi
    if [[ -n "$val" ]]; then printf '%s' "$val"; else printf '%s' "${!key-}"; fi
}

is_paused()      { [[ "$(jq -r '.paused // false' "$RUNTIME_JSON" 2>/dev/null)" == "true" ]]; }
stop_requested() { [[ -f "$STOP_FLAG" ]]; }
clear_stop()     { rm -f "$STOP_FLAG" 2>/dev/null || true; }

# st_set KEY TYPE VALUE   (TYPE: str | num)  - merge one field into status.json
st_set() {
    local key="$1" typ="$2" val="$3" tmp
    tmp="$(mktemp "$CONFIG_DIR/.st.XXXXXX")" || return 0
    if [[ "$typ" == "num" ]]; then
        jq --arg k "$key" --argjson v "${val:-0}" '.[$k]=$v' "$STATUS_JSON" > "$tmp" 2>/dev/null \
            && mv -f "$tmp" "$STATUS_JSON" || rm -f "$tmp"
    else
        jq --arg k "$key" --arg v "$val" '.[$k]=$v' "$STATUS_JSON" > "$tmp" 2>/dev/null \
            && mv -f "$tmp" "$STATUS_JSON" || rm -f "$tmp"
    fi
}

# st_reset - back to idle (keeps resolved_codec/watch_enabled)
st_reset() {
    local tmp; tmp="$(mktemp "$CONFIG_DIR/.st.XXXXXX")" || return 0
    jq '{state:"idle", resolved_codec:(.resolved_codec // ""),
         watch_enabled:(.watch_enabled // true), updated:'"$(date +%s)"'}' \
        "$STATUS_JSON" > "$tmp" 2>/dev/null && mv -f "$tmp" "$STATUS_JSON" || rm -f "$tmp"
}

# history_add '<json object>'
history_add() { printf '%s\n' "$1" >> "$HISTORY_JSONL" 2>/dev/null || true; }
