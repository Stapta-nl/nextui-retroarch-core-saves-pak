#!/usr/bin/env bats
# bats file_tags=device
#
# Runs on a real device (make test-device-<platform>), against the pak as installed in
# Tools/<platform>/<name>.pak, never against the user's real library:
#
#   * every test works on a throw-away fixture SD tree under $TEST_BASE (default
#     $SDCARD_PATH/.core-states-tests, on the SD card so it is a real filesystem), and
#   * the real states, saves and settings are only ever READ (the survey test).
#
# The three sh suites of bin/tests/ run here on the device's own BusyBox sh with the
# platform's own jq and save-rzip, and with REAL bind mounts: that is what finds
# differences in awk, sed, find, mount and the kernel, which no host run can.
#
# The sh suites are in the test bundle (bin/tests is not part of a release); they test the
# installed pak through CORE_SAVES_TEST_PAK.
#
# Environment: SDCARD_PATH (/mnt/SDCARD), PLATFORM, PAK_NAME and SRC_PAK (set by the
# runner), TEST_BASE, KEEP=1 (keep the fixtures), see tests/devices.env.example.

load '../helpers/common'

setup_file() {
    SD="${SDCARD_PATH:-/mnt/SDCARD}"
    PLATFORM="$(pak_platform)"
    PAK="$(pak_src)"
    TEST_BASE="${TEST_BASE:-$SD/.core-states-tests}"
    export SD PLATFORM PAK TEST_BASE
    mkdir -p "$OUT_DIR"
    [ "$(id -u)" = 0 ] || fail "run as root (real bind mounts need it)"
    [ -d "$SD" ] || fail "no SD card at $SD (set SDCARD_PATH)"
    [ -d "$PAK" ] || fail "the pak is not installed at $PAK"
    rm -rf "$TEST_BASE"
    mkdir -p "$TEST_BASE"
}

teardown_file() {
    # Fixtures kept by a failed suite go into the debug bundle, then everything is removed.
    if [ -d "$TEST_BASE" ]; then
        mkdir -p "$OUT_DIR/fixtures"
        cp -R "$TEST_BASE/." "$OUT_DIR/fixtures/" 2>/dev/null || true
        # unmount anything a failed run left below the fixtures, deepest first
        mounts_under "$TEST_BASE" | awk '{ print length($0) " " $0 }' | sort -rn | cut -d' ' -f2- |
            while IFS= read -r m; do umount "$m" 2>/dev/null || true; done
        [ "${KEEP:-0}" = 1 ] || rm -rf "$TEST_BASE"
    fi
}

# run_device_suite <script>: one of bin/tests/*.sh against the installed pak, with this
# platform's binaries and real mounts.
run_device_suite() {
    local script="$1" rc=0
    CORE_SAVES_TEST_PAK="$PAK" \
        CORE_SAVES_TEST_PLATFORM="$PLATFORM" \
        CORE_SAVES_TEST_TOOLS="$PAK/bin/$PLATFORM" \
        CORE_SAVES_TEST_BASE="$TEST_BASE" \
        CORE_SAVES_TEST_REAL_MOUNTS=1 \
        CORE_SAVES_TEST_KEEP=1 \
        sh "$REPO_DIR/bin/tests/$script" >"$OUT_DIR/device-$script.log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "$script failed with status $rc; the last 40 lines:" >&2
        tail -n 40 "$OUT_DIR/device-$script.log" >&2
    fi
    return "$rc"
}

@test "the pak is installed where NextUI looks for it, with this platform's files" {
    [ -f "$PAK/launch.sh" ]
    [ -f "$PAK/pak.json" ]
    [ -f "$PAK/settings.json" ]
    [ -d "$PAK/bin/$PLATFORM" ]
    "$PAK/bin/$PLATFORM/jq" -e --arg p "$PLATFORM" '.platforms | index($p)' "$PAK/pak.json" >/dev/null
    info "pak version $("$PAK/bin/$PLATFORM/jq" -r .version "$PAK/pak.json")"
}

@test "the platform's binaries are executable and have an ELF header" {
    local b
    for b in jq minui-list minui-presenter save-rzip; do
        [ -x "$PAK/bin/$PLATFORM/$b" ] || fail "$b is not executable"
        [ "$(head -c 4 "$PAK/bin/$PLATFORM/$b" | od -An -c | tr -d ' ')" = '177ELF' ] || fail "$b is not an ELF binary"
    done
}

@test "jq runs on this device" {
    run "$PAK/bin/$PLATFORM/jq" --version
    assert_success
    run sh -c "echo '{\"a\":[1,2]}' | '$PAK/bin/$PLATFORM/jq' -c '.a | map(. + 1)'"
    assert_output "[2,3]"
}

@test "the installed binaries match bin/SHA256SUMS" {
    command -v sha256sum >/dev/null 2>&1 || skip "sha256sum is not on the device"
    [ -f "$PAK/bin/SHA256SUMS" ] || skip "no bin/SHA256SUMS in the installed pak"
    cd "$PAK"
    grep " bin/$PLATFORM/" bin/SHA256SUMS >"$BATS_TEST_TMPDIR/sums"
    [ -s "$BATS_TEST_TMPDIR/sums" ] || skip "no checksums for $PLATFORM"
    run sha256sum -c "$BATS_TEST_TMPDIR/sums"
    assert_success
}

@test "Core Saves suite on the device (BusyBox sh, this platform's jq and save-rzip)" {
    run_device_suite test-core-saves.sh
    assert_grep "$OUT_DIR/device-test-core-saves.sh.log" "RetroArch Core Saves tests passed"
}

@test "Core States suite on the device" {
    run_device_suite test-core-states.sh
    assert_grep "$OUT_DIR/device-test-core-states.sh.log" "RetroArch Core States tests passed"
}

@test "Core Saves and Core States with real bind mounts on the device" {
    run_device_suite test-core-saves-mounts.sh
    assert_grep "$OUT_DIR/device-test-core-saves-mounts.sh.log" "PASS: Core Saves with real mounts"
    assert_grep "$OUT_DIR/device-test-core-saves-mounts.sh.log" "PASS: Core States with real mounts"
}

@test "the suites left nothing mounted and no fixtures behind" {
    run mounts_under "$TEST_BASE"
    assert_output ""
    [ -z "$(find "$TEST_BASE" -mindepth 1 -maxdepth 1 -print -quit)" ] || fail "fixtures left in $TEST_BASE"
}

# Read-only look at the real setup, for the debug bundle and as a sanity check: nothing
# here changes anything.
@test "survey: the real NextUI settings and Core States state (read only)" {
    local settings="$SD/.userdata/shared/minuisettings.txt"
    if [ -f "$settings" ]; then
        info "minuisettings: $(grep -E '^(stateFormat|saveFormat)=' "$settings" | tr '\n' ' ')"
    else
        info "no $settings (NextUI settings not written yet)"
    fi
    local home="$SD/.userdata/shared/$(pak_name)"
    if [ -f "$home/enabled" ]; then
        info "Core Saves is enabled on this device"
        [ -f "$home/features.conf" ] && info "features: $(tr '\n' ' ' <"$home/features.conf")"
    else
        info "Core Saves is not enabled on this device"
    fi
    if [ -d "$SD/States/Cores" ]; then
        info "States/Cores folders: $(find "$SD/States/Cores" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
    fi
    run mounts_under "$SD/Saves"
    info "mounts below /Saves: $(printf '%s\n' "$output" | grep -c . || true)"
}
