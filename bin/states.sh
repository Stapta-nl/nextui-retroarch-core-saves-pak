#!/bin/sh
# Core States: the save-state counterpart of Core Saves.
#
# NextUI keeps states in $SHARED_USERDATA_PATH/<TAG>-<core>, where <core> is the
# core's file name without _libretro (the pak's EMU_EXE), not the libretro
# library name that /Saves/Cores uses. Enabling moves them to
# $SDCARD_PATH/States/Cores/<library name>/ under RetroArch's own file names and
# bind-mounts that folder back (mountctl layer 30).
#
# The tree is deliberately not inside /Saves/Cores: restoring Core Saves copies
# every file in a core folder into /Saves/<tag>, and Core Saves rollback deletes
# and rewrites /Saves, which would pull the mount source out from under the
# states mounts.
#
# Only file names change. MinArch reads compressed and raw states alike and
# accepts RetroArch's RASTATE header, so no payload is rewritten, which keeps
# the conversion lossless and reversible.

STATES_LAYER=30-core-states
STATES_LAYER_FILE="$MOUNTS_HOME/layers.d/$STATES_LAYER.sh"
STATES_ROOT="$SDCARD_PATH/States"
STATES_CORES="$STATES_ROOT/Cores"
STATES_TABLE="$HOME_PATH/states-mounts.conf"
STATES_ENABLED_FILE="$HOME_PATH/states-enabled"
STATES_JOURNAL="$HOME_PATH/states-operation.journal"
STATES_STATE="$HOME_PATH/states-operation"
STATES_BACKUP_ROOT="$BACKUP_ROOT/core-states"

# --- the format setting --------------------------------------------------------

state_format_name() {
	case "$1" in
		0) echo "MinUI (.st0)" ;;
		1) echo "RetroArch-ish compressed (.state.0)" ;;
		2) echo "RetroArch-ish uncompressed (.state.0)" ;;
		3) echo "RetroArch compressed (.state)" ;;
		4) echo "RetroArch uncompressed (.state)" ;;
		*) echo "Unknown ($1)" ;;
	esac
}

get_state_format() {
	local value=""
	if [ -f "$SETTINGS_PATH" ]; then
		value=$(sed -n 's/^stateFormat=\([0-9][0-9]*\).*/\1/p' "$SETTINGS_PATH" | tail -n 1)
	fi
	echo "${value:-0}"
}

set_state_format() {
	local value="$1"
	local tmp="$SETTINGS_PATH.tmp.$$"
	mkdir -p "$(dirname "$SETTINGS_PATH")" || return 1
	if [ -f "$SETTINGS_PATH" ]; then
		if grep -q '^stateFormat=' "$SETTINGS_PATH"; then
			sed "s/^stateFormat=.*/stateFormat=$value/" "$SETTINGS_PATH" > "$tmp" || return 1
		else
			cp "$SETTINGS_PATH" "$tmp" || return 1
			echo "stateFormat=$value" >> "$tmp"
		fi
	else
		echo "stateFormat=$value" > "$tmp" || return 1
	fi
	mv "$tmp" "$SETTINGS_PATH"
}

# --- file names ---------------------------------------------------------------

# MinArch drops the last extension of the ROM name when it is 2 to 4 characters
# (strlen of ".ext" between 3 and 5). strip_short_ext, used for saves, accepts a
# single character too, so states get their own copy of MinArch's exact rule.
state_stem() {
	local name="$1" ext

	case "$name" in
		*.*)
			ext=${name##*.}
			if [ "${#ext}" -ge 2 ] && [ "${#ext}" -le 4 ]; then
				echo "${name%.*}"
				return
			fi
			;;
	esac
	echo "$name"
}

# A thumbnail RetroArch writes next to a state travels with it.
state_split_sidecar() {
	case "$1" in
		*.png) STATE_SIDE=.png; STATE_BASE=${1%.png} ;;
		*) STATE_SIDE=""; STATE_BASE=$1 ;;
	esac
}

# Prints the RetroArch name for a state file NextUI wrote in any of its formats,
# classified by the name itself because NextUI never converts old files when the
# setting changes. Returns 1 for a name that is not a state.
#   0 MinUI            Game.gba.st0..st9   (9 is the auto-resume slot)
#   1,2 RetroArch-ish  Game.state.0..N, Game.state.auto
#   3,4 RetroArch      Game.state, Game.stateN, Game.state.auto
state_to_retroarch() {
	local name="$1" base slot

	case "$name" in
		*.state.auto) echo "$name" ;;
		*.state.[0-9]|*.state.[0-9][0-9])
			base=${name%.state.*}
			slot=${name##*.state.}
			if [ "$slot" = 0 ]; then echo "$base.state"; else echo "$base.state$slot"; fi
			;;
		*.state|*.state[0-9]|*.state[0-9][0-9]) echo "$name" ;;
		*.st[0-9])
			slot=${name##*.st}
			base=$(state_stem "${name%.st[0-9]}")
			case "$slot" in
				9) echo "$base.state.auto" ;;
				0) echo "$base.state" ;;
				*) echo "$base.state$slot" ;;
			esac
			;;
		*) return 1 ;;
	esac
}

