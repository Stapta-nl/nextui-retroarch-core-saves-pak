#!/bin/sh
# Core States, host-side: name mapping, the format setting, the shared enable and
# revert transaction, recovery, backups and the setting. Real bind mounts are
# covered by test-core-saves-mounts.sh.

set -eu

PAK_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TEST_ROOT=${TMPDIR:-/tmp}/core-states-tests.$$
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM
mkdir -p "$TEST_ROOT"
TEST_ROOT=$(CDPATH= cd -P -- "$TEST_ROOT" && pwd -P)

PATH="$PAK_DIR/bin/desktop:$PATH"
export PATH

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

assert_eq() {
	[ "$1" = "$2" ] || fail "expected [$2], got [$1]"
}

assert_file() {
	[ -f "$1" ] || fail "missing file: $1"
}

assert_absent() {
	[ ! -e "$1" ] || fail "expected absent: $1"
}

assert_empty_dir() {
	[ -d "$1" ] || fail "missing directory: $1"
	[ -z "$(find "$1" -mindepth 1 -print -quit)" ] || fail "expected empty: $1"
}

assert_contains() {
	grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"
}

assert_content() {
	assert_file "$1"
	[ "$(cat "$1")" = "$2" ] || fail "$1 holds '$(cat "$1")', expected '$2'"
}

command -v jq >/dev/null 2>&1 || fail "missing bin/desktop/jq"

write_emulator() {
	path="$1/.system/$PLATFORM/paks/Emus/$2.pak"
	mkdir -p "$path"
	printf 'EMU_EXE=%s\n' "$3" > "$path/launch.sh"
}

load_fixture() {
	name="$1"
	SDCARD_PATH="$TEST_ROOT/$name/sd"
	PLATFORM=desktop
	SYSTEM_PATH="$SDCARD_PATH/.system/$PLATFORM"
	SHARED_USERDATA_PATH="$SDCARD_PATH/.userdata/shared"
	USERDATA_PATH="$SDCARD_PATH/.userdata/$PLATFORM"
	LOGS_PATH="$USERDATA_PATH/logs"
	CORE_SAVES_DIR="$PAK_DIR"
	CORE_SAVES_SOURCE_ONLY=1
	MOUNTS_LOCK="$TEST_ROOT/$name/mountctl.lock"
	TMPDIR="$TEST_ROOT/$name"
	export SDCARD_PATH PLATFORM SYSTEM_PATH SHARED_USERDATA_PATH USERDATA_PATH
	export LOGS_PATH CORE_SAVES_DIR CORE_SAVES_SOURCE_ONLY MOUNTS_LOCK TMPDIR

	mkdir -p "$SDCARD_PATH/Saves" "$SHARED_USERDATA_PATH"
	write_emulator "$SDCARD_PATH" GBA gpsp
	write_emulator "$SDCARD_PATH" GB gambatte
	write_emulator "$SDCARD_PATH" GBC gambatte

	# shellcheck source=../../launch.sh
	. "$CORE_SAVES_DIR/launch.sh"
	show_progress() { :; }
	run_mounts() { :; }
	printf 'stateFormat=0\nsaveFormat=3\notherSetting=1\n' > "$SETTINGS_PATH"
	printf 'core_states=on\n' > "$FEATURES_FILE"
}

# Writes a state file whose content names it, so a mix-up is visible.
put() {
	mkdir -p "$(dirname "$1")"
	printf '%s' "${2:-$(basename "$1")}" > "$1"
}

# What the menu's revert does about the state format.
revert() {
	RESTORE_STATE_FORMAT="${1:-keep}"
	restore_to_legacy current
}

test_state_name_mapping() (
	load_fixture names

	# NextUI's formats to RetroArch's, one per slot role.
	assert_eq "$(state_to_retroarch 'Game.gba.st0')" "Game.state"
	assert_eq "$(state_to_retroarch 'Game.gba.st1')" "Game.state1"
	assert_eq "$(state_to_retroarch 'Game.gba.st8')" "Game.state8"
	assert_eq "$(state_to_retroarch 'Game.gba.st9')" "Game.state.auto"
	assert_eq "$(state_to_retroarch 'Game.state.0')" "Game.state"
	assert_eq "$(state_to_retroarch 'Game.state.7')" "Game.state7"
	assert_eq "$(state_to_retroarch 'Game.state.auto')" "Game.state.auto"
	assert_eq "$(state_to_retroarch 'Game.state')" "Game.state"
	assert_eq "$(state_to_retroarch 'Game.state3')" "Game.state3"
	state_to_retroarch 'Game.srm' >/dev/null && fail "a save was taken for a state"
	state_to_retroarch 'Game.gba.png' >/dev/null && fail "a picture was taken for a state"

	# MinArch drops an extension of two to four characters, no more, no less.
	assert_eq "$(state_stem 'Game.gba')" "Game"
	assert_eq "$(state_stem 'Game.nes')" "Game"
	assert_eq "$(state_stem 'Dr. Mario.gb')" "Dr. Mario"
	assert_eq "$(state_stem 'Game.z')" "Game.z"
	assert_eq "$(state_stem 'Game.abcde')" "Game.abcde"
	assert_eq "$(state_stem 'NoExtension')" "NoExtension"
	assert_eq "$(state_to_retroarch 'Dr. Mario.gb.st2')" "Dr. Mario.state2"

	# And back, for every format.
	assert_eq "$(state_from_retroarch 'Game.state' 3)" "Game.state"
	assert_eq "$(state_from_retroarch 'Game.state5' 4)" "Game.state5"
	assert_eq "$(state_from_retroarch 'Game.state' 1)" "Game.state.0"
	assert_eq "$(state_from_retroarch 'Game.state5' 2)" "Game.state.5"
	assert_eq "$(state_from_retroarch 'Game.state.auto' 1)" "Game.state.auto"
	assert_eq "$(state_from_retroarch 'Game.state' 0 'Game.gba')" "Game.gba.st0"
	assert_eq "$(state_from_retroarch 'Game.state8' 0 'Game.gba')" "Game.gba.st8"
	assert_eq "$(state_from_retroarch 'Game.state.auto' 0 'Game.gba')" "Game.gba.st9"
	state_from_retroarch 'Game.state' 0 >/dev/null && fail "MinUI name made without a ROM"
	state_from_retroarch 'Game.srm' 3 >/dev/null && fail "a save was renamed as a state"

	# A thumbnail follows its state.
	state_split_sidecar 'Game.state.auto.png'
	assert_eq "$STATE_BASE|$STATE_SIDE" "Game.state.auto|.png"
	state_split_sidecar 'Game.state'
	assert_eq "$STATE_BASE|$STATE_SIDE" "Game.state|"

	# Every extradot name round-trips through RetroArch's names unchanged.
	for name in Game.state.0 Game.state.3 Game.state.auto; do
		ra=$(state_to_retroarch "$name")
		back=$(state_from_retroarch "$ra" 1)
		[ "$name" = "$back" ] || fail "$name did not round-trip: $back"
	done
)

