#!/bin/sh
# Core States, host-side: name mapping, the format setting, enable and disable,
# recovery, backups and independence from Core Saves. Real bind mounts are
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
	run_states_mounts() { :; }
	printf 'stateFormat=0\nsaveFormat=3\notherSetting=1\n' > "$SETTINGS_PATH"
}

# Writes a state file whose content names it, so a mix-up is visible.
put() {
	mkdir -p "$(dirname "$1")"
	printf '%s' "${2:-$(basename "$1")}" > "$1"
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

	# Every format round-trips through RetroArch's names unchanged.
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

test_states_discovery_uses_emu_exe_for_the_folder() (
	load_fixture discover
	printf 'GB|gambatte|Gambatte\nGBA|gpsp|gpSP\nGBC|gambatte|Gambatte\n' > "$TEST_ROOT/expected"
	discover_states_mappings "$TEST_ROOT/table" quiet || fail "discovery failed"
	cmp "$TEST_ROOT/expected" "$TEST_ROOT/table" || fail "unexpected states table: $(cat "$TEST_ROOT/table")"

	# An override has no EMU_EXE to name the folder after, so it is reported and
	# left out rather than guessed.
	mkdir -p "$SYSTEM_PATH/paks/Emus/ZZZ.pak"
	printf '#!/bin/sh\n' > "$SYSTEM_PATH/paks/Emus/ZZZ.pak/launch.sh"
	MAPPING_CONF="$TEST_ROOT/mapping.conf"
	printf 'ZZZ=Custom\n' > "$MAPPING_CONF"
	start_report test
	discover_states_mappings "$TEST_ROOT/table2" || fail "discovery with an override failed"
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

test_enable_renames_states_and_records_the_format() (
	load_fixture enable
	setup_gb_states
	put "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st9.png" autopng

	enable_core_states || fail "enable failed: $ACTION_RESULT"
	assert_file "$STATES_ENABLED_FILE"
	assert_eq "$(get_state_format)" "3"
	assert_eq "$(states_marker_value old_format)" "0"

	assert_content "$STATES_CORES/Gambatte/Game.state" slot0
	assert_content "$STATES_CORES/Gambatte/Game.state3" slot3
	assert_content "$STATES_CORES/Gambatte/Game.state.auto" auto
	assert_content "$STATES_CORES/Gambatte/Game.state.auto.png" autopng
	assert_content "$STATES_CORES/gpSP/Other.state1" gba1
	# Not a state name: still carried over, since the folder is about to be hidden.
	assert_content "$STATES_CORES/gpSP/notes.txt" notes
	assert_absent "$STATES_CORES/Gambatte/Game.gb.st0"

	# The NextUI folders were emptied for their mounts.
	assert_empty_dir "$SHARED_USERDATA_PATH/GB-gambatte"
	assert_empty_dir "$SHARED_USERDATA_PATH/GBA-gpsp"

	assert_file "$STATES_TABLE"
	assert_contains "$STATES_TABLE" "GB|gambatte|Gambatte"
	assert_contains "$STATES_TABLE" "GBC|gambatte|Gambatte"
	assert_file "$STATES_LAYER_FILE"

	# The original files are in the backup, with the settings as they were.
	backup=$(states_marker_value backup)
	case "$backup" in "$BACKUP_ROOT/core-states/"*) ;; *) fail "backup is not under core-states: $backup" ;; esac
	assert_content "$backup/States/GB-gambatte/Game.gb.st0" slot0
	assert_content "$backup/States/GB-gambatte/Game.gb.st9.png" autopng
	assert_contains "$backup/minuisettings.txt" "stateFormat=0"

	assert_contains "$REPORT_FILE" "CONVERTED"
	assert_contains "$REPORT_FILE" "SKIPPED"
	assert_contains "$REPORT_FILE" "Issues requiring attention: 0"
	assert_absent "$STATES_JOURNAL"
	assert_absent "$STATES_STATE"
	# Core Saves stays off: enabling states never touches it.
	assert_absent "$ENABLED_FILE"
	assert_absent "$MOUNT_TABLE"
	assert_absent "$MOUNT_LAYER_FILE"
)

