#!/bin/sh
# Core Saves through mountctl, with real bind mounts: moving a 0.6 install off
# its own boot hook, re-applying mappings with the tag folders mounted, boot,
# and reverting. Re-runs itself inside a private user+mount namespace
# (unshare -rm), so it needs no root and leaves the host alone.

set -u

if [ "${CORE_SAVES_TEST_NS:-0}" != 1 ]; then
	command -v unshare >/dev/null 2>&1 || { echo "SKIP: unshare is not available"; exit 0; }
	CORE_SAVES_TEST_NS=1 exec unshare -rm sh "$0" "$@"
fi

PAK_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/core-saves-mounts.XXXXXX")
TEST_ROOT=$(CDPATH= cd -P -- "$TEST_ROOT" && pwd -P)

PATH="$PAK_DIR/bin/desktop:$PATH"
SDCARD_PATH="$TEST_ROOT/sd"
PLATFORM=desktop
SYSTEM_PATH="$SDCARD_PATH/.system/$PLATFORM"
SHARED_USERDATA_PATH="$SDCARD_PATH/.userdata/shared"
USERDATA_PATH="$SDCARD_PATH/.userdata/$PLATFORM"
LOGS_PATH="$USERDATA_PATH/logs"
CORE_SAVES_DIR="$PAK_DIR"
CORE_SAVES_SOURCE_ONLY=1
MOUNTS_LOCK="$TEST_ROOT/mountctl.lock"
TMPDIR="$TEST_ROOT"
export PATH SDCARD_PATH PLATFORM SYSTEM_PATH SHARED_USERDATA_PATH USERDATA_PATH
export LOGS_PATH CORE_SAVES_DIR CORE_SAVES_SOURCE_ONLY MOUNTS_LOCK TMPDIR

cleanup() {
	awk -v root="$TEST_ROOT" 'substr($5, 1, length(root) + 1) == root "/" { print length($5) " " $5 }' \
		/proc/self/mountinfo | sort -rn | cut -d' ' -f2- | while IFS= read -r path; do
		umount "$path" 2>/dev/null || true
	done
	rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
	echo "FAIL: $*" >&2
	for log in "$LOGS_PATH/core-saves.txt" "$LOGS_PATH/mounts.txt"; do
		[ -f "$log" ] && { echo "--- $log" >&2; cat "$log" >&2; }
	done
	exit 1
}

assert_eq() {
	[ "$1" = "$2" ] || fail "expected [$2], got [$1]"
}

mount_count() {
	awk -v target="$1" '$5 == target { n++ } END { print n + 0 }' /proc/self/mountinfo
}

mounts_below_saves() {
	awk -v root="$SDCARD_PATH/Saves" 'substr($5, 1, length(root) + 1) == root "/" { print $5 }' \
		/proc/self/mountinfo | sort
}

write_emulator() {
	path="$SDCARD_PATH/.system/$PLATFORM/paks/Emus/$1.pak"
	mkdir -p "$path"
	printf 'EMU_EXE=%s\n' "$2" > "$path/launch.sh"
}

write_emulator GBA gpsp
mkdir -p "$SDCARD_PATH/Saves/Cores/gpSP" "$SDCARD_PATH/Saves/GBA" "$SHARED_USERDATA_PATH" "$LOGS_PATH"
printf 'saveFormat=3\n' > "$SHARED_USERDATA_PATH/minuisettings.txt"
echo advance > "$SDCARD_PATH/Saves/Cores/gpSP/Advance.srm"

. "$PAK_DIR/launch.sh"
show_progress() { :; }

# A 0.6 install: enabled, its own hook and helper, and the tag folder mounted
# by that helper at boot.
printf 'GBA|gpSP\n' > "$MOUNT_TABLE"
printf 'backup=\nold_format=3\n' > "$ENABLED_FILE"
mkdir -p "$(dirname "$LEGACY_HOOK_FILE")"
printf '#!/bin/sh\n' > "$LEGACY_HOOK_FILE"
printf '#!/bin/sh\n' > "$HOME_PATH/boot-mount.sh"
mount --bind "$CORES_PATH/gpSP" "$SAVES_PATH/GBA" || fail "could not fake the 0.6 boot mount"

