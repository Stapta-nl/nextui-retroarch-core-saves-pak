#!/bin/sh
# Core States: the save-state side of the Core Saves transaction.
#
# NextUI keeps states in $SHARED_USERDATA_PATH/<TAG>-<core>, where <core> is the
# core's file name without _libretro (the pak's EMU_EXE), not the libretro
# library name that /Saves/Cores uses. Core Saves' enable and revert operations
# handle them in the same loop as saves, when the Core States setting is on:
# states move to $SDCARD_PATH/States/Cores/<library name>/ under RetroArch's
# file names and mountctl's layer 20 mounts that folder back over each NextUI
# folder. This file holds what is specific to states: file names, the format
# setting, the table, and matching restored states to systems.
#
# The tree is deliberately not inside /Saves/Cores: restoring Core Saves copies
# every file in a core folder into /Saves/<tag>, and Core Saves rollback deletes
# and rewrites /Saves, which would pull the mount source out from under the
# states mounts.
#
# Only file names change. MinArch reads compressed and raw states alike and
# accepts RetroArch's RASTATE header, so no payload is rewritten, which keeps
# the conversion lossless and reversible.

STATES_ROOT="$SDCARD_PATH/States"
STATES_CORES="$STATES_ROOT/Cores"
STATES_TABLE="$HOME_PATH/states-mounts.conf"
FEATURES_FILE="$HOME_PATH/features.conf"

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
	# NextUI reads manual slots 0 to 7, its hidden default in 8 and the
	# auto-resume state, which is slot 9 and only ever named .state.auto. A
	# desktop RetroArch slot of 9 or more has no NextUI name in formats 0 to 2:
	# .st9 or .state.auto would collide with the auto-resume state, and .st10 or
	# .state.10 is never read. Those stay in /States/Cores. Formats 3 and 4 use
	# RetroArch's names as they are.
	case "$format:$name" in
		[012]:*.state.auto) ;;
		[012]:*) [ "$slot" -le 8 ] || return 1 ;;
	esac
	case "$format" in
		3|4) echo "$name" ;;
		1|2)
			case "$name" in
				*.state.auto) echo "$name" ;;
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

# --- the setting and the state of the feature -----------------------------------

# Whether the next conversion includes states. On by default. The menu row that
# changes it is locked only while a setup with states is running, so such a
# setup is only ever changed by reverting and converting again; a setup without
# states can switch it on and Re-apply.
core_states_setting() {
	local value
	value=$(sed -n 's/^core_states=//p' "$FEATURES_FILE" 2>/dev/null | tail -n 1)
	case "$value" in off) echo off ;; *) echo on ;; esac
}

set_core_states_setting() {
	local tmp="$FEATURES_FILE.tmp.$$"
	mkdir -p "$(dirname "$FEATURES_FILE")" || return 1
	{
		[ ! -f "$FEATURES_FILE" ] || grep -v '^core_states=' "$FEATURES_FILE"
		echo "core_states=$1"
	} > "$tmp" || return 1
	mv "$tmp" "$FEATURES_FILE"
}

enabled_value() {
	sed -n "s/^$1=//p" "$ENABLED_FILE" 2>/dev/null | head -n 1
}

# True while Core Saves is enabled with states in it.
states_active() {
	[ -f "$ENABLED_FILE" ] && [ "$(enabled_value states)" = 1 ]
}

# What the next enable or re-apply should do about states. A running setup
# that already carries them keeps them; otherwise the setting decides, which
# also lets an install from before Core States opt in with Re-apply.
core_states_wanted() {
	states_active && return 0
	[ "$(core_states_setting)" = on ]
}

# --- the table -----------------------------------------------------------------