test_every_input_format_lands_on_retroarch_names() (
	for fmt in 1 2 3 4; do
		load_fixture "fmt$fmt"
		printf 'stateFormat=%s\n' "$fmt" > "$SETTINGS_PATH"
		if [ "$fmt" -le 2 ]; then
			put "$SHARED_USERDATA_PATH/GB-gambatte/Game.state.0" z
			put "$SHARED_USERDATA_PATH/GB-gambatte/Game.state.4" four
			put "$SHARED_USERDATA_PATH/GB-gambatte/Game.state.auto" auto
		else
			put "$SHARED_USERDATA_PATH/GB-gambatte/Game.state" z
			put "$SHARED_USERDATA_PATH/GB-gambatte/Game.state4" four
			put "$SHARED_USERDATA_PATH/GB-gambatte/Game.state.auto" auto
		fi
		enable_core_states || fail "format $fmt enable: $ACTION_RESULT"
		assert_content "$STATES_CORES/Gambatte/Game.state" z
		assert_content "$STATES_CORES/Gambatte/Game.state4" four
		assert_content "$STATES_CORES/Gambatte/Game.state.auto" auto
		assert_eq "$(states_marker_value old_format)" "$fmt"
		assert_eq "$(get_state_format)" "3"
	done
)

test_enable_twice_changes_nothing() (
	load_fixture twice
	setup_gb_states
	enable_core_states || fail "first enable: $ACTION_RESULT"
	find "$STATES_CORES" -type f | LC_ALL=C sort > "$TEST_ROOT/files.1"
	backups=$(find "$BACKUP_ROOT/core-states" -mindepth 1 -maxdepth 1 | wc -l)

	enable_core_states || fail "second enable: $ACTION_RESULT"
	find "$STATES_CORES" -type f | LC_ALL=C sort > "$TEST_ROOT/files.2"
	cmp "$TEST_ROOT/files.1" "$TEST_ROOT/files.2" || fail "a second enable duplicated states"
	# The format from before the first run is still the one on record.
	assert_eq "$(states_marker_value old_format)" "0"
	assert_eq "$(get_state_format)" "3"
	assert_eq "$(find "$BACKUP_ROOT/core-states" -mindepth 1 -maxdepth 1 | wc -l)" "$backups"
	assert_content "$STATES_CORES/Gambatte/Game.state" slot0
	grep -q 'core-conflict' "$TEST_ROOT/files.2" && fail "a conflict copy was created"

	# A state that appears in a NextUI folder between runs is picked up, once.
	put "$SHARED_USERDATA_PATH/GB-gambatte/New.gb.st2" new
	enable_core_states || fail "third enable: $ACTION_RESULT"
	assert_content "$STATES_CORES/Gambatte/New.state2" new
	assert_eq "$(find "$STATES_CORES/Gambatte" -name 'New*' | wc -l)" "1"
	assert_eq "$(states_marker_value old_format)" "0"
)

test_differing_states_are_kept_as_conflicts() (
	load_fixture conflict
	put "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" mine
	put "$STATES_CORES/Gambatte/Game.state" theirs
	enable_core_states || fail "enable: $ACTION_RESULT"
	assert_content "$STATES_CORES/Gambatte/Game.state" theirs
	assert_content "$STATES_CORES/Gambatte/Game.core-conflict-1.state" mine
	assert_contains "$REPORT_FILE" "Collision"
)