# What main() does on launch.
ensure_mount_layer || fail "moving to mountctl: $MOUNT_ERROR"
run_mounts || fail "first apply: $MOUNT_ERROR"
[ -e "$LEGACY_HOOK_FILE" ] && fail "the 0.6 boot hook was left behind"
[ -e "$HOME_PATH/boot-mount.sh" ] && fail "the 0.6 boot helper was left behind"
assert_eq "$(mount_count "$SAVES_PATH/GBA")" "1"
assert_eq "$(mount_status)" "1/1 mounted"
assert_eq "$(cat "$SAVES_PATH/GBA/Advance.srm")" "advance"

# Re-applying after a new emulator appears: the live tag mounts come down for
# the migration and everything is mounted again, once.
write_emulator GB gambatte
mkdir -p "$SAVES_PATH/GB"
echo mono > "$SAVES_PATH/GB/Mono.gb.sav"
enable_core_saves || fail "re-apply: $ACTION_RESULT"
assert_eq "$(mount_status)" "2/2 mounted"
assert_eq "$(mount_count "$SAVES_PATH/GBA")" "1"
assert_eq "$(mount_count "$SAVES_PATH/GB")" "1"
assert_eq "$(cat "$SAVES_PATH/GB/Mono.gb.sav")" "mono"
[ -f "$CORES_PATH/Gambatte/Mono.gb.sav" ] || fail "the GB save did not move into Cores"

# Boot: nothing mounted yet, then mountctl's hook.
sh "$MOUNTS_HOME/mountctl.sh" down || fail "down failed"
assert_eq "$(mounts_below_saves)" ""
sh "$MOUNTS_HOOK" || fail "boot hook failed"
assert_eq "$(mount_status)" "2/2 mounted"

# A tag folder that gained files while unmounted is not hidden.
sh "$MOUNTS_HOME/mountctl.sh" down || fail "down failed"
echo stray > "$SAVES_PATH/GBA/stray.sav"
sh "$MOUNTS_HOOK" >/dev/null && fail "boot mounted over a folder with files in it"
assert_eq "$(mount_count "$SAVES_PATH/GBA")" "0"
[ -f "$SAVES_PATH/GBA/stray.sav" ] || fail "stray save disappeared"
rm "$SAVES_PATH/GBA/stray.sav"
run_mounts || fail "remount: $MOUNT_ERROR"

# Reverting unmounts the tags, puts the saves back in place and removes the
# layer, and with it mountctl, since no other pak has a layer here.
restore_to_legacy current || fail "revert: $ACTION_RESULT"
assert_eq "$(mounts_below_saves)" ""
assert_eq "$(cat "$SAVES_PATH/GBA/Advance.srm")" "advance"
assert_eq "$(cat "$SAVES_PATH/GB/Mono.gb.sav")" "mono"
[ -e "$MOUNT_LAYER_FILE" ] && fail "layer left installed after revert"
[ -e "$MOUNTS_HOOK" ] && fail "mountctl boot hook left behind"
[ -e "$MOUNTS_HOME/mountctl.sh" ] && fail "mountctl left behind"

echo "PASS: Core Saves with real mounts"
# --- Core States, with real mounts -------------------------------------------
# Both layers installed together: mountctl checks their scopes against each
# other, and layer 20 reads from inside the shared data layer 30 mounts into.
STATE_TARGET="$SHARED_USERDATA_PATH/GBA-gpsp"
printf 'stateFormat=0\n' >> "$SHARED_USERDATA_PATH/minuisettings.txt"
mkdir -p "$STATE_TARGET"
echo slot0 > "$STATE_TARGET/Advance.gba.st0"
echo auto > "$STATE_TARGET/Advance.gba.st9"
unset -f run_mounts run_states_mounts 2>/dev/null || :
. "$PAK_DIR/bin/mounts.sh" 2>/dev/null || :
. "$PAK_DIR/bin/states.sh"

