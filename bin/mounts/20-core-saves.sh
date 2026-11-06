#!/bin/sh
# mountctl layer 20, RetroArch Core Saves.pak: each system-tag folder in /Saves
# shows its core's folder in /Saves/Cores, and, when Core States is part of the
# setup, each NextUI states folder shows its core's folder in States/Cores. It
# reads its tables from shared data, which Profiles (layer 10) may mount, so it
# has to come after Profiles.

# The pak's installer may pin this when its folder was renamed.
: "${CORE_SAVES_HOME:=$SHARED_USERDATA_PATH/RetroArch Core Saves}"

SAVES_PATH="$SDCARD_PATH/Saves"
STATES_PATH="$SDCARD_PATH/States/Cores"
TABLE="$CORE_SAVES_HOME/mounts.conf"
STATES_TABLE="$CORE_SAVES_HOME/states-mounts.conf"
PROFILE_ROOT="$SDCARD_PATH/.profiles"
OWNER_FILE="$PROFILE_ROOT/core-saves-profile"

# One marker says whether states are part of this setup (states=1).
with_states() {
	[ -f "$CORE_SAVES_HOME/enabled" ] && grep -q '^states=1$' "$CORE_SAVES_HOME/enabled"
}

case "$1" in
	scope)
		printf 'below\t%s\n' "$SAVES_PATH"
		printf 'reads\t%s\n' "$CORE_SAVES_HOME" "$PROFILE_ROOT"
		# The states folders live in shared data, where this layer also reads its
		# own state. A "below" scope there would put that read inside it, so each
		# folder is declared exactly. That also keeps the layer from owning any
		# other mount that happens to be in shared data.
		if with_states && [ -s "$STATES_TABLE" ]; then
			while IFS='|' read -r tag emu core; do
				[ -n "$tag" ] && [ -n "$emu" ] && [ -n "$core" ] || continue
				printf 'at\t%s\n' "$SHARED_USERDATA_PATH/$tag-$emu"
			done < "$STATES_TABLE"
		fi
		;;
	plan)
		[ -f "$CORE_SAVES_HOME/enabled" ] || exit 0
		[ -s "$TABLE" ] || {
			echo "Core Saves is enabled but its mount table is missing: $TABLE" >&2
			exit 1
		}
		if with_states && [ ! -s "$STATES_TABLE" ]; then
			echo "Core Saves is enabled with states but its states table is missing: $STATES_TABLE" >&2
			exit 1
		fi
		# Profiles lets one profile own Core Saves. Only enforced while the
		# Profiles layer is installed: after Profiles is uninstalled its marker
		# files stay behind but no longer describe what /Saves shows.
		if [ -f "$MOUNTS_HOME/layers.d/10-profiles.sh" ] && [ -f "$PROFILE_ROOT/active" ]; then
			active=$(sed -n '1p' "$PROFILE_ROOT/active")
			if [ -f "$OWNER_FILE" ]; then
				owner=$(sed -n '1p' "$OWNER_FILE")
				if [ -n "$owner" ] && [ "$owner" != "$active" ]; then
					echo "Core Saves belongs to profile $owner; $active is active, so no tag mounts" >&2
					exit 0
				fi
			elif [ -n "$active" ]; then
				printf '%s\n' "$active" > "$OWNER_FILE" || {
					echo "Could not record $active as the Core Saves owner" >&2
					exit 1
				}
			fi
		fi
		while IFS='|' read -r tag core; do
			[ -n "$tag" ] && [ -n "$core" ] || continue
			printf '%s\t%s\tempty-target\n' "$SAVES_PATH/Cores/$core" "$SAVES_PATH/$tag"
		done < "$TABLE"
		if with_states; then
			while IFS='|' read -r tag emu core; do
				[ -n "$tag" ] && [ -n "$emu" ] && [ -n "$core" ] || continue
				printf '%s\t%s\tempty-target\n' "$STATES_PATH/$core" "$SHARED_USERDATA_PATH/$tag-$emu"
			done < "$STATES_TABLE"
		fi
		;;
	*)
		echo "usage: $0 scope|plan" >&2
		exit 2
		;;
esac