# Writes tag|emu|core rows, from the saves table ($1, tag|core) plus each pak's
# EMU_EXE. The core folder is the library name Core Saves already resolved, but
# NextUI names its states folder after EMU_EXE, which a mapping.conf override does
# not provide; a tag without one cannot be mounted. Pass "quiet" as $3 to leave
# the conversion report alone.
derive_states_table() {
	local savestable="$1"
	local output="$2"
	local quiet="${3:-}"
	local launch tag emu core

	: > "$output" || return 1
	for launch in "$SDCARD_PATH/Emus/$PLATFORM"/*.pak/launch.sh "$SYSTEM_PATH/paks/Emus"/*.pak/launch.sh; do
		[ -f "$launch" ] || continue
		tag=$(basename "$(dirname "$launch")" .pak)
		awk -F'|' -v tag="$tag" '$1 == tag { found = 1 } END { exit !found }' "$output" && continue
		core=$(awk -F'|' -v tag="$tag" '$1 == tag { print $2; exit }' "$savestable")
		[ -n "$core" ] || continue
		emu=$(launch_emu_exe "$launch")
		if [ -z "$emu" ]; then
			[ -n "$quiet" ] ||
				report_issue "/Saves/$tag maps to $core by override, but its launcher has no EMU_EXE, so the NextUI states folder for $tag cannot be determined. Its states were left in place."
			continue
		fi
		printf '%s|%s|%s\n' "$tag" "$emu" "$core" >> "$output"
	done
	sort -t '|' -k1,1 "$output" > "$output.sorted" && mv "$output.sorted" "$output" || return 1
	[ -s "$output" ]
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

	if ! states_active || [ ! -f "$STATES_TABLE" ]; then
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

# Empties a NextUI states folder so a mount can take its place. Refuses while it
# is mounted: that would empty the synced tree instead.
clear_states_folder() {
	local path="$1"

	[ -n "$path" ] || return 1
	case "$path" in "$SHARED_USERDATA_PATH"/?*) ;; *) return 1 ;; esac
	mc_is_mounted "$path" && return 1
	[ -d "$path" ] || { mkdir -p "$path"; return; }
	rm -rf "$path"/* "$path"/.[!.]* "$path"/..?*
}

# Puts back the NextUI folders a backup holds (States/<tag>-<core> in it).
restore_states_from_backup() {
	local backup="$1" dir target

	for dir in "$backup/States"/*; do
		[ -d "$dir" ] || continue
		target="$SHARED_USERDATA_PATH/$(basename "$dir")"
		clear_states_folder "$target" || return 1
		cp -a "$dir"/. "$target"/ || return 1
	done
	return 0
}

# --- restoring -----------------------------------------------------------------

# Builds tag|stem|rom|kind rows for the ROMs of every tag in the states table,
# in one pass over the ROM list. A ROM belongs to a tag when "(<tag>)/" appears
# in its path below Roms, as in "Game Boy (GB)/". Stems follow MinArch's rule
# (state_stem: drop the last extension when it is 2 to 4 characters), and a zip
# also yields the stem of its inner name as an "archive" row.
build_states_rom_index() {
	local table="$1" output="$2"

	: > "$output" || return 1
	find "$ROMS_PATH" -type f 2>/dev/null |
		ROMS="$ROMS_PATH" awk '
			function stem_of(name,   n, parts, ext) {
				n = split(name, parts, ".")
				ext = parts[n]
				if (n >= 2 && length(ext) >= 2 && length(ext) <= 4)
					return substr(name, 1, length(name) - length(ext) - 1)
				return name
			}
			NR == FNR { split($0, f, "|"); if (f[1] != "") tags[f[1]] = 1; next }
			{
				rest = substr($0, length(ENVIRON["ROMS"]) + 2)
				base = $0
				sub(/.*\//, "", base)
				stem = stem_of(base)
				for (tag in tags) {
					if (index(rest, "(" tag ")/") == 0) continue
					print tag "|" stem "|" base "|direct"
					if (base ~ /\.[zZ][iI][pP]$/) {
						archive = stem_of(stem)
						if (archive != stem) print tag "|" archive "|" base "|archive"
					}
				}
			}' "$table" - | LC_ALL=C sort -u > "$output"
}

# Whether restoring needs the ROM index: naming for the MinUI format uses the
# ROM's own name, and a core shared by several systems needs a ROM to tell which
# system a state belongs to. Otherwise the ROM folders are never walked.
states_restore_needs_roms() {
	local target_format="$1"

	[ "$target_format" = 0 ] && return 0
	awk -F'|' 'NF >= 3 { count[$3]++ } END { for (core in count) if (count[core] > 1) exit 0; exit 1 }' "$STATES_TABLE"
}

# Prints the tag a state in a core folder belongs to. A core with one tag needs
# no ROM; a shared core needs exactly one tag whose ROMs have this stem.
# Returns 1 for no match and 2 for several.
states_tag_for() {
	local core="$1" stem="$2" table="$3" index="$4"
	local found count tags matches

	# Tags are joined with "|", which cannot occur in one (the table is "|"
	# separated), and handed to awk through the environment: a newline-separated
	# list through -v is not portable to busybox or BWK awk.
	found=$(awk -F'|' -v core="$core" '
		$3 == core && !seen[$1]++ { list = list "|" $1; n++ }
		END { print n + 0 " " list "|" }' "$table")
	count=${found%% *}
	tags=${found#* }
	if [ "$count" = 1 ]; then
		tags=${tags#|}
		printf '%s\n' "${tags%|}"
		return 0
	fi
	matches=$(STEM="$stem" TAGS="$tags" awk -F'|' '
		$2 == ENVIRON["STEM"] && index(ENVIRON["TAGS"], "|" $1 "|") { print $1 }' "$index" | sort -u)
	[ -n "$matches" ] || return 1
	[ "$(printf '%s\n' "$matches" | grep -c .)" = 1 ] || return 2
	printf '%s\n' "$matches"
}

# Plans putting the synced states back into the NextUI folders under the names
# format $1 expects. Writes file<TAB>tag-emu<TAB>relative new name rows to $2;
# whatever cannot be placed or named stays in /States/Cores and is reported.
# Sets STATES_RESTORE_MATCHED and STATES_RESTORE_UNRESOLVED.
build_states_restore_plan() {
	local target_format="$1" plan="$2" index="$3"
	local dirs="$plan.dirs" files="$plan.files"
	local core file name rel_dir tag emu stem rom target_name rc

	STATES_RESTORE_MATCHED=0
	STATES_RESTORE_UNRESOLVED=0
	: > "$plan" || return 1
	# The ROM index is only built when a state needs it.
	STATES_INDEX_BUILT=0
	: > "$index" || return 1
	if states_restore_needs_roms "$target_format"; then
		build_states_rom_index "$STATES_TABLE" "$index" || return 1
		STATES_INDEX_BUILT=1
	fi
	awk -F'|' 'NF >= 3 && !seen[$3]++ { print $3 }' "$STATES_TABLE" > "$dirs"
	while IFS= read -r core; do
		[ -n "$core" ] && [ -d "$STATES_CORES/$core" ] || continue
		find "$STATES_CORES/$core" -type f > "$files"
		while IFS= read -r file; do
			[ -n "$file" ] || continue
			rel_dir=$(dirname "${file#"$STATES_CORES/$core"/}")
			name=$(basename "$file")
			state_split_sidecar "$name"
			if ! stem=$(state_stem_of "$STATE_BASE"); then
				report_issue "Left in /States/Cores/$core: $file is not a state file name."
				STATES_RESTORE_UNRESOLVED=$((STATES_RESTORE_UNRESOLVED + 1))
				continue
			fi
			stem=${stem%.core-conflict-[0-9]*}
			rc=0
			tag=$(states_tag_for "$core" "$stem" "$STATES_TABLE" "$index") || rc=$?
			if [ "$rc" = 1 ]; then
				report_issue "Unmatched shared-core state left in place: $file"
				STATES_RESTORE_UNRESOLVED=$((STATES_RESTORE_UNRESOLVED + 1))
				continue
			elif [ "$rc" != 0 ]; then
				report_issue "Ambiguous shared-core state left in place: $file"
				STATES_RESTORE_UNRESOLVED=$((STATES_RESTORE_UNRESOLVED + 1))
				continue
			fi
			emu=$(awk -F'|' -v tag="$tag" -v core="$core" '$1 == tag && $3 == core { print $2; exit }' "$STATES_TABLE")
			rom=""
			if [ "$target_format" = 0 ]; then
				rom=$(awk -F'|' -v tag="$tag" -v stem="$stem" '$1 == tag && $2 == stem && $4 == "direct" { print $3 }' "$index")
				if [ -z "$rom" ] || [ "$(printf '%s\n' "$rom" | grep -c .)" != 1 ]; then
					report_issue "No single matching ROM to name a MinUI state; left in place: $file"
					STATES_RESTORE_UNRESOLVED=$((STATES_RESTORE_UNRESOLVED + 1))
					continue
				fi
			fi
			target_name=$(state_from_retroarch "$STATE_BASE" "$target_format" "$rom") || {
				report_issue "Left in /States/Cores/$core: $file cannot be named for $(state_format_name "$target_format")."
				STATES_RESTORE_UNRESOLVED=$((STATES_RESTORE_UNRESOLVED + 1))
				continue
			}
			if [ "$rel_dir" = "." ]; then
				printf '%s\t%s-%s\t%s\n' "$file" "$tag" "$emu" "$target_name$STATE_SIDE" >> "$plan"
			else
				printf '%s\t%s-%s\t%s\n' "$file" "$tag" "$emu" "$rel_dir/$target_name$STATE_SIDE" >> "$plan"
			fi
			STATES_RESTORE_MATCHED=$((STATES_RESTORE_MATCHED + 1))
		done < "$files"
	done < "$dirs"
	rm -f "$dirs" "$files"
}