test_disable_restores_format_and_renames_back() (
	load_fixture disable-restore
	mkdir -p "$ROMS_PATH/Game Boy (GB)"
	: > "$ROMS_PATH/Game Boy (GB)/Game.gb"
	: > "$ROMS_PATH/Game Boy (GB)/Other.gb"
	put "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" slot0
	put "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st9" auto
	enable_core_states || fail "enable: $ACTION_RESULT"
	# A state made after enabling, and one with no ROM.
	put "$STATES_CORES/Gambatte/Other.state2" other2
	put "$STATES_CORES/Gambatte/Gone.state1" gone

	disable_core_states restore || fail "disable: $ACTION_RESULT"
	assert_eq "$(get_state_format)" "0"
	assert_absent "$STATES_ENABLED_FILE"
	assert_absent "$STATES_TABLE"
	assert_absent "$STATES_LAYER_FILE"
	assert_content "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" slot0
	assert_content "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st9" auto
	assert_content "$SHARED_USERDATA_PATH/GB-gambatte/Other.gb.st2" other2
	# The one without a ROM cannot get a MinUI name: it stays, and is said so.
	assert_absent "$SHARED_USERDATA_PATH/GB-gambatte/Gone.gb.st1"
	assert_content "$STATES_CORES/Gambatte/Gone.state1" gone
	assert_contains "$REPORT_FILE" "Gone.state1"
	case "$ACTION_RESULT" in *"will not load"*) ;; *) fail "the result did not say what will not load: $ACTION_RESULT" ;; esac
	case "$ACTION_RESULT" in *"$BACKUP_ROOT/core-states/"*) ;; *) fail "the result did not name the backup" ;; esac
	# Nothing the user synced was deleted.
	assert_content "$STATES_CORES/Gambatte/Game.state" slot0
	assert_content "$STATES_CORES/Gambatte/Game.state.auto" auto
	assert_absent "$STATES_JOURNAL"
)

test_disable_keeping_the_format_uses_retroarch_names() (
	load_fixture disable-keep
	put "$SHARED_USERDATA_PATH/GBA-gpsp/Game.gba.st0" slot0
	enable_core_states || fail "enable: $ACTION_RESULT"
	put "$STATES_CORES/gpSP/Game.state.auto.png" png
	disable_core_states keep || fail "disable: $ACTION_RESULT"
	assert_eq "$(get_state_format)" "3"
	assert_content "$SHARED_USERDATA_PATH/GBA-gpsp/Game.state" slot0
	assert_content "$SHARED_USERDATA_PATH/GBA-gpsp/Game.state.auto.png" png
	assert_absent "$STATES_ENABLED_FILE"
)

test_disable_to_an_extradot_format_renames_slots() (
	load_fixture disable-extradot
	printf 'stateFormat=1\n' > "$SETTINGS_PATH"
	put "$SHARED_USERDATA_PATH/GBA-gpsp/Game.state.0" zero
	put "$SHARED_USERDATA_PATH/GBA-gpsp/Game.state.5" five
	put "$SHARED_USERDATA_PATH/GBA-gpsp/Game.state.auto" auto
	enable_core_states || fail "enable: $ACTION_RESULT"
	disable_core_states restore || fail "disable: $ACTION_RESULT"
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
	enable_core_states || fail "enable: $ACTION_RESULT"
	assert_content "$STATES_CORES/Gambatte/Mono.state" mono
	assert_content "$STATES_CORES/Gambatte/Color.state" color
	put "$STATES_CORES/Gambatte/Both.state1" both

	disable_core_states keep || fail "disable: $ACTION_RESULT"
	assert_content "$SHARED_USERDATA_PATH/GB-gambatte/Mono.state" mono
	assert_content "$SHARED_USERDATA_PATH/GBC-gambatte/Color.state" color
	# Two systems have this ROM name: ambiguous, so it stays where it is.
	assert_absent "$SHARED_USERDATA_PATH/GB-gambatte/Both.state1"
	assert_absent "$SHARED_USERDATA_PATH/GBC-gambatte/Both.state1"
	assert_content "$STATES_CORES/Gambatte/Both.state1" both
	assert_contains "$REPORT_FILE" "Ambiguous"
)

test_states_backups_are_never_pruned() (
	load_fixture prune
	i=0
	while [ "$i" -lt 8 ]; do
		i=$((i + 1))
		mkdir -p "$BACKUP_ROOT/core-states/2026010$i-000000-enable/States"
		mkdir -p "$BACKUP_ROOT/2026010$i-000000-enable/Saves"
	done
	prune_backups 5
	assert_eq "$(find "$BACKUP_ROOT/core-states" -mindepth 1 -maxdepth 1 | wc -l)" "8"
	assert_eq "$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name core-states | wc -l)" "5"
)

