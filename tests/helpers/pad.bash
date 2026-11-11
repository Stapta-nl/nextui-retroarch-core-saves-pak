# shellcheck shell=bash
# Button injection for the on-device menu test: writes evdev events to the device's gamepad
# input node, the way minui-psp's end-to-end tests do.
#
# Which node and which codes are platform settings, not facts this repository can verify
# everywhere. Defaults are the TrimUI pad (tg5040, tg5050) as used by minui-psp's tests;
# for other platforms set PAD_NAME (the "Name=" in /proc/bus/input/devices) or PAD_DEVICE
# (/dev/input/eventN) and, when the codes differ, PAD_A / PAD_B / PAD_UP / PAD_DOWN as
# "type:code:value" (see tests/devices.env.example).

# 24-byte evdev events: 16 zero timestamp bytes, type, code, value.
_octal_byte() { printf '\\%03o' $(($1 & 255)); }

_pad_event() { # <type> <code> <value>
    local v=$(($3 & 4294967295))
    # shellcheck disable=SC2059 # the format is built from octal escapes on purpose
    printf "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0$(_octal_byte "$1")$(_octal_byte $(($1 >> 8)))$(_octal_byte "$2")$(_octal_byte $(($2 >> 8)))$(_octal_byte "$v")$(_octal_byte $((v >> 8)))$(_octal_byte $((v >> 16)))$(_octal_byte $((v >> 24)))" >"$PAD"
}

# pad_find: sets PAD to the input node, or returns 1 with a message.
pad_find() {
    if [ -n "${PAD_DEVICE:-}" ]; then
        PAD="$PAD_DEVICE"
    else
        local name="${PAD_NAME:-TRIMUI Player1}"
        PAD="$(awk -v n="$name" '$0 ~ "^N: Name=\"" n "\"" {f=1} f && /^H: Handlers=/ {for(i=1;i<=NF;i++) if($i ~ /^event/){print "/dev/input/" $i; exit}}' /proc/bus/input/devices)"
    fi
    [ -c "$PAD" ] || {
        echo "no gamepad input node found (PAD_NAME='${PAD_NAME:-TRIMUI Player1}', PAD_DEVICE='${PAD_DEVICE:-}')" >&2
        return 1
    }
    # Defaults: the TrimUI pad. Codes as type:code:value (value while pressed).
    : "${PAD_A:=1:305:1}"
    : "${PAD_B:=1:304:1}"
    : "${PAD_UP:=3:17:-1}"
    : "${PAD_DOWN:=3:17:1}"
}

# press <a|b|up|down>: a short tap, short enough that the UI's key repeat moves only once.
press() {
    local spec type code val
    case "$1" in
    a) spec="$PAD_A" ;;
    b) spec="$PAD_B" ;;
    up) spec="$PAD_UP" ;;
    down) spec="$PAD_DOWN" ;;
    *)
        echo "unknown button: $1" >&2
        return 1
        ;;
    esac
    IFS=: read -r type code val <<<"$spec"
    _pad_event "$type" "$code" "$val"
    _pad_event 0 0 0
    sleep 0.05
    _pad_event "$type" "$code" 0
    _pad_event 0 0 0
    sleep "${KEY_GAP:-0.5}"
}

press_n() { # press_n <button> <count>
    local i
    for ((i = 0; i < $2; i++)); do press "$1"; done
}
