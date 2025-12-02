#!/bin/bash

set -euo pipefail

LOCKFILE="/tmp/xfce4_genmon_bt.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    exit 0
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

read_gtk_setting() {
    local key="$1"
    local file="$HOME/.config/gtk-3.0/settings.ini"
    if [ -f "$file" ]; then
        awk -F'=' -v k="$key" '
            $1 == k {
                gsub(/^[ \t]+|[ \t]+$/, "", $2);
                print $2;
                exit;
            }
        ' "$file"
    fi
}

if command -v xfconf-query >/dev/null 2>&1; then
    CURRENT_THEME=$(xfconf-query -c xsettings -p /Net/ThemeName 2>/dev/null || true)
    CURRENT_ICON_THEME=$(xfconf-query -c xsettings -p /Net/IconThemeName 2>/dev/null || true)
    COLOR_SCHEME=$(xfconf-query -c xsettings -p /Net/ColorScheme 2>/dev/null || true)
fi

[ -z "${CURRENT_THEME:-}" ] && CURRENT_THEME=$(read_gtk_setting "gtk-theme-name")
[ -z "${CURRENT_ICON_THEME:-}" ] && CURRENT_ICON_THEME=$(read_gtk_setting "gtk-icon-theme-name")

YAD_ENV=()
MENU_WIDTH=240
MENU_HEIGHT=150
MENU_GEOMETRY="${MENU_WIDTH}x${MENU_HEIGHT}+0+0"

if [ -n "${CURRENT_THEME:-}" ]; then
    case "${COLOR_SCHEME:-}" in
        prefer-dark)
            if [[ "$CURRENT_THEME" != *":dark" && "$CURRENT_THEME" != *"-dark" && "$CURRENT_THEME" != *"Dark" ]]; then
                GTK_THEME_VALUE="${CURRENT_THEME}:dark"
            else
                GTK_THEME_VALUE="$CURRENT_THEME"
            fi
            ;;
        *)
            GTK_THEME_VALUE="$CURRENT_THEME"
            ;;
    esac
fi

[ -n "${GTK_THEME_VALUE:-}" ] && YAD_ENV+=("GTK_THEME=${GTK_THEME_VALUE}")
[ -n "${CURRENT_ICON_THEME:-}" ] && YAD_ENV+=("GTK_ICON_THEME=${CURRENT_ICON_THEME}")
YAD_ENV+=("GTK_USE_PORTAL=0")

refresh_panel() {
    xfce4-panel --plugin-event=genmon:refresh:bool:true >/dev/null 2>&1 || true
}

run_yad() {
    if [ "${#YAD_ENV[@]}" -gt 0 ]; then
        env "${YAD_ENV[@]}" yad "$@"
    else
        yad "$@"
    fi
}

