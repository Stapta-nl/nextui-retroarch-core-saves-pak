#!/bin/sh

preflight_migration() {
	local table="$1"
	local files="$HOME_PATH/migration-files.$$"
	local tag core src

	while IFS='|' read -r tag core; do
		[ -n "$tag" ] && [ -n "$core" ] || continue
		src="$SAVES_PATH/$tag"
		[ -d "$src" ] || continue
		write_file_list "$src" "$files" || {
			rm -f "$files"
			ACTION_RESULT="Could not inspect /Saves/$tag."
			report_issue "$ACTION_RESULT"
			return 1
		}
	done < "$table"
	rm -f "$files"
}

# The name a migrated file gets, by kind. Saves are renamed for the save format
# in force; states by the name they already carry, since NextUI does not convert
# old states when its setting changes. Returns 1 for a file that is not of the
# kind (a state name that is not one), which is then copied unchanged.
migrate_target_name() {
	local kind="$1" base="$2" format="$3" ra

	case "$kind" in
		saves) core_target_name "$base" "$format" ;;
		states)
			state_split_sidecar "$base"
			if ra=$(state_to_retroarch "$STATE_BASE"); then
				echo "$ra$STATE_SIDE"
			else
				echo "$base"
				return 1
			fi
			;;
		*) return 1 ;;
	esac
}