# The slot (0-9, 9 = auto) and stem of a RetroArch-named state.
state_slot_of() {
	case "$1" in
		*.state.auto) echo 9 ;;
		*.state) echo 0 ;;
		*.state[0-9]|*.state[0-9][0-9]) echo "${1##*.state}" ;;
		*) return 1 ;;
	esac
}

state_stem_of() {
	case "$1" in
		*.state.auto) echo "${1%.state.auto}" ;;
		*.state) echo "${1%.state}" ;;
		*.state[0-9]|*.state[0-9][0-9]) echo "${1%.state*}" ;;
		*) return 1 ;;
	esac
}

# RetroArch name -> the name format $2 expects. Format 0 also needs the ROM file
# name ($3), because the MinUI name keeps the extension that RetroArch's drops.
state_from_retroarch() {
	local name="$1" format="$2" rom="${3:-}" slot stem

	slot=$(state_slot_of "$name") || return 1
	stem=$(state_stem_of "$name") || return 1
	case "$format" in
		3|4) echo "$name" ;;
		1|2)
			case "$slot" in
				9) echo "$name" ;;
				*) echo "$stem.state.$slot" ;;
			esac
			;;
		0)
			[ -n "$rom" ] || return 1
			echo "$rom.st$slot"
			;;
		*) return 1 ;;
	esac
}

# --- discovery ----------------------------------------------------------------

# Writes tag|emu|core rows. The core folder comes from the same mapping Core
# Saves uses, but NextUI's states folder is named after EMU_EXE, which a
# mapping.conf override does not provide; a tag without one cannot be mounted.
discover_states_mappings() {
	local output="$1"
	local quiet="${2:-}"
	local map="$output.map"
	local launch tag emu core

	rm -f "$map"
	discover_mappings "$map" "$quiet" || {
		rm -f "$map"
		return 1
	}
	: > "$output" || return 1

	for launch in "$SDCARD_PATH/Emus/$PLATFORM"/*.pak/launch.sh "$SYSTEM_PATH/paks/Emus"/*.pak/launch.sh; do
		[ -f "$launch" ] || continue
		tag=$(basename "$(dirname "$launch")" .pak)
		awk -F'|' -v tag="$tag" '$1 == tag { found = 1 } END { exit !found }' "$output" && continue
		core=$(awk -F'|' -v tag="$tag" '$1 == tag { print $2; exit }' "$map")
		[ -n "$core" ] || continue
		emu=$(launch_emu_exe "$launch")
		if [ -z "$emu" ]; then
			[ -n "$quiet" ] ||
				report_issue "/Saves/$tag maps to $core by override, but its launcher has no EMU_EXE, so the NextUI states folder for $tag cannot be determined. Its states were left in place."
			continue
		fi
		printf '%s|%s|%s\n' "$tag" "$emu" "$core" >> "$output"
	done

	rm -f "$map"
	sort -t '|' -k1,1 "$output" > "$output.sorted" && mv "$output.sorted" "$output" || return 1
	[ -s "$output" ]
}

states_marker_value() {
	sed -n "s/^$1=//p" "$STATES_ENABLED_FILE" 2>/dev/null | head -n 1
}

states_target() { printf '%s\n' "$SHARED_USERDATA_PATH/$1-$2"; }

# Zero when none of the table's NextUI states folders is a mount point, which
# is the only state in which they may be emptied or filled.
states_targets_free() {
	local tag emu core

	while IFS='|' read -r tag emu core; do
		[ -n "$tag" ] && [ -n "$emu" ] || continue
		mc_is_mounted "$(states_target "$tag" "$emu")" && return 1
	done < "$1"
	return 0
}

states_mount_status() {
	local total=0 active=0 tag emu core

	if [ ! -f "$STATES_TABLE" ] || [ ! -f "$STATES_ENABLED_FILE" ]; then
		echo "Off"
		return
	fi
	while IFS='|' read -r tag emu core; do
		[ -n "$tag" ] && [ -n "$emu" ] && [ -n "$core" ] || continue
		total=$((total + 1))
		mc_matches "$STATES_CORES/$core" "$(states_target "$tag" "$emu")" &&
			active=$((active + 1))
	done < "$STATES_TABLE"
	echo "$active/$total mounted"
}

# Sets STATES_STALE: enabled, but a fresh discovery no longer matches the table.
compute_states_status() {
	local table="/tmp/${PAK_NAME}-states-check.conf"

	STATES_STALE=false
	[ -f "$STATES_ENABLED_FILE" ] || return 0
	rm -f "$table"
	discover_states_mappings "$table" quiet || :
	cmp -s "$table" "$STATES_TABLE" || STATES_STALE=true
	rm -f "$table"
}

# --- mount layer --------------------------------------------------------------

install_states_layer() {
	local stage="${TMPDIR:-/tmp}/${PAK_NAME}-states-layer.$$"
	local result rc

	rm -rf "$stage"
	mkdir -p "$stage" || return 1
	PIN="CORE_SAVES_HOME=$(mc_quote "$HOME_PATH")" awk '
		/^: "\$\{CORE_SAVES_HOME:=/ { print ENVIRON["PIN"]; pinned = 1; next }
		{ print }
		END { exit !pinned }' "$DIR/bin/mounts/$STATES_LAYER.sh" > "$stage/$STATES_LAYER.sh" || {
		rm -rf "$stage"
		MOUNT_ERROR="Could not prepare the states mount layer."
		return 1
	}
	result=$(mountctl_bundled install "$stage/$STATES_LAYER.sh" 2>> "$LOG_FILE")
	rc=$?
	rm -rf "$stage"
	[ "$rc" -eq 0 ] || {
		MOUNT_ERROR=${result:-"Could not install the states mount layer."}
		log "mountctl install failed: $MOUNT_ERROR"
		return 1
	}
}

# Like core_saves_enabled_anywhere: each profile has its own marker in its own
# shared data, and one layer serves them all.
core_states_enabled_anywhere() {
	local enabled
	[ -f "$STATES_ENABLED_FILE" ] && return 0
	for enabled in "$PROFILES_ROOT"/*/shared/"$PAK_NAME"/states-enabled; do
		[ -f "$enabled" ] && return 0
	done
	return 1
}