test_state_format_record_and_restore() (
	load_fixture format
	assert_eq "$(get_state_format)" "0"
	set_state_format 3
	assert_eq "$(get_state_format)" "3"
	assert_contains "$SETTINGS_PATH" "otherSetting=1"
	assert_contains "$SETTINGS_PATH" "saveFormat=3"
	assert_eq "$(get_save_format)" "3"

	rm "$SETTINGS_PATH"
	assert_eq "$(get_state_format)" "0"
	set_state_format 4
	assert_eq "$(get_state_format)" "4"

	printf 'volume=5\n' > "$SETTINGS_PATH"
	set_state_format 3
	assert_contains "$SETTINGS_PATH" "volume=5"
	assert_eq "$(get_state_format)" "3"
	assert_eq "$(state_format_name 3)" "RetroArch compressed (.state)"
)

test_the_setting_is_on_by_default_and_persists() (
	load_fixture setting
	rm -f "$FEATURES_FILE"
	assert_eq "$(core_states_setting)" "on"
	set_core_states_setting off
	assert_eq "$(core_states_setting)" "off"
	set_core_states_setting on
	assert_eq "$(core_states_setting)" "on"
	assert_eq "$(grep -c '^core_states=' "$FEATURES_FILE")" "1"
	core_states_wanted || fail "an on setting was not wanted"
	set_core_states_setting off
	core_states_wanted && fail "an off setting was wanted"
	:
)

test_states_table_uses_emu_exe_for_the_folder() (
	load_fixture discover
	discover_mappings "$TEST_ROOT/saves-table" quiet || fail "discovery failed"
	derive_states_table "$TEST_ROOT/saves-table" "$TEST_ROOT/table" quiet || fail "derivation failed"
	printf 'GB|gambatte|Gambatte\nGBA|gpsp|gpSP\nGBC|gambatte|Gambatte\n' > "$TEST_ROOT/expected"
	cmp "$TEST_ROOT/expected" "$TEST_ROOT/table" || fail "unexpected states table: $(cat "$TEST_ROOT/table")"

	# An override has no EMU_EXE to name the folder after, so it is reported and
	# left out rather than guessed.
	mkdir -p "$SYSTEM_PATH/paks/Emus/ZZZ.pak"
	printf '#!/bin/sh\n' > "$SYSTEM_PATH/paks/Emus/ZZZ.pak/launch.sh"
	MAPPING_CONF="$TEST_ROOT/mapping.conf"
	printf 'ZZZ=Custom\n' > "$MAPPING_CONF"
	start_report test
	discover_mappings "$TEST_ROOT/saves-table2" quiet || fail "discovery with an override failed"
	grep -q '^ZZZ|Custom' "$TEST_ROOT/saves-table2" || fail "the override was not mapped"
	derive_states_table "$TEST_ROOT/saves-table2" "$TEST_ROOT/table2" || fail "derivation with an override failed"
	grep -q '^ZZZ|' "$TEST_ROOT/table2" && fail "a tag without EMU_EXE was given a states folder"
	assert_contains "$REPORT_FILE" "ZZZ"
)

setup_gb_states() {
	put "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" slot0
	put "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st3" slot3
	put "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st9" auto
	put "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st9.png" autopng
	put "$SHARED_USERDATA_PATH/GBA-gpsp/Other.gba.st1" gba1
	put "$SHARED_USERDATA_PATH/GBA-gpsp/notes.txt" notes
}

test_enable_moves_saves_and_states_in_one_transaction() (
	load_fixture enable
	setup_gb_states
	printf 'saveFormat=0\nstateFormat=0\notherSetting=1\n' > "$SETTINGS_PATH"
	put "$SDCARD_PATH/Saves/GBA/Other.gba.sav" save

	enable_core_saves || fail "enable failed: $ACTION_RESULT"
	assert_file "$ENABLED_FILE"
	assert_eq "$(enabled_value states)" "1"
	assert_eq "$(get_state_format)" "3"
	assert_eq "$(get_save_format)" "3"
	assert_eq "$(enabled_value old_state_format)" "0"

	# Saves and states both landed in their own trees.
	assert_content "$CORES_PATH/gpSP/Other.srm" save
	assert_content "$STATES_CORES/Gambatte/Game.state" slot0
	assert_content "$STATES_CORES/Gambatte/Game.state3" slot3
	assert_content "$STATES_CORES/Gambatte/Game.state.auto" auto
	assert_content "$STATES_CORES/Gambatte/Game.state.auto.png" autopng
	assert_content "$STATES_CORES/gpSP/Other.state1" gba1
	# Not a state name: still carried over, since the folder is about to be hidden.
	assert_content "$STATES_CORES/gpSP/notes.txt" notes
	assert_absent "$STATES_CORES/Gambatte/Game.gb.st0"
	# A save never ends up in the states tree, nor a state in the saves tree.
	find "$CORES_PATH" -name '*.state*' | grep -q . && fail "a state ended up in /Saves/Cores"
	find "$STATES_CORES" -name '*.srm' | grep -q . && fail "a save ended up in /States/Cores"

	# The NextUI folders were emptied for their mounts.
	assert_empty_dir "$SHARED_USERDATA_PATH/GB-gambatte"
	assert_empty_dir "$SHARED_USERDATA_PATH/GBA-gpsp"
	assert_contains "$STATES_TABLE" "GB|gambatte|Gambatte"
	assert_contains "$STATES_TABLE" "GBC|gambatte|Gambatte"
	assert_file "$MOUNT_LAYER_FILE"

	# One backup holds both, with the settings as they were.
	backup=$(enabled_value backup)
	assert_content "$backup/Saves/GBA/Other.gba.sav" save
	assert_content "$backup/States/GB-gambatte/Game.gb.st0" slot0
	assert_content "$backup/States/GB-gambatte/Game.gb.st9.png" autopng
	assert_contains "$backup/minuisettings.txt" "stateFormat=0"
	assert_eq "$(enabled_value states_backup)" "$backup"

	assert_contains "$REPORT_FILE" "CONVERTED"
	assert_contains "$REPORT_FILE" "SKIPPED"
	assert_contains "$REPORT_FILE" "Issues requiring attention: 0"
	assert_absent "$OPERATION_JOURNAL"
	assert_absent "$OPERATION_STATE"
	case "$ACTION_RESULT" in *"/States/Cores"*) ;; *) fail "the result did not mention states: $ACTION_RESULT" ;; esac
)