test_failed_enable_rolls_back() (
	load_fixture rollback
	setup_gb_states
	# Fails only when enabling sets the new format; rollback's write still works.
	set_state_format() {
		[ "$1" != 3 ] || return 1
		sed "s/^stateFormat=.*/stateFormat=$1/" "$SETTINGS_PATH" > "$SETTINGS_PATH.t" &&
			mv "$SETTINGS_PATH.t" "$SETTINGS_PATH"
	}

	enable_core_states && fail "enable passed with a failing format write"
	. "$PAK_DIR/bin/states.sh"
	run_states_mounts() { :; }
	# Everything is back where it was.
	assert_eq "$(get_state_format)" "0"
	assert_content "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" slot0
	assert_content "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st9.png" autopng
	assert_content "$SHARED_USERDATA_PATH/GBA-gpsp/Other.gba.st1" gba1
	assert_absent "$STATES_ENABLED_FILE"
	assert_absent "$STATES_TABLE"
	assert_absent "$STATES_JOURNAL"
	assert_absent "$STATES_STATE"
	assert_absent "$STATES_LAYER_FILE"
	case "$ACTION_RESULT" in *"Recovered"*) ;; *) fail "rollback not reported: $ACTION_RESULT" ;; esac

	# A later enable still works and reuses the copies the failed one left.
	enable_core_states || fail "enable after rollback: $ACTION_RESULT"
	assert_content "$STATES_CORES/Gambatte/Game.state" slot0
	grep -rq 'core-conflict' "$STATES_CORES" 2>/dev/null && fail "the leftover copies became conflicts"
	:
)