enable_core_saves || fail "saves for the states test: $ACTION_RESULT"
enable_core_states || fail "enable states: $ACTION_RESULT"
assert_eq "$(mount_count "$STATE_TARGET")" "1"
assert_eq "$(mount_count "$SAVES_PATH/GBA")" "1"
assert_eq "$(states_mount_status)" "2/2 mounted"
# What NextUI sees through the mount is the RetroArch-named file in the tree.
assert_eq "$(cat "$STATE_TARGET/Advance.state")" "slot0"
assert_eq "$(cat "$STATE_TARGET/Advance.state.auto")" "auto"
assert_eq "$(cat "$SDCARD_PATH/States/Cores/gpSP/Advance.state")" "slot0"
# A state written through the mount lands in the synced tree.
echo new > "$STATE_TARGET/Advance.state2"
assert_eq "$(cat "$SDCARD_PATH/States/Cores/gpSP/Advance.state2")" "new"
assert_eq "$(get_state_format)" "3"
[ -f "$MOUNTS_HOME/layers.d/20-core-saves.sh" ] && [ -f "$MOUNTS_HOME/layers.d/30-core-states.sh" ] ||
	fail "both layers should be installed"

# Boot brings both back, and re-applying is stable.
sh "$MOUNTS_HOME/mountctl.sh" down || fail "down failed"
assert_eq "$(mount_count "$STATE_TARGET")" "0"
sh "$MOUNTS_HOOK" || fail "boot hook failed"
assert_eq "$(mount_count "$STATE_TARGET")" "1"
assert_eq "$(mount_count "$SAVES_PATH/GBA")" "1"
sh "$MOUNTS_HOME/mountctl.sh" apply || fail "re-apply failed"
assert_eq "$(mount_count "$STATE_TARGET")" "1"

# Taking only the states layer down leaves the save mounts alone.
sh "$MOUNTS_HOME/mountctl.sh" down 30-core-states || fail "down 30 failed"
assert_eq "$(mount_count "$STATE_TARGET")" "0"
assert_eq "$(mount_count "$SAVES_PATH/GBA")" "1"

# A states folder that gained files while unmounted is not hidden.
echo stray > "$STATE_TARGET/stray.state"
sh "$MOUNTS_HOOK" >/dev/null && fail "boot mounted over a states folder with files in it"
assert_eq "$(mount_count "$STATE_TARGET")" "0"
[ -f "$STATE_TARGET/stray.state" ] || fail "stray state disappeared"
rm "$STATE_TARGET/stray.state"
sh "$MOUNTS_HOOK" || fail "remount failed"

# Enabling again with everything mounted is a no-op for the states.
enable_core_states || fail "enable again: $ACTION_RESULT"
assert_eq "$(mount_count "$STATE_TARGET")" "1"
assert_eq "$(states_marker_value old_format)" "0"
assert_eq "$(find "$SDCARD_PATH/States/Cores/gpSP" -type f | wc -l | tr -d ' ')" "3"

# Restoring the MinUI format needs the ROM, which supplies the extension back.
mkdir -p "$ROMS_PATH/Game Boy Advance (GBA)"
: > "$ROMS_PATH/Game Boy Advance (GBA)/Advance.gba"

# Disabling unmounts, copies the states back and removes only its own layer.
disable_core_states restore || fail "disable states: $ACTION_RESULT"
assert_eq "$(mount_count "$STATE_TARGET")" "0"
assert_eq "$(mount_count "$SAVES_PATH/GBA")" "1"
assert_eq "$(cat "$STATE_TARGET/Advance.gba.st0")" "slot0"
assert_eq "$(cat "$STATE_TARGET/Advance.gba.st9")" "auto"
[ -e "$MOUNTS_HOME/layers.d/30-core-states.sh" ] && fail "states layer left installed"
[ -f "$MOUNTS_HOME/layers.d/20-core-saves.sh" ] || fail "disabling states removed the saves layer"
assert_eq "$(get_state_format)" "0"

# Reverting the saves now removes the last layer and mountctl with it.
restore_to_legacy current || fail "final revert: $ACTION_RESULT"
[ -e "$MOUNTS_HOME/mountctl.sh" ] && fail "mountctl left behind"

echo "PASS: Core States with real mounts"