test_every_input_format_lands_on_retroarch_names() (
	for fmt in 1 2 3 4; do
		load_fixture "fmt$fmt"
		printf 'saveFormat=3\nstateFormat=%s\n' "$fmt" > "$SETTINGS_PATH"
		if [ "$fmt" -le 2 ]; then
			put "$SHARED_USERDATA_PATH/GB-gambatte/Game.state.0" z
			put "$SHARED_USERDATA_PATH/GB-gambatte/Game.state.4" four
			put "$SHARED_USERDATA_PATH/GB-gambatte/Game.state.auto" auto
		else
			put "$SHARED_USERDATA_PATH/GB-gambatte/Game.state" z
			put "$SHARED_USERDATA_PATH/GB-gambatte/Game.state4" four
			put "$SHARED_USERDATA_PATH/GB-gambatte/Game.state.auto" auto
		fi
		enable_core_saves || fail "format $fmt enable: $ACTION_RESULT"
		assert_content "$STATES_CORES/Gambatte/Game.state" z
		assert_content "$STATES_CORES/Gambatte/Game.state4" four
		assert_content "$STATES_CORES/Gambatte/Game.state.auto" auto
		assert_eq "$(enabled_value old_state_format)" "$fmt"
		assert_eq "$(get_state_format)" "3"
	done
)

test_enable_twice_changes_nothing() (
	load_fixture twice
	setup_gb_states
	enable_core_saves || fail "first enable: $ACTION_RESULT"
	first_backup=$(enabled_value states_backup)
	find "$STATES_CORES" "$CORES_PATH" -type f | LC_ALL=C sort > "$TEST_ROOT/files.1"

	enable_core_saves || fail "second enable: $ACTION_RESULT"
	find "$STATES_CORES" "$CORES_PATH" -type f | LC_ALL=C sort > "$TEST_ROOT/files.2"
	cmp "$TEST_ROOT/files.1" "$TEST_ROOT/files.2" || fail "a second enable duplicated files"
	# What the first run found is still what is on record, and its backup is
	# still the one holding the original states.
	assert_eq "$(enabled_value old_state_format)" "0"
	assert_eq "$(enabled_value states_backup)" "$first_backup"
	assert_eq "$(get_state_format)" "3"
	assert_content "$first_backup/States/GB-gambatte/Game.gb.st0" slot0
	assert_content "$STATES_CORES/Gambatte/Game.state" slot0
	grep -q 'core-conflict' "$TEST_ROOT/files.2" && fail "a conflict copy was created"

	# A state that appears in a NextUI folder between runs is picked up, once.
	put "$SHARED_USERDATA_PATH/GB-gambatte/New.gb.st2" new
	enable_core_saves || fail "third enable: $ACTION_RESULT"
	assert_content "$STATES_CORES/Gambatte/New.state2" new
	assert_eq "$(find "$STATES_CORES/Gambatte" -name 'New*' | wc -l | tr -d ' ')" "1"
	assert_eq "$(enabled_value old_state_format)" "0"
)

test_differing_states_are_kept_as_conflicts() (
	load_fixture conflict
	put "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" mine
	put "$STATES_CORES/Gambatte/Game.state" theirs
	enable_core_saves || fail "enable: $ACTION_RESULT"
	assert_content "$STATES_CORES/Gambatte/Game.state" theirs
	assert_content "$STATES_CORES/Gambatte/Game.core-conflict-1.state" mine
	assert_contains "$REPORT_FILE" "Collision"
)

test_setting_off_leaves_states_alone() (
	load_fixture off
	set_core_states_setting off
	setup_gb_states
	enable_core_saves || fail "enable: $ACTION_RESULT"
	assert_eq "$(enabled_value states)" "0"
	assert_absent "$STATES_TABLE"
	assert_absent "$STATES_CORES"
	assert_eq "$(get_state_format)" "0"
	assert_content "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" slot0
	assert_content "$SHARED_USERDATA_PATH/GBA-gpsp/notes.txt" notes
	[ ! -d "$(enabled_value backup)/States" ] || fail "states were backed up with the setting off"
	states_active && fail "states reported active"
	assert_eq "$(states_mount_status)" "Off"

	# Reverting such a setup never asks about, nor touches, states.
	revert restore || fail "revert: $ACTION_RESULT"
	assert_content "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" slot0
	assert_eq "$(get_state_format)" "0"
	case "$ACTION_RESULT" in *"States now"*) fail "the revert reported states: $ACTION_RESULT" ;; esac
	:
)

test_an_install_from_before_core_states_can_opt_in() (
	load_fixture optin
	set_core_states_setting off
	put "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" slot0
	enable_core_saves || fail "enable: $ACTION_RESULT"
	# An old marker has no states line at all.
	sed -i '/^states=/d' "$ENABLED_FILE"
	states_active && fail "an old marker counted as having states"

	# The setting default is on, so Re-apply picks states up.
	set_core_states_setting on
	enable_core_saves || fail "re-apply: $ACTION_RESULT"
	assert_eq "$(enabled_value states)" "1"
	assert_content "$STATES_CORES/Gambatte/Game.state" slot0
	assert_eq "$(enabled_value old_state_format)" "0"
)

test_revert_restores_format_and_renames_back() (
	load_fixture revert-restore
	mkdir -p "$ROMS_PATH/Game Boy (GB)"
	: > "$ROMS_PATH/Game Boy (GB)/Game.gb"
	: > "$ROMS_PATH/Game Boy (GB)/Other.gb"
	put "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" slot0
	put "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st9" auto
	enable_core_saves || fail "enable: $ACTION_RESULT"
	# A state made after enabling, and one with no ROM.
	put "$STATES_CORES/Gambatte/Other.state2" other2
	put "$STATES_CORES/Gambatte/Gone.state1" gone

	revert restore || fail "revert: $ACTION_RESULT"
	assert_eq "$(get_state_format)" "0"
	assert_absent "$ENABLED_FILE"
	assert_absent "$STATES_TABLE"
	assert_absent "$MOUNT_LAYER_FILE"
	assert_content "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" slot0
	assert_content "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st9" auto
	assert_content "$SHARED_USERDATA_PATH/GB-gambatte/Other.gb.st2" other2
	# The one without a ROM cannot get a MinUI name: it stays, and is said so.
	assert_absent "$SHARED_USERDATA_PATH/GB-gambatte/Gone.gb.st1"
	assert_content "$STATES_CORES/Gambatte/Gone.state1" gone
	assert_contains "$REPORT_FILE" "Gone.state1"
	case "$ACTION_RESULT" in *"will not load"*) ;; *) fail "the result did not say what will not load: $ACTION_RESULT" ;; esac
	case "$ACTION_RESULT" in *"Backup: $BACKUP_ROOT/"*) ;; *) fail "the result did not name the backup: $ACTION_RESULT" ;; esac
	# Nothing the user synced was deleted.
	assert_content "$STATES_CORES/Gambatte/Game.state" slot0
	assert_content "$STATES_CORES/Gambatte/Game.state.auto" auto
	assert_absent "$OPERATION_JOURNAL"
)