test_interrupted_enable_is_recovered() (
	load_fixture interrupted
	setup_gb_states

	# Reproduce a stop after the folders were emptied: the journal, the snapshot
	# and the backup exist, the originals are gone, the format is already set.
	begin_states_operation enable || fail "journal"
	backup=$(make_states_backup enable "$SHARED_USERDATA_PATH/GB-gambatte" "$SHARED_USERDATA_PATH/GBA-gpsp")
	states_phase clearing "$backup"
	rm -rf "$SHARED_USERDATA_PATH/GB-gambatte"/* "$SHARED_USERDATA_PATH/GBA-gpsp"/*
	set_state_format 3
	printf 'GB|gambatte|Gambatte\n' > "$STATES_TABLE"

	audit_states_operation || fail "recovery: $ACTION_RESULT"
	assert_eq "$(get_state_format)" "0"
	assert_content "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" slot0
	assert_content "$SHARED_USERDATA_PATH/GBA-gpsp/notes.txt" notes
	assert_absent "$STATES_JOURNAL"
	assert_absent "$STATES_TABLE"
	assert_absent "$STATES_ENABLED_FILE"
)

test_interrupted_disable_is_recovered() (
	load_fixture interrupted-disable
	put "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" slot0
	enable_core_states || fail "enable: $ACTION_RESULT"

	# Stop part-way through copying states back.
	begin_states_operation disable || fail "journal"
	backup=$(make_states_backup disable "$STATES_CORES/Gambatte")
	states_phase copying "$backup"
	put "$SHARED_USERDATA_PATH/GB-gambatte/Game.state" slot0
	printf '%s\n' "$SHARED_USERDATA_PATH/GB-gambatte/Game.state" >> "$STATES_STATE/copied"
	set_state_format 0

	audit_states_operation || fail "recovery: $ACTION_RESULT"
	assert_eq "$(get_state_format)" "3"
	assert_file "$STATES_ENABLED_FILE"
	assert_file "$STATES_TABLE"
	assert_empty_dir "$SHARED_USERDATA_PATH/GB-gambatte"
	assert_content "$STATES_CORES/Gambatte/Game.state" slot0
	assert_absent "$STATES_JOURNAL"
)

test_core_saves_and_core_states_are_independent() (
	load_fixture independent
	printf 'saveFormat=0\nstateFormat=0\n' > "$SETTINGS_PATH"
	put "$SDCARD_PATH/Saves/GB/Game.gb.sav" save
	put "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" state

	# States on, saves off.
	enable_core_states || fail "states: $ACTION_RESULT"
	assert_file "$STATES_ENABLED_FILE"
	assert_absent "$ENABLED_FILE"
	assert_content "$SDCARD_PATH/Saves/GB/Game.gb.sav" save

	# Saves on as well: neither disturbs the other.
	enable_core_saves || fail "saves: $ACTION_RESULT"
	assert_file "$ENABLED_FILE"
	assert_file "$STATES_ENABLED_FILE"
	assert_content "$SDCARD_PATH/Saves/Cores/Gambatte/Game.srm" save
	assert_content "$STATES_CORES/Gambatte/Game.state" state
	assert_file "$STATES_LAYER_FILE"
	assert_file "$MOUNT_LAYER_FILE"

	# Reverting saves leaves the states, their layer and the format alone.
	restore_to_legacy current || fail "revert saves: $ACTION_RESULT"
	assert_absent "$ENABLED_FILE"
	assert_file "$STATES_ENABLED_FILE"
	assert_file "$STATES_LAYER_FILE"
	assert_content "$STATES_CORES/Gambatte/Game.state" state
	assert_eq "$(get_state_format)" "3"
	# ...and the saves restore never copied a state into /Saves.
	find "$SDCARD_PATH/Saves" -name '*.state*' | grep -q . && fail "a state ended up in /Saves"

	# Saves back on, then states off: now the saves are untouched.
	enable_core_saves || fail "saves again: $ACTION_RESULT"
	disable_core_states keep || fail "states off: $ACTION_RESULT"
	assert_file "$ENABLED_FILE"
	assert_file "$MOUNT_LAYER_FILE"
	assert_absent "$STATES_LAYER_FILE"
	assert_content "$SDCARD_PATH/Saves/Cores/Gambatte/Game.srm" save
)

test_states_follow_the_single_profile_owner() (
	load_fixture profiles
	mkdir -p "$SDCARD_PATH/.profiles/Ben/Saves"
	printf '%s\n' Ben > "$SDCARD_PATH/.profiles/active"
	put "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" state
	# The active profile decides the backup folder when the pak starts.
	. "$CORE_SAVES_DIR/launch.sh"
	show_progress() { :; }
	run_states_mounts() { :; }

	enable_core_states || fail "enable as the first profile: $ACTION_RESULT"
	assert_contains "$SDCARD_PATH/.profiles/core-saves-profile" "Ben"
	# Backups are the active profile's.
	case "$(states_marker_value backup)" in "$SDCARD_PATH/.profiles/Ben/.core-saves-backups/core-states/"*) ;; *) fail "backup is not per-profile: $(states_marker_value backup)" ;; esac

	printf '%s\n' Kid > "$SDCARD_PATH/.profiles/active"
	enable_core_states && fail "a second profile enabled Core States"
	case "$ACTION_RESULT" in *Ben*) ;; *) fail "the refusal did not name the owner: $ACTION_RESULT" ;; esac
	disable_core_states keep && fail "a second profile disabled Core States"
	assert_file "$STATES_ENABLED_FILE"
)

test_states_layer_plan_and_scope() (
	load_fixture layer
	put "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" state
	enable_core_states || fail "enable: $ACTION_RESULT"
	export MOUNTS_HOME
	layer="$STATES_LAYER_FILE"

	sh "$layer" plan > "$TEST_ROOT/plan" || fail "plan failed"
	grep -Fq "$STATES_CORES/Gambatte	$SHARED_USERDATA_PATH/GB-gambatte	empty-target" "$TEST_ROOT/plan" ||
		fail "no plan for GB: $(cat "$TEST_ROOT/plan")"
	grep -Fq "$SHARED_USERDATA_PATH/GBC-gambatte" "$TEST_ROOT/plan" || fail "no plan for GBC"

	# One exact scope per folder, and no "below": layer 20 reads inside shared data.
	sh "$layer" scope > "$TEST_ROOT/scope"
	grep -Fq "at	$SHARED_USERDATA_PATH/GB-gambatte" "$TEST_ROOT/scope" || fail "no at scope"
	grep -q '^below' "$TEST_ROOT/scope" && fail "the layer declared a below scope"

	# Not enabled: nothing planned, nothing owned.
	mv "$STATES_ENABLED_FILE" "$STATES_ENABLED_FILE.off"
	[ -z "$(sh "$layer" plan)" ] || fail "a disabled layer planned mounts"
	[ -z "$(sh "$layer" scope | grep '^at')" ] || fail "a disabled layer claimed scope"
	mv "$STATES_ENABLED_FILE.off" "$STATES_ENABLED_FILE"

	# Another profile owns it: planned nothing, while Profiles is installed.
	mkdir -p "$MOUNTS_HOME/layers.d" "$SDCARD_PATH/.profiles"
	: > "$MOUNTS_HOME/layers.d/10-profiles.sh"
	printf '%s\n' Kid > "$SDCARD_PATH/.profiles/active"
	printf '%s\n' Ben > "$SDCARD_PATH/.profiles/core-saves-profile"
	[ -z "$(sh "$layer" plan 2>/dev/null)" ] || fail "a non-owner profile got mounts"
	printf '%s\n' Ben > "$SDCARD_PATH/.profiles/active"
	[ -n "$(sh "$layer" plan 2>/dev/null)" ] || fail "the owner got no mounts"

	# The table is missing while enabled: refuses rather than planning nothing.
	rm "$STATES_TABLE"
	sh "$layer" plan >/dev/null 2>&1 && fail "a missing table was accepted"
	:
)

test_menu_rows_follow_the_states_state() (
	load_fixture menu
	put "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" state
	current_settings > "$TEST_ROOT/menu-off.json"
	jq -e '
		([.settings[].name] | index("Enable Core States")) != null and
		([.settings[].name] | index("Disable Core States")) == null and
		([.settings[] | select(.name == "> State Format:")][0].options == ["MinUI (.st0)"]) and
		([.settings[] | select(.name == "> States:")][0].options == ["Off"]) and
		([.settings[] | select(.name == "> States Location:")][0].options == ["/States/Cores"])
	' "$TEST_ROOT/menu-off.json" >/dev/null || fail "inactive states menu is wrong: $(cat "$TEST_ROOT/menu-off.json")"

	enable_core_states || fail "enable: $ACTION_RESULT"
	current_settings > "$TEST_ROOT/menu-on.json"
	jq -e '
		([.settings[].name] | index("Enable Core States")) == null and
		([.settings[].name] | index("Re-apply Core States Mappings")) == null and
		([.settings[].name] | index("Disable Core States")) != null and
		([.settings[] | select(.name == "> State Format:")][0].options == ["RetroArch compressed (.state)"]) and
		([.settings[] | select(.name == "> States:")][0].options == ["0/3 mounted"])
	' "$TEST_ROOT/menu-on.json" >/dev/null || fail "active states menu is wrong: $(cat "$TEST_ROOT/menu-on.json")"

	# A newly installed emulator offers a re-apply.
	write_emulator "$SDCARD_PATH" SFC snes9x
	current_settings > "$TEST_ROOT/menu-stale.json"
	jq -e '([.settings[].name] | index("Re-apply Core States Mappings")) != null' \
		"$TEST_ROOT/menu-stale.json" >/dev/null || fail "no re-apply row for a new emulator"
)

test_states_are_untouched_when_nothing_maps() (
	load_fixture nothing
	rm -rf "$SYSTEM_PATH/paks/Emus"
	put "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" state
	enable_core_states && fail "enable passed with no emulators"
	assert_content "$SHARED_USERDATA_PATH/GB-gambatte/Game.gb.st0" state
	assert_eq "$(get_state_format)" "0"
	assert_absent "$STATES_ENABLED_FILE"
)

test_state_name_mapping
test_state_format_record_and_restore
test_states_discovery_uses_emu_exe_for_the_folder
test_enable_renames_states_and_records_the_format
test_every_input_format_lands_on_retroarch_names
test_enable_twice_changes_nothing
test_differing_states_are_kept_as_conflicts
test_disable_restores_format_and_renames_back
test_disable_keeping_the_format_uses_retroarch_names
test_disable_to_an_extradot_format_renames_slots
test_shared_core_states_return_to_the_right_system
test_states_backups_are_never_pruned
test_failed_enable_rolls_back
test_interrupted_enable_is_recovered
test_interrupted_disable_is_recovered
test_core_saves_and_core_states_are_independent
test_states_follow_the_single_profile_owner
test_states_layer_plan_and_scope
test_menu_rows_follow_the_states_state
test_states_are_untouched_when_nothing_maps
echo "RetroArch Core States tests passed"