# Copies the files of one NextUI folder ($2: /Saves/<tag> or a states folder)
# into its core folder ($3) under the names its kind ($1) uses. Nothing here
# removes the source, and a file already there with the same bytes is reused, so
# running it again changes nothing. Counts renamed and unrecognised states in
# STATES_CONVERTED and STATES_KEPT.
migrate_folder() {
	local kind="$1"
	local src="$2"
	local dst_root="$3"
	local format="$4"
	local tag="$5"
	local file rel rel_dir original_base base dst final mode files

	[ -d "$src" ] || {
		mkdir -p "$src"
		return
	}

	files="$HOME_PATH/migrate-$kind-$tag-files.$$"

	write_file_list "$src" "$files" || {
		rm -f "$files"
		ACTION_RESULT="Could not inspect ${src#"$SDCARD_PATH"}."
		return 1
	}

	while IFS= read -r file; do
		rel=${file#"$src"/}
		rel_dir=$(dirname "$rel")
		original_base=$(basename "$file")
		if base=$(migrate_target_name "$kind" "$original_base" "$format"); then
			if [ "$kind" = states ] && [ "$base" != "$original_base" ]; then
				STATES_CONVERTED=$((STATES_CONVERTED + 1))
			fi
		else
			base=$original_base
			STATES_KEPT=$((STATES_KEPT + 1))
			report_note "SKIPPED: $file is not a recognised $kind name; copied unchanged."
		fi

		if [ "$rel_dir" = "." ]; then
			dst="$dst_root/$base"
		else
			dst="$dst_root/$rel_dir/$base"
		fi

		mkdir -p "$(dirname "$dst")" || {
			rm -f "$files"
			return 1
		}

		mode=copy
		final=$(unique_path "$dst" "$file")

		# unique_path returns an existing path only when that file already holds
		# these exact bytes, so there is nothing left to copy.
		if [ ! -e "$final" ]; then
			if [ "$final" != "$dst" ]; then
				report_issue "Collision: $file was copied to $final. Review both $kind and choose the correct one."
			fi

			copy_save_file "$file" "$final" "$mode" || {
				rm -f "$files"
				report_issue "Could not copy $file to $final."
				return 1
			}
		fi

		[ "$base" = "$original_base" ] || [ "$kind" != states ] ||
			report_note "CONVERTED: $file -> $final"
		[ "$kind" != saves ] ||
			printf '%s|%s\n' "${final#"$CORES_PATH"/}" "$tag/$rel" >> "$MANIFEST"
	done < "$files"
	rm -f "$files"
}

migrate_tag() {
	migrate_folder saves "$SAVES_PATH/$1" "$CORES_PATH/$2" "$3" "$1"
}

# Enables Core Saves and, while the Core States setting is on, Core States with
# it: one backup, one journal, one rollback and one set of mounts for both.
enable_core_saves() {
	local format state_format tmp tmp_states backup tag emu core states_on
	local old_state_format states_backup set_format

	profiles_core_saves_allowed || return 1
	format=$(get_save_format)

	case "$format" in 0|1|2|3) ;; *) ACTION_RESULT="Unknown save format: $format"; return 1 ;; esac

	states_on=false
	state_format=""
	if core_states_wanted; then
		states_on=true
		state_format=$(get_state_format)
		case "$state_format" in 0|1|2|3|4) ;; *) ACTION_RESULT="Unknown state format: $state_format"; return 1 ;; esac
	fi

	STATES_CONVERTED=0
	STATES_KEPT=0
	start_report "Move or import saves$($states_on && echo ' and states') into /Saves/Cores$($states_on && echo ' and /States/Cores')"
	tmp="$HOME_PATH/mounts.new.$$"
	tmp_states="$HOME_PATH/states-mounts.new.$$"

	discover_mappings "$tmp" || {
		rm -f "$tmp"
		finish_report
		ACTION_RESULT="No emulator mappings were found.
Report: $REPORT_FILE"
		return 1
	}

	if $states_on; then
		derive_states_table "$tmp" "$tmp_states" || {
			rm -f "$tmp_states"
			# A setup that already carries states must not lose them quietly: with
			# no table the old mounts would come down and NextUI would stop seeing
			# its states. Refuse before anything changes.
			if states_active; then
				rm -f "$tmp"
				report_issue "No mapped emulator has a states folder (the emulators are gone or their launchers have no EMU_EXE), so the existing states setup was left exactly as it is."
				finish_report
				ACTION_RESULT="No mapped emulator has a states folder, so nothing was changed and your states are still mounted.
Report: $REPORT_FILE"
				return 1
			fi
			states_on=false
			report_note "Core States is on, but no mapped emulator has a states folder to move."
		}
	fi

	preflight_migration "$tmp" || {
		rm -f "$tmp" "$tmp_states"
		finish_report
		ACTION_RESULT="$ACTION_RESULT
Report: $REPORT_FILE"
		return 1
	}

	# Enabling again keeps remembering what the first run found: the format and
	# the backup holding the states from before Core States.
	old_state_format="$state_format"
	states_backup=""
	if $states_on && states_active; then
		old_state_format=$(enabled_value old_state_format)
		states_backup=$(enabled_value states_backup)
		case "$old_state_format" in 0|1|2|3|4) ;; *) old_state_format="$state_format" ;; esac
	fi

	begin_operation enable || {
		rm -f "$tmp" "$tmp_states"
		finish_report
		ACTION_RESULT="Could not initialize recoverable migration state.
Report: $REPORT_FILE"
		return 1
	}

	unmount_core_mounts || {
		rm -f "$tmp" "$tmp_states"
		report_issue "Could not unmount an existing save folder."
		finish_report
		abort_operation "Could not unmount an existing save folder.
Report: $REPORT_FILE"
		return 1
	}

	if $states_on; then
		states_targets_free "$tmp_states" || {
			rm -f "$tmp" "$tmp_states"
			report_issue "A NextUI states folder is still mounted."
			finish_report
			abort_operation "A NextUI states folder is still mounted.
Report: $REPORT_FILE"
			return 1
		}
	fi

	show_progress "Backing up saves..." 10
	if $states_on; then
		backup=$(make_backup enable "$tmp_states")
	else
		backup=$(make_backup enable)
	fi || {
		rm -f "$tmp" "$tmp_states"
		finish_report
		abort_operation "Could not back up the Saves folder.
Report: $REPORT_FILE"
		return 1
	}
	$states_on && [ -z "$states_backup" ] && states_backup="$backup"

	operation_phase backed-up "$backup" || {
		rm -f "$tmp" "$tmp_states"
		finish_report
		abort_operation "Could not record the save backup in the operation journal.
Report: $REPORT_FILE"
		return 1
	}

	create_core_folders "$tmp" || {
		rm -f "$tmp" "$tmp_states"
		finish_report
		abort_operation "Could not create the core save folders.
Report: $REPORT_FILE"
		return 1
	}
	if $states_on; then
		while IFS='|' read -r tag emu core; do
			[ -n "$tag" ] || continue
			mkdir -p "$STATES_CORES/$core" || {
				rm -f "$tmp" "$tmp_states"
				finish_report
				abort_operation "Could not create $STATES_CORES/$core.
Report: $REPORT_FILE"
				return 1
			}
		done < "$tmp_states"
	fi

	: > "$MANIFEST"
	operation_phase migrating || {
		rm -f "$tmp" "$tmp_states"
		finish_report
		abort_operation "Could not update the operation journal.
Report: $REPORT_FILE"
		return 1
	}

	show_progress "Moving saves into Cores..." 45

	while IFS='|' read -r tag core; do
		[ -n "$tag" ] && [ -n "$core" ] || continue
		migrate_tag "$tag" "$core" "$format" || {
			rm -f "$tmp" "$tmp_states"
			report_issue "Migration stopped while processing /Saves/$tag."
			finish_report
			abort_operation "Migration failed.
Report: $REPORT_FILE"
			return 1
		}
	done < "$tmp"

	if $states_on; then
		show_progress "Moving states into States/Cores..." 55
		while IFS='|' read -r tag emu core; do
			[ -n "$tag" ] || continue
			migrate_folder states "$(states_target "$tag" "$emu")" "$STATES_CORES/$core" "" "$tag-$emu" || {
				rm -f "$tmp" "$tmp_states"
				report_issue "States migration stopped while processing $tag-$emu."
				finish_report
				abort_operation "States migration failed.
Report: $REPORT_FILE"
				return 1
			}
		done < "$tmp_states"
	fi

	while IFS='|' read -r tag core; do
		[ -n "$tag" ] && [ -n "$core" ] || continue
		clear_mountpoint "$tag" || {
			rm -f "$tmp" "$tmp_states"
			report_issue "Could not empty /Saves/$tag for its bind mount."
			finish_report
			abort_operation "Could not prepare /Saves/$tag.
Report: $REPORT_FILE"
			return 1
		}
	done < "$tmp"

	if $states_on; then
		while IFS='|' read -r tag emu core; do
			[ -n "$tag" ] || continue
			clear_states_folder "$(states_target "$tag" "$emu")" || {
				rm -f "$tmp" "$tmp_states"
				report_issue "Could not empty the NextUI states folder $tag-$emu for its bind mount."
				finish_report
				abort_operation "Could not prepare the states folder $tag-$emu.
Report: $REPORT_FILE"
				return 1
			}
		done < "$tmp_states"
	fi

	if [ "$format" = 0 ] || [ "$format" = 2 ]; then
		set_save_format 3 || {
			report_issue "Could not set RetroArch uncompressed format."
			finish_report
			abort_operation "Could not set RetroArch uncompressed format.
Report: $REPORT_FILE"
			return 1
		}
	fi

	if $states_on; then
		# Formats 3 and 4 both use RetroArch's names, so a re-apply leaves a
		# format the user switched to (4, uncompressed) alone. It is set to 3 when
		# states are first enabled, or when the format is one that names files
		# differently.
		set_format=true
		if states_active; then
			case "$state_format" in 3|4) set_format=false ;; esac
		fi
		if $set_format; then
			set_state_format 3 || {
				report_issue "Could not set RetroArch (compressed) state format."
				finish_report
				abort_operation "Could not set the state format.
Report: $REPORT_FILE"
				return 1
			}
		fi
	fi

	mv "$tmp" "$MOUNT_TABLE" || {
		rm -f "$tmp_states"
		finish_report
		abort_operation "Could not install the new mount table.
Report: $REPORT_FILE"
		return 1
	}
	if $states_on; then
		mv "$tmp_states" "$STATES_TABLE" || {
			finish_report
			abort_operation "Could not install the new states mount table.
Report: $REPORT_FILE"
			return 1
		}
	else
		rm -f "$STATES_TABLE" "$tmp_states"
	fi

	{
		echo "backup=$backup"
		echo "old_format=$format"
		echo "enabled_at=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
		if $states_on; then
			echo "states=1"
			echo "old_state_format=$old_state_format"
			echo "states_backup=$states_backup"
		else
			echo "states=0"
		fi
	} > "$ENABLED_FILE" || {
		finish_report
		abort_operation "Could not record the enabled state.
Report: $REPORT_FILE"
		return 1
	}

	install_mount_layer || {
		report_issue "Could not install the mount layer: $MOUNT_ERROR"
		finish_report
		abort_operation "Could not install the Core Saves mount layer.
Report: $REPORT_FILE"
		return 1
	}

	operation_phase mounting || {
		finish_report
		abort_operation "Could not update the operation journal.
Report: $REPORT_FILE"
		return 1
	}

	show_progress "Mounting core save folders..." 80

	run_mounts || {
		report_issue "Saves were copied, but one or more bind mounts failed: $MOUNT_ERROR"
		finish_report
		abort_operation "One or more core save mounts failed.
Report: $REPORT_FILE"
		return 1
	}

	sync

	commit_operation || {
		finish_report
		abort_operation "Core saves were prepared, but the operation could not be committed.
Report: $REPORT_FILE"
		return 1
	}

	claim_profiles_core_saves_owner || {
		report_issue "Core Saves is active, but Profiles.pak could not record this profile as its owner."
		finish_report
		ACTION_RESULT="Core Saves is active, but Profiles ownership could not be recorded. Disable Core Saves before switching profiles.
Report: $REPORT_FILE"
		return 1
	}

	if $states_on; then
		report_note ""
		report_note "States: $STATES_CONVERTED renamed, $STATES_KEPT copied unchanged."
	fi
	finish_report
	ACTION_RESULT="Core saves are active.
Sync /Saves/Cores with SyncThing."
	if $states_on; then
		ACTION_RESULT="Core saves and states are active ($STATES_CONVERTED states renamed).
Sync /Saves/Cores and /States/Cores with SyncThing.
States only load in the same core at a compatible version."
	fi
	ACTION_RESULT="$ACTION_RESULT$(report_notice)"
}
