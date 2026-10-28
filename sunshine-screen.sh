#!/usr/bin/env bash
set -euo pipefail
umask 077

CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/sunshine-screen.conf"

# defaults; the config file or environment can override these.
MONITOR_SERIAL=""
MONITOR_NAME=""
DIM_PERCENT=10

if [[ -r "$CONFIG_FILE" ]]; then
    # this is a trusted, user-owned shell config file.
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

MONITOR_SERIAL="${SUNSHINE_SCREEN_SERIAL:-${MONITOR_SERIAL:-}}"
MONITOR_NAME="${SUNSHINE_SCREEN_NAME:-${MONITOR_NAME:-$MONITOR_SERIAL}}"
DIM_PERCENT="${SUNSHINE_SCREEN_DIM_PERCENT:-${DIM_PERCENT:-10}}"

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

if [[ -z "$MONITOR_SERIAL" ]]; then
    die "Set MONITOR_SERIAL in $CONFIG_FILE."
fi

if [[ ! "$DIM_PERCENT" =~ ^[0-9]+$ ]] ||
   (( DIM_PERCENT < 1 || DIM_PERCENT > 99 )); then
    die "DIM_PERCENT must be a whole number from 1 to 99."
fi

command -v ddcutil >/dev/null 2>&1 || die "ddcutil is not installed."

SAFE_SERIAL="$(printf '%s' "$MONITOR_SERIAL" | tr -cd '[:alnum:]_.-')"
[[ -n "$SAFE_SERIAL" ]] || die "Monitor serial contains no usable characters."

if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
    STATE_DIR="$XDG_RUNTIME_DIR/sunshine-screen"
else
    STATE_DIR="/tmp/sunshine-screen-$UID"
fi

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

STATE_FILE="$STATE_DIR/brightness-$SAFE_SERIAL"
PID_FILE="$STATE_DIR/inhibitor-$SAFE_SERIAL.pid"

CURRENT=""
MAX=""

read_brightness() {
    local output parsed

    if ! output="$(ddcutil getvcp --sn "$MONITOR_SERIAL" 10 2>&1)"; then
        die "Could not read brightness for $MONITOR_NAME: $output"
    fi

    parsed="$(
        printf '%s\n' "$output" |
            sed -nE 's/.*current value = *([0-9]+), max value = *([0-9]+).*/\1 \2/p'
    )"

    [[ -n "$parsed" ]] || die "Could not parse ddcutil brightness output."

    read -r CURRENT MAX <<< "$parsed"
    [[ "$MAX" =~ ^[0-9]+$ ]] && (( MAX > 0 )) ||
        die "Monitor reported an invalid maximum brightness."
}

set_brightness() {
    local value="$1" output

    if ! output="$(ddcutil setvcp --sn "$MONITOR_SERIAL" 10 "$value" 2>&1)"; then
        die "Could not set brightness for $MONITOR_NAME: $output"
    fi
}

percent() {
    local value="$1" max="$2"
    printf '%d' "$(( (value * 100 + max / 2) / max ))"
}

stop_inhibitor() {
    [[ -r "$PID_FILE" ]] || return 0

    local pid cmdline
    read -r pid < "$PID_FILE" || true

    if [[ "${pid:-}" =~ ^[0-9]+$ ]] && [[ -r "/proc/$pid/cmdline" ]]; then
        cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
        if [[ "$cmdline" == *systemd-inhibit* ]]; then
            kill "$pid" 2>/dev/null || true
        fi
    fi

    rm -f "$PID_FILE"
}

start_inhibitor() {
    command -v systemd-inhibit >/dev/null 2>&1 || {
        printf 'Warning: systemd-inhibit not found; sleep will not be blocked.\n' >&2
        return 0
    }

    if [[ -r "$PID_FILE" ]]; then
        local existing cmdline
        read -r existing < "$PID_FILE" || true
        if [[ "${existing:-}" =~ ^[0-9]+$ ]] &&
           [[ -r "/proc/$existing/cmdline" ]]; then
            cmdline="$(tr '\0' ' ' < "/proc/$existing/cmdline" 2>/dev/null || true)"
            [[ "$cmdline" == *systemd-inhibit* ]] && return 0
        fi
        rm -f "$PID_FILE"
    fi

    systemd-inhibit \
        --what=sleep \
        --mode=block \
        --who="Sunshine screen" \
        --why="Monitor dimmed for streaming" \
        sleep infinity >/dev/null 2>&1 &
    local pid=$!

    sleep 0.2
    if kill -0 "$pid" 2>/dev/null; then
        printf '%s\n' "$pid" > "$PID_FILE"
    else
        wait "$pid" 2>/dev/null || true
        printf 'Warning: could not start systemd-inhibit.\n' >&2
    fi
}

save_original_brightness() {
    local value="$1"
    local temp_file="$STATE_FILE.tmp.$$"

    printf '%s\n' "$value" > "$temp_file"
    mv -f "$temp_file" "$STATE_FILE"
}

case "${1:-}" in
    status)
        read_brightness
        target=$(( (MAX * DIM_PERCENT + 50) / 100 ))
        (( target < 1 )) && target=1

        if (( CURRENT == target )); then
            printf 'screen: dimmed\n'
        else
            printf 'screen: normal\n'
        fi
        printf 'monitor: %s\n' "$MONITOR_NAME"
        printf 'brightness: %s%%\n' "$(percent "$CURRENT" "$MAX")"
        ;;

    off)
        read_brightness
        target=$(( (MAX * DIM_PERCENT + 50) / 100 ))
        (( target < 1 )) && target=1

        if [[ -f "$STATE_FILE" ]]; then
            read -r saved < "$STATE_FILE" ||
                die "Could not read saved brightness state."
            [[ "$saved" =~ ^[0-9]+$ ]] ||
                die "Saved brightness state is invalid."
        else
            saved="$CURRENT"
            save_original_brightness "$saved"
        fi

        set_brightness "$target"
        start_inhibitor

        printf '%s dimmed to %s%% (was %s%%).\n' \
            "$MONITOR_NAME" "$DIM_PERCENT" "$(percent "$saved" "$MAX")"
        ;;

    on)
        if [[ -f "$STATE_FILE" ]]; then
            read -r saved < "$STATE_FILE" ||
                die "Could not read saved brightness state."
            [[ "$saved" =~ ^[0-9]+$ ]] ||
                die "Saved brightness state is invalid."

            set_brightness "$saved"
            read_brightness
            rm -f "$STATE_FILE"
            stop_inhibitor

            printf '%s brightness set to %s%%.\n' \
                "$MONITOR_NAME" "$(percent "$CURRENT" "$MAX")"
        else
            stop_inhibitor
            read_brightness
            printf '%s brightness is already %s%%.\n' \
                "$MONITOR_NAME" "$(percent "$CURRENT" "$MAX")"
        fi
        ;;

    *)
        printf 'Usage: %s {status|off|on}\n' "${0##*/}" >&2
        exit 2
        ;;
esac