test_revert_keeping_the_format_uses_retroarch_names() (
	load_fixture revert-keep
	put "$SHARED_USERDATA_PATH/GBA-gpsp/Game.gba.st0" slot0
	enable_core_saves || fail "enable: $ACTION_RESULT"
	put "$STATES_CORES/gpSP/Game.state.auto.png" png
	revert keep || fail "revert: $ACTION_RESULT"
	assert_eq "$(get_state_format)" "3"
	assert_content "$SHARED_USERDATA_PATH/GBA-gpsp/Game.state" slot0
	assert_content "$SHARED_USERDATA_PATH/GBA-gpsp/Game.state.auto.png" png
	assert_absent "$ENABLED_FILE"
)

test_revert_to_an_extradot_format_renames_slots() (
	load_fixture revert-extradot
	printf 'saveFormat=3\nstateFormat=1\n' > "$SETTINGS_PATH"
	put "$SHARED_USERDATA_PATH/GBA-gpsp/Game.state.0" zero
	put "$SHARED_USERDATA_PATH/GBA-gpsp/Game.state.5" five
	put "$SHARED_USERDATA_PATH/GBA-gpsp/Game.state.auto" auto
	enable_core_saves || fail "enable: $ACTION_RESULT"
	revert restore || fail "revert: $ACTION_RESULT"
	assert_eq "$(get_state_format)" "1"
	assert_content "$SHARED_USERDATA_PATH/GBA-gpsp/Game.state.0" zero
	assert_content "$SHARED_USERDATA_PATH/GBA-gpsp/Game.state.5" five
	assert_content "$SHARED_USERDATA_PATH/GBA-gpsp/Game.state.auto" auto
)

test_shared_core_states_return_to_the_right_system() (
	load_fixture shared
	mkdir -p "$ROMS_PATH/Game Boy (GB)" "$ROMS_PATH/Game Boy Color (GBC)"
	: > "$ROMS_PATH/Game Boy (GB)/Mono.gb"
	: > "$ROMS_PATH/Game Boy Color (GBC)/Color.gbc"
	: > "$ROMS_PATH/Game Boy (GB)/Both.gb"
	: > "$ROMS_PATH/Game Boy Color (GBC)/Both.gbc"
	put "$SHARED_USERDATA_PATH/GB-gambatte/Mono.gb.st0" mono
	put "$SHARED_USERDATA_PATH/GBC-gambatte/Color.gbc.st0" color
	enable_core_saves || fail "enable: $ACTION_RESULT"
	assert_content "$STATES_CORES/Gambatte/Mono.state" mono
	assert_content "$STATES_CORES/Gambatte/Color.state" color
	put "$STATES_CORES/Gambatte/Both.state1" both

	revert keep || fail "revert: $ACTION_RESULT"
	assert_content "$SHARED_USERDATA_PATH/GB-gambatte/Mono.state" mono
	assert_content "$SHARED_USERDATA_PATH/GBC-gambatte/Color.state" color
	# Two systems have this ROM name: ambiguous, so it stays where it is.
	assert_absent "$SHARED_USERDATA_PATH/GB-gambatte/Both.state1"
	assert_absent "$SHARED_USERDATA_PATH/GBC-gambatte/Both.state1"
	assert_content "$STATES_CORES/Gambatte/Both.state1" both
	assert_contains "$REPORT_FILE" "Ambiguous"
)

test_a_states_revert_never_puts_states_in_saves() (
	load_fixture revert-saves
	put "$SDCARD_PATH/Saves/GBA/Game.gba.sav" save
	put "$SHARED_USERDATA_PATH/GBA-gpsp/Game.gba.st0" state
	printf 'saveFormat=0\nstateFormat=0\n' > "$SETTINGS_PATH"
	enable_core_saves || fail "enable: $ACTION_RESULT"
	revert keep || fail "revert: $ACTION_RESULT"
	find "$SDCARD_PATH/Saves" -name '*.state*' | grep -q . && fail "a state ended up in /Saves"
	assert_content "$SDCARD_PATH/Saves/GBA/Game.srm" save
	assert_content "$SHARED_USERDATA_PATH/GBA-gpsp/Game.state" state
)

test_the_backup_holding_the_original_states_survives_pruning() (
	load_fixture prune
	put "$SHARED_USERDATA_PATH/GBA-gpsp/Game.gba.st0" state
	enable_core_saves || fail "enable: $ACTION_RESULT"
	original=$(enabled_value states_backup)
	i=0
	while [ "$i" -lt 8 ]; do
		i=$((i + 1))
		mkdir -p "$BACKUP_ROOT/2099010$i-000000-enable/Saves"
	done
	prune_backups 5
	assert_content "$original/States/GBA-gpsp/Game.gba.st0" state
	assert_eq "$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" "6"
)

test_failed_enable_rolls_back_saves_and_states() (
	load_fixture rollback
	setup_gb_states
	put "$SDCARD_PATH/Saves/GBA/Other.gba.sav" save
	# Fails only when enabling sets the new state format; rollback is unaffected.
	set_state_format() { return 1; }

	enable_core_saves && fail "enable passed with a failing format write"
	. "$PAK_DIR/bin/states.sh"
	# Everything is back where it was.
	assert_eq "$(get_state_format)" "0"
	assert_content "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" slot0
	assert_content "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st9.png" autopng
	assert_content "$SHARED_USERDATA_PATH/GBA-gpsp/Other.gba.st1" gba1
	assert_content "$SDCARD_PATH/Saves/GBA/Other.gba.sav" save
	assert_absent "$ENABLED_FILE"
	assert_absent "$MOUNT_TABLE"
	assert_absent "$STATES_TABLE"
	assert_absent "$OPERATION_JOURNAL"
	assert_absent "$OPERATION_STATE"
	assert_absent "$MOUNT_LAYER_FILE"
	case "$ACTION_RESULT" in *"Recovered"*) ;; *) fail "rollback not reported: $ACTION_RESULT" ;; esac

	# A later enable still works and reuses the copies the failed one left.
	enable_core_saves || fail "enable after rollback: $ACTION_RESULT"
	assert_content "$STATES_CORES/Gambatte/Game.state" slot0
	grep -rq 'core-conflict' "$STATES_CORES" 2>/dev/null && fail "the leftover copies became conflicts"
	:
)

test_interrupted_enable_is_recovered() (
	load_fixture interrupted
	setup_gb_states
	put "$SDCARD_PATH/Saves/GBA/Other.gba.sav" save
	printf 'GB|gambatte|Gambatte\nGBA|gpsp|gpSP\n' > "$TEST_ROOT/table"

	# Reproduce a stop after the NextUI folders were emptied: the journal, the
	# snapshot and the backup exist, the originals are gone, the format is set.
	begin_operation enable || fail "journal"
	backup=$(make_backup enable "$TEST_ROOT/table")
	operation_phase migrating "$backup"
	for dir in GB-gambatte GBA-gpsp; do clear_states_folder "$SHARED_USERDATA_PATH/$dir"; done
	set_state_format 3
	cp "$TEST_ROOT/table" "$STATES_TABLE"

	audit_operation || fail "recovery: $ACTION_RESULT"
	assert_eq "$(get_state_format)" "0"
	assert_content "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" slot0
	assert_content "$SHARED_USERDATA_PATH/GBA-gpsp/notes.txt" notes
	assert_content "$SDCARD_PATH/Saves/GBA/Other.gba.sav" save
	assert_absent "$OPERATION_JOURNAL"
	assert_absent "$STATES_TABLE"
	assert_absent "$ENABLED_FILE"
)

