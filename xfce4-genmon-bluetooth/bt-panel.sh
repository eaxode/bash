#!/bin/bash

# ------------------------------------------------------------
# 📝 Zweck
# Dieses Skript zeigt Akkustand, Codec und Bitrate des aktuell
# verbundenen Bluetooth-Geräts im XFCE Genmon-Plugin an und öffnet
# per Linksklick das Menü (bt-menu.sh) zum Schalten/Verwalten des Adapters.
# Voraussetzungen:
#   - bt-panel.sh: bluez libglib2.0-bin pulseaudio-utils imagemagick
#   - bt-menu.sh: yad xdotool bluez libglib2.0-bin blueman
# ------------------------------------------------------------

ICON_ACTIVE="/usr/share/icons/elementary-xfce-dark/panel/16/bluetooth-active.png"
ICON_DISABLED="/usr/share/icons/elementary-xfce-dark/panel/16/bluetooth-disabled.png"
ICON_DISCONNECTED_COLOR="#808080"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ICON_DIR="${SCRIPT_DIR}/icons"
mkdir -p "$ICON_DIR"

# Statusdatei merkt sich, bis zu welchem Akkustand bereits gewarnt wurde (<10%).
STATEFILE="/tmp/bt_battery_warn_state"

mac_to_path() { echo "/org/bluez/hci0/dev_${1//:/_}"; }

ensure_colored_icon() {
    local name="$1"
    local fill="$2"
    local path="${ICON_DIR}/${name}.png"

    if [ ! -f "$path" ]; then
        if command -v convert >/dev/null 2>&1; then
            if ! convert "$ICON_ACTIVE" -alpha on -fill "$fill" -colorize 100% "$path"; then
                cp "$ICON_ACTIVE" "$path"
            fi
        else
            cp "$ICON_ACTIVE" "$path"
        fi
    fi

    echo "$path"
}

# --------------------------------------
# 🔍 Aktives Gerät ermitteln
# --------------------------------------
ACTIVE_DEVICE=""
ACTIVE_NAME=""
CONNECTED=$(bluetoothctl devices Connected 2>/dev/null)
if [ -n "$CONNECTED" ]; then
    ACTIVE_DEVICE=$(echo "$CONNECTED" | head -n1 | awk '{print $2}')
    ACTIVE_NAME=$(echo "$CONNECTED" | head -n1 | cut -d' ' -f3-)
fi
[ -z "$ACTIVE_NAME" ] && ACTIVE_NAME="Unbekanntes Gerät"

# Adapterzustand ermitteln, um zwischen "ausgeschaltet" und "nicht verbunden" unterscheiden zu können.
POWERED_STATE=""
ADAPTER_INFO=$(bluetoothctl show 2>/dev/null || true)
if grep -q "Powered:" <<<"$ADAPTER_INFO"; then
    POWERED_STATE=$(awk '/Powered:/ {print tolower($2)}' <<<"$ADAPTER_INFO")
elif grep -qi "no default controller available" <<<"$ADAPTER_INFO"; then
    POWERED_STATE="no"
fi

if [ -z "$ACTIVE_DEVICE" ]; then
    if [ "$POWERED_STATE" = "no" ]; then
        ICON_STATE="$ICON_DISABLED"
        TOOLTIP="Bluetooth deaktiviert"
    else
        ICON_STATE=$(ensure_colored_icon "disconnected" "$ICON_DISCONNECTED_COLOR")
        TOOLTIP="Kein Bluetooth-Gerät verbunden"
    fi
    echo "<img>${ICON_STATE}</img><tool>${TOOLTIP}</tool><click>${SCRIPT_DIR}/bt-menu.sh</click><click3>xfce4-panel --plugin-event=genmon:refresh:bool:true</click3>"
    exit 0
fi

# --------------------------------------
# 🔋 Akkustand auslesen
# --------------------------------------
DEVICE_PATH=$(mac_to_path "$ACTIVE_DEVICE")
PERCENT=$(gdbus call --system --dest org.bluez \
  --object-path "$DEVICE_PATH" \
  --method org.freedesktop.DBus.Properties.Get \
  org.bluez.Battery1 Percentage 2>/dev/null | awk -F'0x' '{print strtonum("0x"$2)}')