release_states_layer() {
	core_states_enabled_anywhere && return 0
	[ -f "$STATES_LAYER_FILE" ] || return 0
	run_mountctl remove "$STATES_LAYER"
}

unmount_states_mounts() {
	[ -f "$STATES_LAYER_FILE" ] || return 0
	run_mountctl down "$STATES_LAYER"
}

ensure_states_layer() {
	if core_states_enabled_anywhere; then
		install_states_layer
	else
		release_states_layer
	fi
}

run_states_mounts() {
	run_mountctl apply
}

# --- backup -------------------------------------------------------------------

# Backups of states live apart from the save backups and are never pruned: the
# user decides when they are no longer needed. $1 labels the backup; the rest
# are the folders to copy, stored under States/<folder name>.
make_states_backup() {
	local label="$1" ts backup incomplete n dir
	shift

	ts=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)
	backup="$STATES_BACKUP_ROOT/$ts-$label"
	n=0
	while [ -e "$backup" ]; do
		n=$((n + 1))
		backup="$STATES_BACKUP_ROOT/$ts-$label-$$-$n"
	done
	incomplete="$backup.incomplete"
	rm -rf "$incomplete"
	mkdir -p "$incomplete/States" || return 1
	for dir in "$@"; do
		[ -d "$dir" ] || continue
		mkdir -p "$incomplete/States/$(basename "$dir")" &&
			cp -a "$dir"/. "$incomplete/States/$(basename "$dir")"/ || {
			rm -rf "$incomplete"
			return 1
		}
	done
	if [ -f "$SETTINGS_PATH" ]; then
		cp -p "$SETTINGS_PATH" "$incomplete/minuisettings.txt" || { rm -rf "$incomplete"; return 1; }
	fi
	mv "$incomplete" "$backup" || { rm -rf "$incomplete"; return 1; }
	echo "$backup"
}