test_interrupted_revert_is_recovered() (
	load_fixture interrupted-revert
	put "$SHARED_USERDATA_PATH/GBA-gpsp/Game.gba.st0" slot0
	enable_core_saves || fail "enable: $ACTION_RESULT"

	# Stop part-way through restoring states into the NextUI folder.
	begin_operation restore || fail "journal"
	unmount_core_mounts
	backup=$(make_backup restore "$STATES_TABLE")
	operation_phase backed-up "$backup"
	put "$SHARED_USERDATA_PATH/GBA-gpsp/Game.state" slot0
	set_state_format 0
	rm -f "$ENABLED_FILE" "$STATES_TABLE"

	audit_operation || fail "recovery: $ACTION_RESULT"
	assert_eq "$(get_state_format)" "3"
	assert_file "$ENABLED_FILE"
	assert_file "$STATES_TABLE"
	assert_eq "$(enabled_value states)" "1"
	assert_empty_dir "$SHARED_USERDATA_PATH/GBA-gpsp"
	assert_content "$STATES_CORES/gpSP/Game.state" slot0
	assert_absent "$OPERATION_JOURNAL"
)

test_states_follow_the_single_profile_owner() (
	load_fixture profiles
	mkdir -p "$SDCARD_PATH/.profiles/Ben/Saves"
	printf '%s\n' Ben > "$SDCARD_PATH/.profiles/active"
	put "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" state
	# The active profile decides the backup folder when the pak starts.
	. "$CORE_SAVES_DIR/launch.sh"
	show_progress() { :; }
	run_mounts() { :; }
	printf 'core_states=on\n' > "$FEATURES_FILE"

	enable_core_saves || fail "enable as the first profile: $ACTION_RESULT"
	assert_contains "$SDCARD_PATH/.profiles/core-saves-profile" "Ben"
	case "$(enabled_value states_backup)" in "$SDCARD_PATH/.profiles/Ben/.core-saves-backups/"*) ;; *) fail "backup is not per-profile: $(enabled_value states_backup)" ;; esac

	printf '%s\n' Kid > "$SDCARD_PATH/.profiles/active"
	enable_core_saves && fail "a second profile enabled Core Saves with states"
	case "$ACTION_RESULT" in *Ben*) ;; *) fail "the refusal did not name the owner: $ACTION_RESULT" ;; esac
	# Reverting stays available to every profile, as it always was.
	assert_file "$ENABLED_FILE"
)

test_one_layer_plans_saves_and_states() (
	load_fixture layer
	put "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" state
	put "$SDCARD_PATH/Saves/GB/Game.gb.sav" save
	enable_core_saves || fail "enable: $ACTION_RESULT"
	layer="$MOUNT_LAYER_FILE"
	[ ! -e "$MOUNTS_HOME/layers.d/30-core-states.sh" ] || fail "a second layer was installed"
	export MOUNTS_HOME

	sh "$layer" plan > "$TEST_ROOT/plan" || fail "plan failed"
	grep -Fq "$CORES_PATH/Gambatte	$SAVES_PATH/GB	empty-target" "$TEST_ROOT/plan" ||
		fail "no saves plan for GB: $(cat "$TEST_ROOT/plan")"
	grep -Fq "$STATES_CORES/Gambatte	$SHARED_USERDATA_PATH/GB-gambatte	empty-target" "$TEST_ROOT/plan" ||
		fail "no states plan for GB: $(cat "$TEST_ROOT/plan")"
	grep -Fq "$SHARED_USERDATA_PATH/GBC-gambatte" "$TEST_ROOT/plan" || fail "no states plan for GBC"

	# Saves keep their "below" scope; each states folder is declared exactly,
	# because layer 20 reads inside shared data.
	sh "$layer" scope > "$TEST_ROOT/scope"
	grep -Fq "below	$SAVES_PATH" "$TEST_ROOT/scope" || fail "no below scope for saves"
	grep -Fq "at	$SHARED_USERDATA_PATH/GB-gambatte" "$TEST_ROOT/scope" || fail "no at scope for states"
	grep -Fq "below	$SHARED_USERDATA_PATH" "$TEST_ROOT/scope" && fail "a below scope over shared data"

	# A setup without states plans only saves and claims no states scope.
	sed -i 's/^states=1$/states=0/' "$ENABLED_FILE"
	sh "$layer" plan > "$TEST_ROOT/plan.saves" || fail "plan failed without states"
	grep -Fq "$SHARED_USERDATA_PATH/" "$TEST_ROOT/plan.saves" && fail "states planned while off"
	[ -z "$(sh "$layer" scope | grep '^at')" ] || fail "states scope claimed while off"
	sed -i 's/^states=0$/states=1/' "$ENABLED_FILE"

	# Another profile owns it: planned nothing, while Profiles is installed.
	mkdir -p "$MOUNTS_HOME/layers.d" "$SDCARD_PATH/.profiles"
	: > "$MOUNTS_HOME/layers.d/10-profiles.sh"
	printf '%s\n' Kid > "$SDCARD_PATH/.profiles/active"
	printf '%s\n' Ben > "$SDCARD_PATH/.profiles/core-saves-profile"
	[ -z "$(sh "$layer" plan 2>/dev/null)" ] || fail "a non-owner profile got mounts"
	printf '%s\n' Ben > "$SDCARD_PATH/.profiles/active"
	[ -n "$(sh "$layer" plan 2>/dev/null)" ] || fail "the owner got no mounts"

	# The states table is missing while the marker wants it: refuses rather than
	# silently mounting only the saves.
	rm "$STATES_TABLE"
	sh "$layer" plan >/dev/null 2>&1 && fail "a missing states table was accepted"
	:
)

