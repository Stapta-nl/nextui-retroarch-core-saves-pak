#!/bin/sh
# mountctl layer 30, RetroArch Core Saves.pak (Core States): each NextUI states
# folder, $SHARED_USERDATA_PATH/<TAG>-<core>, shows its core's folder in
# $SDCARD_PATH/States/Cores. It reads its table from shared data, which
# Profiles (layer 10) may mount, so it has to come after Profiles.
#
# Unlike layer 20 it cannot declare "below <shared data>": layer 20 reads its own
# state from inside shared data, and mountctl treats a read under a later
# layer's "below" scope as an ordering error. It declares one exact "at" scope
# per folder it mounts instead, which also keeps it from owning any other mount
# that happens to live in shared data.

# The pak's installer may pin this when its folder was renamed.
: "${CORE_SAVES_HOME:=$SHARED_USERDATA_PATH/RetroArch Core Saves}"

STATES_PATH="$SDCARD_PATH/States/Cores"
TABLE="$CORE_SAVES_HOME/states-mounts.conf"
PROFILE_ROOT="$SDCARD_PATH/.profiles"
OWNER_FILE="$PROFILE_ROOT/core-saves-profile"

case "$1" in
	scope)
		printf 'reads\t%s\n' "$CORE_SAVES_HOME" "$PROFILE_ROOT"
		[ -f "$CORE_SAVES_HOME/states-enabled" ] && [ -s "$TABLE" ] || exit 0
		while IFS='|' read -r tag emu core; do
			[ -n "$tag" ] && [ -n "$emu" ] && [ -n "$core" ] || continue
			printf 'at\t%s\n' "$SHARED_USERDATA_PATH/$tag-$emu"
		done < "$TABLE"
		;;
	plan)
		[ -f "$CORE_SAVES_HOME/states-enabled" ] || exit 0
		[ -s "$TABLE" ] || {
			echo "Core States is enabled but its mount table is missing: $TABLE" >&2
			exit 1
		}
		# Same single-owner rule as Core Saves. Only enforced while the Profiles
		# layer is installed.
		if [ -f "$MOUNTS_HOME/layers.d/10-profiles.sh" ] && [ -f "$PROFILE_ROOT/active" ]; then
			active=$(sed -n '1p' "$PROFILE_ROOT/active")
			if [ -f "$OWNER_FILE" ]; then
				owner=$(sed -n '1p' "$OWNER_FILE")
				if [ -n "$owner" ] && [ "$owner" != "$active" ]; then
					echo "Core Saves belongs to profile $owner; $active is active, so no states mounts" >&2
					exit 0
				fi
			fi
		fi
		while IFS='|' read -r tag emu core; do
			[ -n "$tag" ] && [ -n "$emu" ] && [ -n "$core" ] || continue
			printf '%s\t%s\tempty-target\n' "$STATES_PATH/$core" "$SHARED_USERDATA_PATH/$tag-$emu"
		done < "$TABLE"
		;;
	*)
		echo "usage: $0 scope|plan" >&2
		exit 2
		;;
esac