reclaim_incomplete_states_backups() {
	local backup
	for backup in "$STATES_BACKUP_ROOT"/*.incomplete; do
		[ -d "$backup" ] && rm -rf "$backup"
	done
	return 0
}

# --- the transaction journal --------------------------------------------------

states_journal_value() {
	sed -n "s/^$1=//p" "$STATES_JOURNAL" 2>/dev/null | head -n 1
}

write_states_journal() {
	local tmp="$STATES_JOURNAL.new.$$"
	{
		echo "operation=$STATES_OP"
		echo "phase=$STATES_PHASE"
		echo "backup=$STATES_BACKUP"
		echo "format=$STATES_FORMAT_BEFORE"
	} > "$tmp" || return 1
	mv "$tmp" "$STATES_JOURNAL" && sync
}

begin_states_operation() {
	local file
	[ ! -f "$STATES_JOURNAL" ] && [ ! -f "$OPERATION_JOURNAL" ] || {
		ACTION_RESULT="An interrupted operation must be recovered first."
		return 1
	}
	rm -rf "$STATES_STATE"
	mkdir -p "$STATES_STATE" || return 1
	: > "$STATES_STATE/copied" || return 1
	for file in "$STATES_ENABLED_FILE" "$STATES_TABLE"; do
		if [ -f "$file" ]; then
			cp -p "$file" "$STATES_STATE/$(basename "$file")" &&
				: > "$STATES_STATE/$(basename "$file").exists" || {
				rm -rf "$STATES_STATE"
				return 1
			}
		fi
	done
	STATES_OP="$1"
	STATES_PHASE=prepared
	STATES_BACKUP=""
	STATES_FORMAT_BEFORE=$(get_state_format)
	write_states_journal || { rm -rf "$STATES_STATE"; return 1; }
}

states_phase() {
	STATES_PHASE="$1"
	[ "$#" -lt 2 ] || STATES_BACKUP="$2"
	write_states_journal
}

commit_states_operation() {
	sync
	rm -f "$STATES_JOURNAL" || return 1
	rm -rf "$STATES_STATE"
	reclaim_incomplete_states_backups
}

restore_states_control_file() {
	local name="$1" destination="$2"
	if [ -f "$STATES_STATE/$name.exists" ]; then
		cp -p "$STATES_STATE/$name" "$destination"
	else
		rm -f "$destination"
	fi
}

# Rolls an interrupted or failed operation back. Enable puts the original
# folders back from the backup; disable removes the copies it made into them.
# States already in /States/Cores are never touched: they are the synced copy,
# and a leftover is identical to its source, so a later enable reuses it.
audit_states_operation() {
	local operation phase backup format tag emu core dir copied

	[ -f "$STATES_JOURNAL" ] || return 0
	operation=$(states_journal_value operation)
	phase=$(states_journal_value phase)
	backup=$(states_journal_value backup)
	format=$(states_journal_value format)
	case "$operation" in enable|disable) ;; *)
		ACTION_RESULT="The Core States journal is invalid. No automatic changes were made."
		return 1 ;;
	esac
	case "$phase" in
		prepared|backed-up|copying|clearing|installing|mounting|recovering-mounts) ;;
		*)
			ACTION_RESULT="The Core States journal has an invalid phase. No automatic changes were made."
			return 1 ;;
	esac
	[ -d "$STATES_STATE" ] || {
		ACTION_RESULT="The Core States recovery snapshot is missing. No automatic changes were made."
		return 1
	}
	if [ -n "$backup" ]; then
		case "$backup" in "$STATES_BACKUP_ROOT"/*) ;; *)
			ACTION_RESULT="The Core States journal has an invalid backup path. No automatic changes were made."
			return 1 ;;
		esac
		[ -d "$backup/States" ] || {
			ACTION_RESULT="The Core States backup is missing. No automatic changes were made."
			return 1
		}
	fi

	if [ "$phase" != recovering-mounts ]; then
		show_progress "Recovering interrupted Core States operation..." 10
		unmount_states_mounts || {
			ACTION_RESULT="Could not unmount the states folders during recovery. Reopen the pak to retry."
			return 1
		}
		# The table that was live while the operation ran decides what to undo.
		if [ -f "$STATES_TABLE" ]; then
			states_targets_free "$STATES_TABLE" || {
				ACTION_RESULT="A states folder is still mounted. Reopen the pak to retry recovery."
				return 1
			}
		fi

		if [ "$operation" = enable ] && [ -n "$backup" ]; then
			for dir in "$backup/States"/*; do
				[ -d "$dir" ] || continue
				mkdir -p "$SHARED_USERDATA_PATH/$(basename "$dir")" &&
					cp -a "$dir"/. "$SHARED_USERDATA_PATH/$(basename "$dir")"/ || {
					ACTION_RESULT="Could not restore the original states folders. Reopen the pak to retry."
					return 1
				}
			done
		elif [ "$operation" = disable ]; then
			copied="$STATES_STATE/copied"
			while IFS= read -r dir; do
				case "$dir" in "$SHARED_USERDATA_PATH"/*) rm -f "$dir" ;; esac
			done < "$copied"
		fi

		[ -z "$format" ] || set_state_format "$format" || {
			ACTION_RESULT="Could not restore the state format. Reopen the pak to retry."
			return 1
		}
		restore_states_control_file states-enabled "$STATES_ENABLED_FILE" &&
			restore_states_control_file states-mounts.conf "$STATES_TABLE" || {
			ACTION_RESULT="Could not restore the Core States configuration. Reopen the pak to retry."
			return 1
		}
		STATES_OP="$operation"
		STATES_PHASE=recovering-mounts
		STATES_BACKUP="$backup"
		STATES_FORMAT_BEFORE="$format"
		write_states_journal || {
			ACTION_RESULT="States were recovered, but the recovery checkpoint could not be recorded. Reopen the pak to retry."
			return 1
		}
	else
		show_progress "Retrying previous states mounts..." 80
	fi

	if [ -f "$STATES_STATE/states-enabled.exists" ]; then
		install_states_layer && run_states_mounts || {
			ACTION_RESULT="States were recovered, but the previous mounts could not be restored. Reopen the pak to retry."
			return 1
		}
	else
		release_states_layer || :
	fi
	report_note "RECOVERY: Rolled back interrupted Core States $operation operation."
	rm -f "$STATES_JOURNAL"
	rm -rf "$STATES_STATE"
	reclaim_incomplete_states_backups
	sync
	ACTION_RESULT="Recovered an interrupted Core States $operation operation.
The previous states layout and format setting were restored."
}

abort_states_operation() {
	local reason="$1" recovery_result

	if audit_states_operation; then
		recovery_result="$ACTION_RESULT"
		ACTION_RESULT="$reason
$recovery_result"
	else
		ACTION_RESULT="$reason
Automatic rollback could not finish. Reopen the pak to retry recovery.
$ACTION_RESULT"
	fi
	return 1
}

# --- enable -------------------------------------------------------------------

# Copies one NextUI states folder into its core folder under RetroArch names.
# Sets STATES_CONVERTED, STATES_KEPT. A name that is not a state is copied as it
# is, since the folder is about to be hidden under a mount.
migrate_states_folder() {
	local src="$1" core="$2"
	local dst_root="$STATES_CORES/$core"
	local files="$HOME_PATH/states-files.$$"
	local file rel rel_dir name ra final final_name dst

	find "$src" -type f > "$files" 2>/dev/null || { rm -f "$files"; return 1; }
	while IFS= read -r file; do
		[ -n "$file" ] || continue
		rel=${file#"$src"/}
		rel_dir=$(dirname "$rel")
		name=$(basename "$file")
		state_split_sidecar "$name"
		if ra=$(state_to_retroarch "$STATE_BASE"); then
			final_name="$ra$STATE_SIDE"
			if [ "$final_name" != "$name" ]; then STATES_CONVERTED=$((STATES_CONVERTED + 1)); fi
		else
			final_name="$name"
			STATES_KEPT=$((STATES_KEPT + 1))
			report_note "SKIPPED: $file is not a recognised state name; copied unchanged."
		fi
		if [ "$rel_dir" = "." ]; then dst="$dst_root/$final_name"; else dst="$dst_root/$rel_dir/$final_name"; fi
		mkdir -p "$(dirname "$dst")" || { rm -f "$files"; return 1; }
		final=$(unique_path "$dst" "$file")
		if [ ! -e "$final" ]; then
			[ "$final" = "$dst" ] ||
				report_issue "Collision: $file was copied to $final. Review both states and choose the correct one."
			cp -p "$file" "$final" || {
				rm -f "$final" "$files"
				report_issue "Could not copy $file to $final."
				STATES_FAILED=$((STATES_FAILED + 1))
				return 1
			}
		fi
		[ "$final_name" = "$name" ] || report_note "CONVERTED: $file -> $final"
	done < "$files"
	rm -f "$files"
}

clear_states_folder() {
	local path="$1"

	[ -n "$path" ] || return 1
	case "$path" in "$SHARED_USERDATA_PATH"/?*) ;; *) return 1 ;; esac
	mc_is_mounted "$path" && return 1
	[ -d "$path" ] || { mkdir -p "$path"; return; }
	rm -rf "$path"/* "$path"/.[!.]* "$path"/..?*
}

enable_core_states() {
	local current old_format was_enabled tmp backup tag emu core src first_backup first_at has_files

	profiles_core_saves_allowed || return 1
	current=$(get_state_format)
	case "$current" in 0|1|2|3|4) ;; *) ACTION_RESULT="Unknown state format: $current"; return 1 ;; esac

	STATES_CONVERTED=0
	STATES_KEPT=0
	STATES_FAILED=0
	start_report "Move or import save states into /States/Cores"
	tmp="$HOME_PATH/states-mounts.new.$$"
	discover_states_mappings "$tmp" || {
		rm -f "$tmp"
		finish_report
		ACTION_RESULT="No emulator mappings with a states folder were found.
Report: $REPORT_FILE"
		return 1
	}

	was_enabled=false
	[ -f "$STATES_ENABLED_FILE" ] && was_enabled=true
	# Enabling again must keep remembering the format from before the first run;
	# the current value is already the one this feature set.
	if $was_enabled; then
		old_format=$(states_marker_value old_format)
		first_backup=$(states_marker_value backup)
		first_at=$(states_marker_value enabled_at)
	else
		old_format="$current"
		first_backup=""
		first_at=""
	fi
	case "$old_format" in 0|1|2|3|4) ;; *) old_format="$current" ;; esac

	begin_states_operation enable || {
		rm -f "$tmp"
		finish_report
		[ -n "$ACTION_RESULT" ] || ACTION_RESULT="Could not initialize recoverable Core States state."
		return 1
	}

	unmount_states_mounts || {
		rm -f "$tmp"
		report_issue "Could not unmount an existing states folder."
		finish_report
		abort_states_operation "Could not unmount an existing states folder.
Report: $REPORT_FILE"
		return 1
	}
	states_targets_free "$tmp" && { [ ! -f "$STATES_TABLE" ] || states_targets_free "$STATES_TABLE"; } || {
		rm -f "$tmp"
		report_issue "A NextUI states folder is still mounted."
		finish_report
		abort_states_operation "A NextUI states folder is still mounted.
Report: $REPORT_FILE"
		return 1
	}

	# A re-apply with nothing new to move needs no new backup.
	has_files=false
	while IFS='|' read -r tag emu core; do
		[ -n "$tag" ] || continue
		src=$(states_target "$tag" "$emu")
		[ -d "$src" ] && [ -n "$(find "$src" -type f -print -quit 2>/dev/null)" ] && has_files=true
	done < "$tmp"

	backup=""
	if ! $was_enabled || $has_files; then
		show_progress "Backing up states..." 10
		set --
		while IFS='|' read -r tag emu core; do
			[ -n "$tag" ] || continue
			set -- "$@" "$(states_target "$tag" "$emu")"
		done < "$tmp"
		backup=$(make_states_backup enable "$@") || {
			rm -f "$tmp"
			finish_report
			abort_states_operation "Could not back up the states folders.
Report: $REPORT_FILE"
			return 1
		}
		states_phase backed-up "$backup" || {
			rm -f "$tmp"
			finish_report
			abort_states_operation "Could not record the states backup in the journal.
Report: $REPORT_FILE"
			return 1
		}
		report_note "Backup: $backup"
	fi

	states_phase copying "$backup"
	show_progress "Moving states into /States/Cores..." 40
	while IFS='|' read -r tag emu core; do
		[ -n "$tag" ] || continue
		mkdir -p "$STATES_CORES/$core" || {
			rm -f "$tmp"
			finish_report
			abort_states_operation "Could not create $STATES_CORES/$core.
Report: $REPORT_FILE"
			return 1
		}
		src=$(states_target "$tag" "$emu")
		[ -d "$src" ] || { mkdir -p "$src"; continue; }
		migrate_states_folder "$src" "$core" || {
			rm -f "$tmp"
			report_issue "States migration stopped while processing $src."
			finish_report
			abort_states_operation "States migration failed.
Report: $REPORT_FILE"
			return 1
		}
	done < "$tmp"

	states_phase clearing "$backup"
	while IFS='|' read -r tag emu core; do
		[ -n "$tag" ] || continue
		clear_states_folder "$(states_target "$tag" "$emu")" || {
			rm -f "$tmp"
			report_issue "Could not empty the NextUI states folder for $tag-$emu."
			finish_report
			abort_states_operation "Could not prepare the states folder for $tag-$emu.
Report: $REPORT_FILE"
			return 1
		}
	done < "$tmp"

	states_phase installing "$backup"
	set_state_format 3 || {
		rm -f "$tmp"
		report_issue "Could not set RetroArch (compressed) state format."
		finish_report
		abort_states_operation "Could not set the state format.
Report: $REPORT_FILE"
		return 1
	}
	if [ -f "$STATES_TABLE" ]; then
		while IFS='|' read -r tag emu core; do
			[ -n "$tag" ] || continue
			awk -F'|' -v tag="$tag" -v emu="$emu" '$1 == tag && $2 == emu { found = 1 } END { exit !found }' "$tmp" ||
				report_note "DROPPED: $tag-$emu no longer has an installed emulator; its states stay in /States/Cores/$core."
		done < "$STATES_TABLE"
	fi
	mv "$tmp" "$STATES_TABLE" || {
		finish_report
		abort_states_operation "Could not install the new states mount table.
Report: $REPORT_FILE"
		return 1
	}
	{
		echo "backup=${first_backup:-$backup}"
		echo "old_format=$old_format"
		echo "enabled_at=${first_at:-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)}"
	} > "$STATES_ENABLED_FILE" || {
		finish_report
		abort_states_operation "Could not record the enabled state.
Report: $REPORT_FILE"
		return 1
	}
	install_states_layer || {
		report_issue "Could not install the states mount layer: $MOUNT_ERROR"
		finish_report
		abort_states_operation "Could not install the Core States mount layer.
Report: $REPORT_FILE"
		return 1
	}

	states_phase mounting "$backup"
	show_progress "Mounting states folders..." 80
	run_states_mounts || {
		report_issue "States were copied, but one or more bind mounts failed: $MOUNT_ERROR"
		finish_report
		abort_states_operation "One or more states mounts failed.
Report: $REPORT_FILE"
		return 1
	}
	sync
	commit_states_operation || {
		finish_report
		abort_states_operation "States were prepared, but the operation could not be committed.
Report: $REPORT_FILE"
		return 1
	}
	claim_profiles_core_saves_owner || {
		report_issue "Core States is active, but Profiles.pak could not record this profile as its owner."
		finish_report
		ACTION_RESULT="Core States is active, but Profiles ownership could not be recorded. Disable Core States before switching profiles.
Report: $REPORT_FILE"
		return 1
	}
	report_note ""
	report_note "Summary: $STATES_CONVERTED renamed, $STATES_KEPT copied unchanged, $STATES_FAILED failed."
	finish_report
	ACTION_RESULT="Core States are active ($STATES_CONVERTED renamed, $STATES_KEPT unchanged).
Sync /States/Cores with SyncThing.
States only load in the same core at a compatible version.$(report_notice)"
}

# --- disable ------------------------------------------------------------------

# Builds tag|stem|rom|kind rows for the ROMs of every tag in the states table.
build_states_rom_index() {
	local table="$1" output="$2"
	local roms="$output.roms" raw="$output.raw"
	local tag emu core rom base stem archive

	: > "$raw" || return 1
	find "$ROMS_PATH" -type f > "$roms" 2>/dev/null || :
	while IFS='|' read -r tag emu core; do
		[ -n "$tag" ] || continue
		while IFS= read -r rom; do
			case "$rom" in
				"$ROMS_PATH"/*"($tag)"/*)
					base=$(basename "$rom")
					stem=$(state_stem "$base")
					printf '%s|%s|%s|direct\n' "$tag" "$stem" "$base" >> "$raw"
					case "$base" in
						*.[zZ][iI][pP])
							archive=$(state_stem "$stem")
							[ "$archive" = "$stem" ] ||
								printf '%s|%s|%s|archive\n' "$tag" "$archive" "$base" >> "$raw"
							;;
					esac
					;;
			esac
		done < "$roms"
	done < "$table"
	sort -u "$raw" > "$output"
	rm -f "$roms" "$raw"
}

# Prints the tag a state in a core folder belongs to. A core with one tag needs
# no ROM; a shared core needs exactly one tag whose ROMs have this stem.
# Returns 1 for no match and 2 for several.
states_tag_for() {
	local core="$1" stem="$2" table="$3" index="$4"
	local tags count matches

	tags=$(awk -F'|' -v core="$core" '$3 == core { print $1 }' "$table" | sort -u)
	count=$(printf '%s\n' "$tags" | grep -c .)
	if [ "$count" = 1 ]; then
		printf '%s\n' "$tags"
		return 0
	fi
	matches=$(awk -F'|' -v stem="$stem" -v tags="$tags" '
		BEGIN { n = split(tags, list, "\n"); for (i = 1; i <= n; i++) allowed[list[i]] = 1 }
		$2 == stem && ($1 in allowed) { print $1 }' "$index" | sort -u)
	[ -n "$matches" ] || return 1
	[ "$(printf '%s\n' "$matches" | grep -c .)" = 1 ] || return 2
	printf '%s\n' "$matches"
}

# $1 = restore | keep: whether to put the format recorded at enable time back.
disable_core_states() {
	local choice="$1"
	local old_format current target_format backup index
	local tag emu core src file name base ra stem target_name rom dst final rel_dir
	local restored=0 unresolved=0 dirs

	profiles_core_saves_allowed || return 1
	[ -f "$STATES_ENABLED_FILE" ] || {
		ACTION_RESULT="Core States are not active."
		return 1
	}
	current=$(get_state_format)
	case "$current" in 0|1|2|3|4) ;; *) current=3 ;; esac
	old_format=$(states_marker_value old_format)
	case "$old_format" in 0|1|2|3|4) ;; *) old_format="$current" ;; esac
	if [ "$choice" = restore ]; then target_format="$old_format"; else target_format="$current"; fi

	start_report "Restore save states to NextUI folders as $(state_format_name "$target_format")"
	STATES_FAILED=0
	index="$HOME_PATH/states-roms.$$"
	build_states_rom_index "$STATES_TABLE" "$index" || {
		rm -f "$index"
		finish_report
		ACTION_RESULT="Could not index the ROMs.
Report: $REPORT_FILE"
		return 1
	}

	begin_states_operation disable || {
		rm -f "$index"
		finish_report
		[ -n "$ACTION_RESULT" ] || ACTION_RESULT="Could not initialize recoverable Core States state."
		return 1
	}
	unmount_states_mounts || {
		rm -f "$index"
		report_issue "Could not unmount the states folders."
		finish_report
		abort_states_operation "Could not unmount the states folders.
Report: $REPORT_FILE"
		return 1
	}
	states_targets_free "$STATES_TABLE" || {
		rm -f "$index"
		finish_report
		abort_states_operation "A NextUI states folder is still mounted.
Report: $REPORT_FILE"
		return 1
	}

	show_progress "Backing up states..." 20
	set --
	while IFS='|' read -r tag emu core; do
		[ -n "$tag" ] || continue
		set -- "$@" "$STATES_CORES/$core"
	done < "$STATES_TABLE"
	backup=$(make_states_backup disable "$@") || {
		rm -f "$index"
		finish_report
		abort_states_operation "Could not back up the states.
Report: $REPORT_FILE"
		return 1
	}
	states_phase backed-up "$backup" || {
		rm -f "$index"
		finish_report
		abort_states_operation "Could not record the states backup in the journal.
Report: $REPORT_FILE"
		return 1
	}
	report_note "Backup: $backup"

	states_phase copying "$backup"
	show_progress "Restoring states folders..." 50
	dirs="$HOME_PATH/states-dirs.$$"
	awk -F'|' 'NF >= 3 && !seen[$3]++ { print $3 }' "$STATES_TABLE" > "$dirs"
	while IFS= read -r core; do
		[ -n "$core" ] && [ -d "$STATES_CORES/$core" ] || continue
		find "$STATES_CORES/$core" -type f > "$dirs.files"
		while IFS= read -r file; do
			[ -n "$file" ] || continue
			rel_dir=$(dirname "${file#"$STATES_CORES/$core"/}")
			name=$(basename "$file")
			state_split_sidecar "$name"
			if ! stem=$(state_stem_of "$STATE_BASE"); then
				report_issue "Left in /States/Cores/$core: $file is not a state file name."
				unresolved=$((unresolved + 1))
				continue
			fi
			stem=${stem%.core-conflict-[0-9]*}
			tag=$(states_tag_for "$core" "$stem" "$STATES_TABLE" "$index")
			case $? in
				0) ;;
				1)
					report_issue "Unmatched shared-core state left in place: $file"
					unresolved=$((unresolved + 1))
					continue ;;
				*)
					report_issue "Ambiguous shared-core state left in place: $file"
					unresolved=$((unresolved + 1))
					continue ;;
			esac
			emu=$(awk -F'|' -v tag="$tag" -v core="$core" '$1 == tag && $3 == core { print $2; exit }' "$STATES_TABLE")
			rom=""
			if [ "$target_format" = 0 ]; then
				rom=$(awk -F'|' -v tag="$tag" -v stem="$stem" '$1 == tag && $2 == stem && $4 == "direct" { print $3 }' "$index")
				if [ -z "$rom" ] || [ "$(printf '%s\n' "$rom" | grep -c .)" != 1 ]; then
					report_issue "No single matching ROM to name a MinUI state; left in place: $file"
					unresolved=$((unresolved + 1))
					continue
				fi
			fi
			target_name=$(state_from_retroarch "$STATE_BASE" "$target_format" "$rom") || {
				report_issue "Left in /States/Cores/$core: $file cannot be named for $(state_format_name "$target_format")."
				unresolved=$((unresolved + 1))
				continue
			}
			target_name="$target_name$STATE_SIDE"
			src=$(states_target "$tag" "$emu")
			if [ "$rel_dir" = "." ]; then dst="$src/$target_name"; else dst="$src/$rel_dir/$target_name"; fi
			mkdir -p "$(dirname "$dst")" || { rm -f "$index" "$dirs" "$dirs.files"; return 1; }
			final=$(unique_path "$dst" "$file")
			if [ ! -e "$final" ]; then
				[ "$final" = "$dst" ] ||
					report_issue "Collision: $file was restored to $final. Review both states and choose the correct one."
				printf '%s\n' "$final" >> "$STATES_STATE/copied"
				cp -p "$file" "$final" || {
					rm -f "$index" "$dirs" "$dirs.files"
					report_issue "Could not copy $file to $final."
					finish_report
					abort_states_operation "Could not restore one or more states.
Report: $REPORT_FILE"
					return 1
				}
			fi
			report_note "RESTORED: $file -> $final"
			restored=$((restored + 1))
		done < "$dirs.files"
	done < "$dirs"
	rm -f "$index" "$dirs" "$dirs.files"

	states_phase installing "$backup"
	if [ "$choice" = restore ]; then
		set_state_format "$target_format" || {
			report_issue "Could not restore the state format."
			finish_report
			abort_states_operation "Could not restore the state format.
Report: $REPORT_FILE"
			return 1
		}
	fi
	rm -f "$STATES_ENABLED_FILE" "$STATES_TABLE"
	release_states_layer ||
		report_note "The states mount layer could not be removed yet: $MOUNT_ERROR"
	sync
	commit_states_operation || {
		finish_report
		abort_states_operation "States were restored, but the operation could not be committed.
Report: $REPORT_FILE"
		return 1
	}
	report_note ""
	report_note "Summary: $restored restored, $unresolved left in /States/Cores."
	finish_report
	ACTION_RESULT="States now use $(state_format_name "$target_format") in the NextUI folders.
$restored restored; $unresolved left in /States/Cores"
	if [ "$unresolved" -gt 0 ] && [ "$choice" = restore ]; then
		ACTION_RESULT="$ACTION_RESULT
Those $unresolved states will not load in NextUI until renamed."
	fi
	ACTION_RESULT="$ACTION_RESULT
Backup: $backup
Report: $REPORT_FILE"
}