test_menu_rows_follow_the_setting_and_the_state() (
	load_fixture menu
	put "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" state
	row='[.settings[] | select(.name == "> Core States:")][0]'

	current_settings > "$TEST_ROOT/menu-on.json"
	jq -e "
		($row.options == [\"On\"]) and
		($row.features.unselectable == false) and
		($row.features.show_confirm == true) and
		([.settings[] | select(.name == \"> State Format:\")][0].options == [\"MinUI (.st0)\"]) and
		([.settings[] | select(.name == \"> States:\")][0].options == [\"Off\"]) and
		([.settings[] | select(.name == \"> States Location:\")][0].options == [\"/States/Cores\"]) and
		([.settings[].name] | index(\"Enable Core States\")) == null
	" "$TEST_ROOT/menu-on.json" >/dev/null || fail "inactive menu is wrong: $(cat "$TEST_ROOT/menu-on.json")"

	set_core_states_setting off
	current_settings > "$TEST_ROOT/menu-off.json"
	jq -e "$row.options == [\"Off\"]" "$TEST_ROOT/menu-off.json" >/dev/null || fail "the off setting is not shown"
	set_core_states_setting on

	# Running: the row is locked and shows what the setup includes.
	enable_core_saves || fail "enable: $ACTION_RESULT"
	current_settings > "$TEST_ROOT/menu-active.json"
	jq -e "
		($row.options == [\"On (active)\"]) and
		($row.features.unselectable == true) and
		($row.features | has(\"show_confirm\") | not) and
		([.settings[] | select(.name == \"> State Format:\")][0].options == [\"RetroArch compressed (.state)\"]) and
		([.settings[] | select(.name == \"> States:\")][0].options == [\"0/3 mounted\"]) and
		([.settings[].name] | index(\"Re-apply Core Save Mappings\")) == null
	" "$TEST_ROOT/menu-active.json" >/dev/null || fail "active menu is wrong: $(cat "$TEST_ROOT/menu-active.json")"

	# A newly installed emulator offers the one re-apply, for saves and states.
	write_emulator "$SDCARD_PATH" SFC snes9x
	current_settings > "$TEST_ROOT/menu-stale.json"
	jq -e '([.settings[].name] | index("Re-apply Core Save Mappings")) != null' \
		"$TEST_ROOT/menu-stale.json" >/dev/null || fail "no re-apply row for a new emulator"
)

test_an_old_setup_is_offered_a_reapply_for_states() (
	load_fixture stale-states
	put "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" state
	set_core_states_setting off
	enable_core_saves || fail "enable: $ACTION_RESULT"
	sed -i '/^states=/d' "$ENABLED_FILE"
	set_core_states_setting on
	current_settings > "$TEST_ROOT/menu.json"
	jq -e '([.settings[].name] | index("Re-apply Core Save Mappings")) != null' \
		"$TEST_ROOT/menu.json" >/dev/null || fail "an install without states was not offered a re-apply"
)

test_states_folders_that_do_not_exist_yet_are_created_and_mounted() (
	load_fixture missing
	# NextUI only makes <TAG>-<core> when a game of that system starts or a state
	# is first saved, so on a fresh card none of them exist.
	[ ! -e "$SHARED_USERDATA_PATH/GB-gambatte" ] || fail "fixture should start without the folder"
	put "$SHARED_USERDATA_PATH/GBA-gpsp/Game.gba.st0" slot0

	enable_core_saves || fail "enable: $ACTION_RESULT"
	# Every mapped system gets its folder and its tree, the played one and not.
	assert_empty_dir "$SHARED_USERDATA_PATH/GB-gambatte"
	assert_empty_dir "$SHARED_USERDATA_PATH/GBC-gambatte"
	[ -d "$STATES_CORES/Gambatte" ] || fail "no tree folder for a system that has no states yet"
	[ -d "$STATES_CORES/gpSP" ] || fail "no tree folder for gpSP"
	assert_contains "$STATES_TABLE" "GB|gambatte|Gambatte"
	assert_content "$STATES_CORES/gpSP/Game.state" slot0
	# The plan has a mount for the folder that did not exist.
	sh "$MOUNT_LAYER_FILE" plan | grep -Fq "$SHARED_USERDATA_PATH/GB-gambatte" ||
		fail "no mount planned for a folder that did not exist"

	# Reverting leaves the empty folders alone and puts states back where they were.
	revert keep || fail "revert: $ACTION_RESULT"
	assert_content "$SHARED_USERDATA_PATH/GBA-gpsp/Game.state" slot0
	assert_empty_dir "$SHARED_USERDATA_PATH/GB-gambatte"
)

test_slots_nextui_cannot_represent_are_refused() (
	load_fixture slots

	# NextUI reads manual slots 0-7, its hidden default in 8, and the auto-resume
	# state. A desktop slot of 9 or more has no name in formats 0 to 2: .st9 and
	# .state.auto are the auto-resume state, and .st12 is never read.
	assert_eq "$(state_from_retroarch 'Game.state8' 0 'Game.gba')" "Game.gba.st8"
	assert_eq "$(state_from_retroarch 'Game.state8' 1)" "Game.state.8"
	assert_eq "$(state_from_retroarch 'Game.state8' 2)" "Game.state.8"
	assert_eq "$(state_from_retroarch 'Game.state8' 3)" "Game.state8"
	assert_eq "$(state_from_retroarch 'Game.state8' 4)" "Game.state8"
	for fmt in 0 1 2; do
		state_from_retroarch 'Game.state9' "$fmt" 'Game.gba' >/dev/null && fail "slot 9 got a name in format $fmt"
		state_from_retroarch 'Game.state12' "$fmt" 'Game.gba' >/dev/null && fail "slot 12 got a name in format $fmt"
	done
	for fmt in 3 4; do
		assert_eq "$(state_from_retroarch 'Game.state9' "$fmt")" "Game.state9"
		assert_eq "$(state_from_retroarch 'Game.state12' "$fmt")" "Game.state12"
	done
	# The auto-resume state still maps in every format.
	assert_eq "$(state_from_retroarch 'Game.state.auto' 0 'Game.gba')" "Game.gba.st9"
	assert_eq "$(state_from_retroarch 'Game.state.auto' 1)" "Game.state.auto"
	assert_eq "$(state_from_retroarch 'Game.state.auto' 2)" "Game.state.auto"
	assert_eq "$(state_from_retroarch 'Game.state.auto' 3)" "Game.state.auto"

	# On revert they stay in the tree and are reported, never renamed onto the
	# auto-resume state.
	printf 'saveFormat=3\nstateFormat=1\n' > "$SETTINGS_PATH"
	put "$SHARED_USERDATA_PATH/GBA-gpsp/Game.state.5" five
	put "$SHARED_USERDATA_PATH/GBA-gpsp/Game.state.auto" auto
	enable_core_saves || fail "enable: $ACTION_RESULT"
	put "$STATES_CORES/gpSP/Game.state8" eight
	put "$STATES_CORES/gpSP/Game.state9" nine
	put "$STATES_CORES/gpSP/Game.state12" twelve
	revert restore || fail "revert: $ACTION_RESULT"
	assert_eq "$(get_state_format)" "1"
	assert_content "$SHARED_USERDATA_PATH/GBA-gpsp/Game.state.5" five
	assert_content "$SHARED_USERDATA_PATH/GBA-gpsp/Game.state.8" eight
	assert_content "$SHARED_USERDATA_PATH/GBA-gpsp/Game.state.auto" auto
	assert_absent "$SHARED_USERDATA_PATH/GBA-gpsp/Game.state.9"
	assert_absent "$SHARED_USERDATA_PATH/GBA-gpsp/Game.state.12"
	assert_content "$STATES_CORES/gpSP/Game.state9" nine
	assert_content "$STATES_CORES/gpSP/Game.state12" twelve
	assert_contains "$REPORT_FILE" "Game.state9 cannot be named"
	assert_contains "$REPORT_FILE" "Game.state12 cannot be named"
	case "$ACTION_RESULT" in *"will not load"*) ;; *) fail "the result did not say what will not load: $ACTION_RESULT" ;; esac
)

test_the_rom_index_is_only_built_when_a_state_needs_it() (
	load_fixture lazy
	mkdir -p "$ROMS_PATH/Game Boy Advance (GBA)"
	: > "$ROMS_PATH/Game Boy Advance (GBA)/Game.gba"
	built=0
	build_states_rom_index() { built=$((built + 1)); : > "$2"; }
	printf 'GBA|gpsp|gpSP\n' > "$STATES_TABLE"
	put "$STATES_CORES/gpSP/Game.state" one

	# One system for the core, a format that needs no ROM name: never built.
	for fmt in 1 2 3 4; do
		build_states_restore_plan "$fmt" "$TEST_ROOT/plan" "$TEST_ROOT/index" || fail "plan for format $fmt"
		assert_eq "$STATES_INDEX_BUILT" "0"
		assert_eq "$STATES_RESTORE_MATCHED" "1"
	done
	assert_eq "$built" "0"

	# The MinUI format names the file after the ROM, so it needs the index.
	build_states_restore_plan 0 "$TEST_ROOT/plan" "$TEST_ROOT/index" || fail "plan for format 0"
	assert_eq "$STATES_INDEX_BUILT" "1"
	assert_eq "$built" "1"

	# A core shared by two systems needs a ROM to tell them apart, for any format.
	printf 'GB|gambatte|Gambatte\nGBC|gambatte|Gambatte\n' > "$STATES_TABLE"
	put "$STATES_CORES/Gambatte/Game.state" two
	build_states_restore_plan 3 "$TEST_ROOT/plan" "$TEST_ROOT/index" || fail "plan for a shared core"
	assert_eq "$STATES_INDEX_BUILT" "1"
	assert_eq "$built" "2"
)

test_the_rom_index_rows() (
	load_fixture rom-index
	r="$ROMS_PATH"
	mkdir -p "$r/Game Boy (GB)/sub" "$r/Game Boy Color (GBC)" "$r/(GB)" "$r/Other (SFC)"
	for f in "Game Boy (GB)/Mono.gb" "Game Boy (GB)/sub/Deep.gb" "Game Boy (GB)/Dr. Mario.gb" \
		"Game Boy Color (GBC)/Zip Game.gbc.zip" "Game Boy Color (GBC)/Up.ZIP" "(GB)/Root.gb" \
		"Game Boy (GB)/x.z" "Game Boy (GB)/noext" "Other (SFC)/Skip.sfc"; do
		: > "$r/$f"
	done
	printf 'GB|gambatte|Gambatte\nGBC|gambatte|Gambatte\n' > "$TEST_ROOT/table"
	build_states_rom_index "$TEST_ROOT/table" "$TEST_ROOT/index" || fail "index failed"
	cat > "$TEST_ROOT/expected" <<'EOF'
GBC|Up|Up.ZIP|direct
GBC|Zip Game.gbc|Zip Game.gbc.zip|direct
GBC|Zip Game|Zip Game.gbc.zip|archive
GB|Deep|Deep.gb|direct
GB|Dr. Mario|Dr. Mario.gb|direct
GB|Mono|Mono.gb|direct
GB|Root|Root.gb|direct
GB|noext|noext|direct
GB|x.z|x.z|direct
EOF
	LC_ALL=C sort "$TEST_ROOT/expected" > "$TEST_ROOT/expected.sorted"
	cmp "$TEST_ROOT/expected.sorted" "$TEST_ROOT/index" || fail "unexpected index: $(cat "$TEST_ROOT/index")"
)

test_tag_matching_for_shared_cores() (
	load_fixture tags
	printf 'GB|gambatte|Gambatte\nGBC|gambatte|Gambatte\nGBA|gpsp|gpSP\n' > "$TEST_ROOT/table"
	cat > "$TEST_ROOT/index" <<'EOF'
GB|Both|Both.gb|direct
GBC|Both|Both.gbc|direct
GBC|Only|Only.gbc|direct
GB|Mono|Mono.gb|direct
EOF
	# One tag for the core: no ROM needed, even with an empty index.
	: > "$TEST_ROOT/empty"
	assert_eq "$(states_tag_for gpSP Anything "$TEST_ROOT/table" "$TEST_ROOT/empty")" "GBA"
	# GB is a prefix of GBC; only exact tags count.
	assert_eq "$(states_tag_for Gambatte Only "$TEST_ROOT/table" "$TEST_ROOT/index")" "GBC"
	assert_eq "$(states_tag_for Gambatte Mono "$TEST_ROOT/table" "$TEST_ROOT/index")" "GB"
	rc=0
	states_tag_for Gambatte Both "$TEST_ROOT/table" "$TEST_ROOT/index" >/dev/null || rc=$?
	assert_eq "$rc" "2"
	rc=0
	states_tag_for Gambatte Nowhere "$TEST_ROOT/table" "$TEST_ROOT/index" >/dev/null || rc=$?
	assert_eq "$rc" "1"
	# A tag in the index that does not belong to this core is ignored.
	printf 'GBA|Only|Only.gba|direct\n' >> "$TEST_ROOT/index"
	assert_eq "$(states_tag_for Gambatte Only "$TEST_ROOT/table" "$TEST_ROOT/index")" "GBC"
)

test_the_core_states_row_can_be_switched_for_a_setup_without_states() (
	load_fixture row
	put "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" state
	row='[.settings[] | select(.name == "> Core States:")][0]'
	set_core_states_setting off
	enable_core_saves || fail "enable: $ACTION_RESULT"
	assert_eq "$(enabled_value states)" "0"

	# Converted without states: the row is selectable and shows the setting.
	current_settings > "$TEST_ROOT/menu-off.json"
	jq -e "
		($row.options == [\"Off\"]) and
		($row.features.unselectable == false) and
		($row.features.show_confirm == true) and
		([.settings[].name] | index(\"Re-apply Core Save Mappings\")) == null
	" "$TEST_ROOT/menu-off.json" >/dev/null || fail "off row is wrong: $(cat "$TEST_ROOT/menu-off.json")"

	# Switching it on offers the Re-apply that brings the states in.
	set_core_states_setting on
	current_settings > "$TEST_ROOT/menu-on.json"
	jq -e "
		($row.options == [\"On\"]) and
		($row.features.unselectable == false) and
		([.settings[].name] | index(\"Re-apply Core Save Mappings\")) != null
	" "$TEST_ROOT/menu-on.json" >/dev/null || fail "on row is wrong: $(cat "$TEST_ROOT/menu-on.json")"
	enable_core_saves || fail "re-apply: $ACTION_RESULT"
	assert_eq "$(enabled_value states)" "1"
	assert_content "$STATES_CORES/Gambatte/Game.state" state

	# Now the setup carries states: locked, and the setting cannot take them out.
	current_settings > "$TEST_ROOT/menu-active.json"
	jq -e "
		($row.options == [\"On (active)\"]) and
		($row.features.unselectable == true) and
		($row.features | has(\"show_confirm\") | not)
	" "$TEST_ROOT/menu-active.json" >/dev/null || fail "active row is wrong: $(cat "$TEST_ROOT/menu-active.json")"
	set_core_states_setting off
	core_states_wanted || fail "an active setup stopped wanting its states"
)

test_a_reapply_never_drops_the_states_of_a_setup_that_has_them() (
	load_fixture noreapply
	put "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" state
	enable_core_saves || fail "enable: $ACTION_RESULT"
	cp "$ENABLED_FILE" "$TEST_ROOT/enabled.before"
	cp "$STATES_TABLE" "$TEST_ROOT/table.before"
	cp "$MOUNT_TABLE" "$TEST_ROOT/saves-table.before"
	cp "$SETTINGS_PATH" "$TEST_ROOT/settings.before"

	# The emulators lose their EMU_EXE but are still mapped by override, so
	# saves discovery works and only the states table comes out empty.
	for tag in GB GBC GBA; do printf '#!/bin/sh\n' > "$SYSTEM_PATH/paks/Emus/$tag.pak/launch.sh"; done
	MAPPING_CONF="$TEST_ROOT/mapping.conf"
	printf 'GB=Gambatte\nGBC=Gambatte\nGBA=gpSP\n' > "$MAPPING_CONF"

	enable_core_saves && fail "a re-apply with no states folders passed"
	case "$ACTION_RESULT" in *"No mapped emulator has a states folder"*) ;; *) fail "unexpected result: $ACTION_RESULT" ;; esac
	assert_contains "$REPORT_FILE" "left exactly as it is"
	# Nothing changed: same marker, tables and format, states still in the tree,
	# no half-finished operation.
	cmp "$TEST_ROOT/enabled.before" "$ENABLED_FILE" || fail "the marker changed"
	cmp "$TEST_ROOT/table.before" "$STATES_TABLE" || fail "the states table changed"
	cmp "$TEST_ROOT/saves-table.before" "$MOUNT_TABLE" || fail "the saves table changed"
	cmp "$TEST_ROOT/settings.before" "$SETTINGS_PATH" || fail "the settings changed"
	assert_eq "$(enabled_value states)" "1"
	assert_content "$STATES_CORES/Gambatte/Game.state" state
	assert_absent "$OPERATION_JOURNAL"
	assert_absent "$OPERATION_STATE"
)

test_a_first_conversion_without_state_folders_continues_with_saves() (
	load_fixture softer
	put "$SDCARD_PATH/Saves/GB/Game.gb.sav" save
	printf 'saveFormat=0\nstateFormat=0\n' > "$SETTINGS_PATH"
	for tag in GB GBC GBA; do printf '#!/bin/sh\n' > "$SYSTEM_PATH/paks/Emus/$tag.pak/launch.sh"; done
	MAPPING_CONF="$TEST_ROOT/mapping.conf"
	printf 'GB=Gambatte\nGBC=Gambatte\nGBA=gpSP\n' > "$MAPPING_CONF"

	enable_core_saves || fail "enable: $ACTION_RESULT"
	assert_eq "$(enabled_value states)" "0"
	assert_absent "$STATES_TABLE"
	assert_eq "$(get_state_format)" "0"
	assert_content "$CORES_PATH/Gambatte/Game.srm" save
	assert_contains "$REPORT_FILE" "no mapped emulator has a states folder"
)

test_a_reapply_keeps_a_retroarch_format_the_user_chose() (
	load_fixture format-kept
	put "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" state
	enable_core_saves || fail "enable: $ACTION_RESULT"
	assert_eq "$(get_state_format)" "3"
	assert_eq "$(enabled_value old_state_format)" "0"

	# Uncompressed RetroArch is just as good; the re-apply leaves it alone.
	set_state_format 4
	enable_core_saves || fail "re-apply with format 4: $ACTION_RESULT"
	assert_eq "$(get_state_format)" "4"
	assert_eq "$(enabled_value old_state_format)" "0"

	# A format that names files differently is put back to RetroArch.
	set_state_format 1
	enable_core_saves || fail "re-apply with format 1: $ACTION_RESULT"
	assert_eq "$(get_state_format)" "3"
	assert_eq "$(enabled_value old_state_format)" "0"
	set_state_format 0
	enable_core_saves || fail "re-apply with format 0: $ACTION_RESULT"
	assert_eq "$(get_state_format)" "3"
)

test_nothing_is_touched_when_nothing_maps() (
	load_fixture nothing
	rm -rf "$SYSTEM_PATH/paks/Emus"
	put "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" state
	enable_core_saves && fail "enable passed with no emulators"
	assert_content "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" state
	assert_eq "$(get_state_format)" "0"
	assert_absent "$ENABLED_FILE"
)

test_state_name_mapping
test_state_format_record_and_restore
test_the_setting_is_on_by_default_and_persists
test_states_table_uses_emu_exe_for_the_folder
test_enable_moves_saves_and_states_in_one_transaction
test_every_input_format_lands_on_retroarch_names
test_enable_twice_changes_nothing
test_differing_states_are_kept_as_conflicts
test_setting_off_leaves_states_alone
test_an_install_from_before_core_states_can_opt_in
test_revert_restores_format_and_renames_back
test_revert_keeping_the_format_uses_retroarch_names
test_revert_to_an_extradot_format_renames_slots
test_shared_core_states_return_to_the_right_system
test_a_states_revert_never_puts_states_in_saves
test_the_backup_holding_the_original_states_survives_pruning
test_failed_enable_rolls_back_saves_and_states
test_interrupted_enable_is_recovered
test_interrupted_revert_is_recovered
test_states_follow_the_single_profile_owner
test_one_layer_plans_saves_and_states
test_menu_rows_follow_the_setting_and_the_state
test_an_old_setup_is_offered_a_reapply_for_states
test_states_folders_that_do_not_exist_yet_are_created_and_mounted
test_slots_nextui_cannot_represent_are_refused
test_the_rom_index_is_only_built_when_a_state_needs_it
test_the_rom_index_rows
test_tag_matching_for_shared_cores
test_the_core_states_row_can_be_switched_for_a_setup_without_states
test_a_reapply_never_drops_the_states_of_a_setup_that_has_them
test_a_first_conversion_without_state_folders_continues_with_saves
test_a_reapply_keeps_a_retroarch_format_the_user_chose
test_nothing_is_touched_when_nothing_maps
echo "RetroArch Core States tests passed"