escape_markup() {
    local text="$1"
    text=${text//&/&amp;}
    text=${text//</&lt;}
    text=${text//>/&gt;}
    echo "$text"
}

ensure_bluetoothctl() {
    if ! command -v bluetoothctl >/dev/null 2>&1; then
        notify-send "Bluetooth" "bluetoothctl wurde nicht gefunden."
        exit 1
    fi
}

ensure_xdotool() {
    if ! command -v xdotool >/dev/null 2>&1; then
        notify-send "Bluetooth" "xdotool wurde nicht gefunden."
        exit 1
    fi
}

mac_to_path() {
    local mac="$1"
    echo "/org/bluez/hci0/dev_${mac//:/_}"
}

read_adapter_state() {
    local info
    info=$(bluetoothctl show 2>/dev/null || true)
    if ! grep -q "Powered:" <<<"$info"; then
        notify-send "Bluetooth" "Kein Bluetooth-Adapter gefunden."
        exit 1
    fi
    POWERED=$(awk '/Powered:/ {print $2}' <<<"$info")
}

read_connected_device() {
    local connected
    connected=$(bluetoothctl devices Connected 2>/dev/null || true)
    if [ -n "$connected" ]; then
        ACTIVE_DEVICE=$(echo "$connected" | head -n1 | awk '{print $2}')
        ACTIVE_NAME=$(echo "$connected" | head -n1 | cut -d' ' -f3-)
    else
        ACTIVE_DEVICE=""
        ACTIVE_NAME=""
    fi
}

read_battery_percentage() {
    BATTERY_PERCENT=""
    if [ -z "${ACTIVE_DEVICE:-}" ]; then
        return
    fi
    if ! command -v gdbus >/dev/null 2>&1; then
        return
    fi

    local device_path raw value
    device_path=$(mac_to_path "$ACTIVE_DEVICE")
    raw=$(gdbus call --system --dest org.bluez \
        --object-path "$device_path" \
        --method org.freedesktop.DBus.Properties.Get \
        org.bluez.Battery1 Percentage 2>/dev/null || true)

    if [ -z "$raw" ]; then
        return
    fi

    value=$(awk -F'0x' 'NF>1 {print strtonum("0x"$2)}' <<<"$raw")
    if [ -z "$value" ]; then
        value=$(grep -oE '[0-9]+' <<<"$raw" | head -n1)
    fi

    if [[ "${value:-}" =~ ^[0-9]+$ ]]; then
        BATTERY_PERCENT="$value"
    fi
}

open_blueman_manager() {
    if command -v blueman-manager >/dev/null 2>&1; then
        (blueman-manager >/dev/null 2>&1 &)
    else
        notify-send "Bluetooth" "blueman-manager nicht gefunden."
    fi
}

open_blueman_adapters() {
    if command -v blueman-adapters >/dev/null 2>&1; then
        (blueman-adapters >/dev/null 2>&1 &)
    else
        notify-send "Bluetooth" "blueman-adapters nicht gefunden."
    fi
}

apply_power_state() {
    local desired="$1"
    local output=""

    if [ "$desired" = "on" ] && [ "$POWERED" != "yes" ]; then
        while read -r line; do
            output+="$line"$'\n'
        done < <(bluetoothctl power on 2>&1)
        if grep -Eqi "succeed|success" <<<"$output"; then
            notify-send "🔵 Bluetooth" "Adapter eingeschaltet."
        else
            notify-send "Bluetooth" "Einschalten fehlgeschlagen:\n${output}"
        fi
    elif [ "$desired" = "off" ] && [ "$POWERED" = "yes" ]; then
        while read -r line; do
            output+="$line"$'\n'
        done < <(bluetoothctl power off 2>&1)
        if grep -Eqi "succeed|success" <<<"$output"; then
            notify-send "⚪ Bluetooth" "Adapter ausgeschaltet."
        else
            notify-send "Bluetooth" "Ausschalten fehlgeschlagen:\n${output}"
        fi
    fi
}

calculate_menu_geometry() {
    local x y target_x target_y
    if eval "$(xdotool getmouselocation --shell 2>/dev/null)"; then
        x="${X:-0}"
        y="${Y:-0}"
    else
        x=0
        y=0
    fi

    target_x=$(( x - MENU_WIDTH ))
    if [ "$target_x" -lt 0 ]; then
        target_x=0
    fi

    target_y=$y
    if [ "$target_y" -lt 0 ]; then
        target_y=0
    fi

    MENU_GEOMETRY="${MENU_WIDTH}x${MENU_HEIGHT}+${target_x}+${target_y}"
}

ensure_bluetoothctl
ensure_xdotool

while true; do
    read_adapter_state
    read_connected_device
    read_battery_percentage

    if [ "$POWERED" = "yes" ]; then
        CHECKED="TRUE"
    else
        CHECKED="FALSE"
    fi

    if [ -n "$ACTIVE_NAME" ]; then
        STATUS_TEXT="Verbunden mit ${ACTIVE_NAME}"
        if [ -n "$BATTERY_PERCENT" ]; then
            STATUS_TEXT="${STATUS_TEXT} (${BATTERY_PERCENT}%)"
        fi
    else
        STATUS_TEXT="Kein Gerät verbunden"
    fi
    STATUS_TEXT=$(escape_markup "$STATUS_TEXT")

    calculate_menu_geometry

    OUTPUT=$(run_yad --form \
        --title="Bluetooth" \
        --window-icon=bluetooth \
        --on-top \
        --text="${STATUS_TEXT}" \
        --geometry="${MENU_GEOMETRY}" \
        --field="Bluetooth aktiv:CHK" "$CHECKED" \
        --field="Geräteverwaltung ...:BTN" "bash -lc 'blueman-manager >/dev/null 2>&1 &'" \
        --field="Adaptereinstellungen ...:BTN" "bash -lc 'blueman-adapters >/dev/null 2>&1 &'" \
        --separator="|" \
        --button="Übernehmen:0" \
        --button="Abbrechen:1" \
        2>/dev/null)
    EXIT_CODE=$?

    case "$EXIT_CODE" in
        0)
            DESIRED_STATE=$(cut -d'|' -f1 <<<"${OUTPUT:-FALSE}")
            if [ "${DESIRED_STATE}" = "TRUE" ]; then
                apply_power_state "on"
            else
                apply_power_state "off"
            fi
            break
            ;;
        1|252)
            exit 0
            ;;
        *)
            exit 0
            ;;
    esac
done

refresh_panel