# --------------------------------------
# 🎧 Codec aus api.bluez5.codec lesen
# --------------------------------------
MAC_US="${ACTIVE_DEVICE//:/_}"
SINK_NAME="bluez_output.${MAC_US}.1"

CODEC=$(pactl list sinks 2>/dev/null | grep -A40 "Name: ${SINK_NAME}" | grep -oP '(?<=api.bluez5.codec = ")[^"]+')
[ -z "$CODEC" ] && CODEC="unbekannt"

# --------------------------------------
# 📊 Typische Bitraten je Codec
# --------------------------------------
case "$CODEC" in
    sbc_xq)  BITRATE="492 kbps" ;;
    sbc)     BITRATE="328 kbps" ;;
    aac)     BITRATE="256 kbps" ;;
    aptx)    BITRATE="352 kbps" ;;
    aptx_hd) BITRATE="576 kbps" ;;
    msbc)    BITRATE="64 kbps (HFP Wideband)" ;;
    cvsd)    BITRATE="64 kbps (HSP Narrowband)" ;;
    *)       BITRATE="unbekannt" ;;
esac

# --------------------------------------
# 🎨 Icon-Farbe nach Akkustand
# --------------------------------------
ICON="$ICON_ACTIVE"
NUMERIC_PERCENT=""
if [ -z "$PERCENT" ]; then
    PERCENT="?"
elif [[ "$PERCENT" =~ ^[0-9]+$ ]]; then
    NUMERIC_PERCENT="$PERCENT"
else
    PERCENT="?"
fi

if [ -n "$NUMERIC_PERCENT" ]; then
    if   [ "$NUMERIC_PERCENT" -le 10 ]; then
        ICON=$(ensure_colored_icon "10" "#FF0000")
    elif [ "$NUMERIC_PERCENT" -le 20 ]; then
        ICON=$(ensure_colored_icon "20" "#FF6600")
    elif [ "$NUMERIC_PERCENT" -le 30 ]; then
        ICON=$(ensure_colored_icon "30" "#FFCC00")
    elif [ "$NUMERIC_PERCENT" -le 40 ]; then
        ICON=$(ensure_colored_icon "40" "#99CC00")
    elif [ "$NUMERIC_PERCENT" -le 50 ]; then
        ICON=$(ensure_colored_icon "50" "#33CC33")
    elif [ "$NUMERIC_PERCENT" -le 60 ]; then
        ICON=$(ensure_colored_icon "60" "#00CC66")
    elif [ "$NUMERIC_PERCENT" -le 70 ]; then
        ICON=$(ensure_colored_icon "70" "#00CCCC")
    elif [ "$NUMERIC_PERCENT" -le 80 ]; then
        ICON=$(ensure_colored_icon "80" "#0099CC")
    elif [ "$NUMERIC_PERCENT" -le 100 ]; then
        ICON=$(ensure_colored_icon "90" "#0066CC")
    else
        ICON=$(ensure_colored_icon "100" "#FFFFFF")
    fi
fi

# --------------------------------------
# ⚠️ Akkuwarnung
# --------------------------------------
if [ -n "$NUMERIC_PERCENT" ]; then
    LAST_WARN_LEVEL=100
    [ -f "$STATEFILE" ] && LAST_WARN_LEVEL=$(cat "$STATEFILE")
    if [ "$NUMERIC_PERCENT" -lt 10 ] && [ "$NUMERIC_PERCENT" -lt "$LAST_WARN_LEVEL" ]; then
        notify-send "🔋 Akku niedrig" "$ACTIVE_NAME hat nur noch ${PERCENT}%!"
        echo "$NUMERIC_PERCENT" > "$STATEFILE"
    fi
    [ "$NUMERIC_PERCENT" -ge 10 ] && echo 100 > "$STATEFILE"
fi

# --------------------------------------
# 🪧 Tooltip + Klickaktionen
# --------------------------------------
echo -e "<img>${ICON}</img>\
<tool><b>Akkustand: ${PERCENT}%</b>\n<span size=\"smaller\">Gerät: ${ACTIVE_NAME}</span>\nCodec: ${CODEC}\nBitrate: ${BITRATE}</tool>\
<click>${SCRIPT_DIR}/bt-menu.sh</click>\
<click3>xfce4-panel --plugin-event=genmon:refresh:bool:true</click3>"
