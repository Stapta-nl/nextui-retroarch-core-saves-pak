#!/bin/sh

prune_backups() {
	local keep="${1:-5}"
	local protected="${2:-}"
	local list="$BACKUP_ROOT/.backup-list.$$"
	local count=0 backup

	find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
		! -name '*.incomplete' -print 2>/dev/null |
		LC_ALL=C sort -r > "$list" || {
			rm -f "$list"
			return 1
		}
	while IFS= read -r backup; do
		[ -n "$backup" ] || continue
		[ "$backup" = "$protected" ] && continue
		# The backups an enabled setup points at hold the saves and states it
		# started from, so they stay however many newer ones there are.
		[ "$backup" = "$(enabled_value backup)" ] && continue
		[ "$backup" = "$(enabled_value states_backup)" ] && continue
		count=$((count + 1))
		if [ -n "$protected" ]; then
			[ "$count" -lt "$keep" ] && continue
		else
			[ "$count" -le "$keep" ] && continue
		fi
		case "$backup" in
			"$BACKUP_ROOT"/*) rm -rf "$backup" || {
				rm -f "$list"
				return 1
			} ;;
			*)
				rm -f "$list"
				return 1
				;;
		esac
	done < "$list"
	rm -f "$list"
}

# prune_backups deliberately ignores *.incomplete directories so a backup in
# progress is never counted or deleted. That leaves a full copy of the save tree
# behind whenever an operation dies mid-copy, since the next run picks a new
# timestamped name. Only one instance of the pak runs at a time, so any
# *.incomplete other than the one named by $keep is abandoned and reclaimable.
reclaim_incomplete_backups() {
	local keep="${1:-}"
	local list="$BACKUP_ROOT/.incomplete-list.$$"
	local backup
	find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '*.incomplete' \
		-print 2>/dev/null > "$list" || :
	while IFS= read -r backup; do
		[ -n "$backup" ] || continue
		[ "$backup" = "$keep" ] && continue
		case "$backup" in
			"$BACKUP_ROOT"/*.incomplete) rm -rf "$backup" || {
				rm -f "$list"
				return 1
			} ;;
			*)
				rm -f "$list"
				return 1
				;;
		esac
	done < "$list"
	rm -f "$list"
}

# $2 is the states table (tag|emu|core), when states are part of the operation:
# the NextUI states folders it lists are kept under States/<tag>-<emu>, so a
# rollback can put them back exactly as they were.
make_backup() {
	local label="$1"
	local states_table="${2:-}"
	local ts backup incomplete n tag emu core dir
	ts=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)
	backup="$BACKUP_ROOT/$ts-$label"
	n=0
	while [ -e "$backup" ]; do
		n=$((n + 1))
		backup="$BACKUP_ROOT/$ts-$label-$$-$n"
	done
	incomplete="$backup.incomplete"
	rm -rf "$incomplete"
	reclaim_incomplete_backups "$incomplete" ||
		log "Could not reclaim abandoned partial backups."
	mkdir -p "$incomplete/Saves" || return 1
	cp -a "$SAVES_PATH"/. "$incomplete/Saves"/ || {
		rm -rf "$incomplete"
		return 1
	}
	if [ -n "$states_table" ] && [ -f "$states_table" ]; then
		while IFS='|' read -r tag emu core; do
			[ -n "$tag" ] && [ -n "$emu" ] || continue
			dir=$(states_target "$tag" "$emu")
			[ -d "$dir" ] || continue
			mkdir -p "$incomplete/States/$tag-$emu" &&
				cp -a "$dir"/. "$incomplete/States/$tag-$emu"/ || {
				rm -rf "$incomplete"
				return 1
			}
		done < "$states_table"
	fi
	if [ -f "$SETTINGS_PATH" ]; then
		cp -p "$SETTINGS_PATH" "$incomplete/minuisettings.txt" || {
			rm -rf "$incomplete"
			return 1
		}
		echo 1 > "$incomplete/settings-existed" || {
			rm -rf "$incomplete"
			return 1
		}
	else
		echo 0 > "$incomplete/settings-existed" || {
			rm -rf "$incomplete"
			return 1
		}
	fi
	mv "$incomplete" "$backup" || {
		rm -rf "$incomplete"
		return 1
	}
	prune_backups 5 "$backup" || log "Could not prune old save backups."
	echo "$backup"
}
