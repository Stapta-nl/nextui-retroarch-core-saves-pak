#!/usr/bin/env bats
# bats file_tags=device,menu
#
# Drives the pak's real menu (the real minui-list) on a real device with injected button
# presses, against a throw-away fixture SD tree. OPT IN: set MENU_TESTS=1, because it takes
# over the screen for a few seconds and kills NextUI's UI process, which NextUI's own
# launcher loop then restarts.
#
# How: the pak is started through NextUI's own hand-off (/tmp/next, then kill -9 of
# nextui.elf; never SIGTERM, which NextUI treats as "power off"), through a small wrapper
# that points the pak at the fixture. Buttons are written to the gamepad's evdev node
# (tests/helpers/pad.bash). The result is read from the fixture's files, not from the screen.
#
# Status: written from minui-psp's tests, NOT yet run on any device. Treat the first runs
# as calibration: UI_WAIT (seconds for the menu to appear) and KEY_GAP may need raising.
# Other platforms than tg5040 / tg5050 need PAD_NAME or PAD_DEVICE (see devices.env.example).

load '../helpers/common'
load '../helpers/pad'

kill_ui() { killall -9 nextui.elf 2>/dev/null; }

setup_file() {
    [ "${MENU_TESTS:-0}" = 1 ] || return 0
    SD="${SDCARD_PATH:-/mnt/SDCARD}"
    PLATFORM="$(pak_platform)"
    PAK="$(pak_src)"
    export SD PLATFORM PAK
    UI_WAIT="${UI_WAIT:-8}"
    export UI_WAIT
}

setup() {
    [ "${MENU_TESTS:-0}" = 1 ] || skip "menu tests are opt in: set MENU_TESTS=1 (see tests/devices.env.example)"
    [ "$(id -u)" = 0 ] || fail "run as root (needed for /dev/input)"
    [ -f /tmp/nextui_exec ] || skip "NextUI's launcher is not running (/tmp/nextui_exec missing)"
    pad_find || skip "no gamepad node: set PAD_NAME or PAD_DEVICE"

    FIX="${TEST_BASE:-$SD/.core-states-tests}/menu"
    rm -rf "$FIX"
    mkdir -p "$FIX/sd/Saves" "$FIX/sd/.userdata/shared" "$FIX/sd/.userdata/$PLATFORM/logs" \
        "$FIX/sd/.system/$PLATFORM/paks/Emus/GBA.pak"
    printf 'EMU_EXE=gpsp\n' >"$FIX/sd/.system/$PLATFORM/paks/Emus/GBA.pak/launch.sh"
    printf 'stateFormat=0\nsaveFormat=3\n' >"$FIX/sd/.userdata/shared/minuisettings.txt"
    FEATURES="$FIX/sd/.userdata/shared/$(pak_name)/features.conf"
    mkdir -p "$(dirname "$FEATURES")"
    printf 'core_states=on\n' >"$FEATURES"

    # The wrapper NextUI runs: the real pak, the fixture as its SD card.
    cat >"$FIX/run.sh" <<EOF
#!/bin/sh
SDCARD_PATH='$FIX/sd'
PLATFORM='$PLATFORM'
export SDCARD_PATH PLATFORM
exec sh '$PAK/launch.sh'
EOF
    chmod +x "$FIX/run.sh"
}

teardown() {
    rm -f /tmp/next
    if [ -n "${FIX:-}" ] && [ -d "$FIX" ]; then
        mkdir -p "$OUT_DIR/menu"
        cp -R "$FIX/sd/.userdata" "$OUT_DIR/menu/" 2>/dev/null || true
        [ "${KEEP:-0}" = 1 ] || rm -rf "$FIX"
    fi
}

# start_pak: hands the wrapper to NextUI's launcher loop and waits for the menu.
start_pak() {
    printf "'%s'\n" "$FIX/run.sh" >/tmp/next
    kill_ui
    sleep "$UI_WAIT"
}

# The number of Down presses (negative: Up) from the row the menu starts on to the row named
# $1, from the menu the pak itself renders for this fixture. Only selectable rows count: the
# cursor skips the status rows.
downs_to() {
    local row="$1" json
    json="$(PATH="$PAK/bin/$PLATFORM:$PATH" SDCARD_PATH="$FIX/sd" PLATFORM="$PLATFORM" CORE_SAVES_DIR="$PAK" CORE_SAVES_SOURCE_ONLY=1 \
        sh -c ". '$PAK/launch.sh' >/dev/null 2>&1; current_settings")" || return 1
    printf '%s' "$json" | "$PAK/bin/$PLATFORM/jq" -r --arg row "$row" '
        [.settings[] | select(.features.unselectable != true) | .name] as $n
        | ($n | index("Re-apply Core Save Mappings") // index("Convert to RetroArch Core Saves")
            // index("Revert to NextUI Saves") // 0) as $start
        | ($n | index($row)) as $target
        | if $target == null then "missing" else ($target - $start) end'
}

@test "menu: selecting the Core States row switches the setting off and on again" {
    local n
    n="$(downs_to '> Core States:')"
    [ "$n" != missing ] || fail "the menu has no '> Core States:' row"
    info "Core States row is $n Down presses from the start row"

    start_pak
    if [ "$n" -ge 0 ]; then press_n down "$n"; else press_n up $((-n)); fi
    press a
    sleep 2
    assert_grep "$FEATURES" '^core_states=off'

    press a # the same row is still selected
    sleep 2
    assert_grep "$FEATURES" '^core_states=on'

    press b # leave the pak; NextUI's launcher loop brings NextUI back
    sleep 3
}
