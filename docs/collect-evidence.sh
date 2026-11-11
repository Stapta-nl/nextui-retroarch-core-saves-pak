#!/bin/sh
# Gathers what is needed to verify RetroArch Core Saves (Core States) on a device.
#
#   sh collect-evidence.sh [SDCARD_PATH] [PLATFORM] [OUT_DIR]
#
# Run it from a shell on the device (SSH, telnet or adb) after each step of
# docs/HARDWARE-TESTING.md, or copy the files it lists by hand from the SD card.
# It copies small text files (logs, settings, tables, reports) and writes
# listings and checksums of states and saves. It never copies the states or
# saves themselves.

SD=${1:-${SDCARD_PATH:-/mnt/SDCARD}}
PLATFORM=${2:-${PLATFORM:-}}
STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)
OUT=${3:-$SD/core-states-evidence-$STAMP}

[ -d "$SD" ] || { echo "No such SD card path: $SD" >&2; exit 1; }

# The platform is the userdata folder that has the pak's logs.
if [ -z "$PLATFORM" ]; then
	for d in "$SD"/.userdata/*; do
		[ -f "$d/logs/core-saves.txt" ] || [ -d "$d/Mounts" ] || continue
		PLATFORM=$(basename "$d")
		break
	done
fi
[ -n "$PLATFORM" ] || { echo "Could not tell the platform; pass it as the second argument." >&2; exit 1; }

USERDATA="$SD/.userdata/$PLATFORM"
SHARED="$SD/.userdata/shared"
mkdir -p "$OUT" || exit 1
SUMMARY="$OUT/summary.txt"

say() { printf '%s\n' "$*" >> "$SUMMARY"; }
section() { say ""; say "=== $*"; }
grab() {
	# grab <file> [name]: copy a small text file if it exists.
	[ -f "$1" ] || { say "missing: $1"; return; }
	cp -p "$1" "$OUT/${2:-$(basename "$1")}" 2>/dev/null && say "copied: $1"
}

hash_tree() {
	# hash_tree <dir>: "<md5>  <path relative to dir>" for every file.
	local dir="$1" sum
	if command -v sha256sum >/dev/null 2>&1; then sum=sha256sum
	elif command -v md5sum >/dev/null 2>&1; then sum=md5sum
	else echo "no sha256sum or md5sum on this device"; return; fi
	(cd "$dir" 2>/dev/null && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
		"$sum" "$f"
	done)
}

: > "$SUMMARY"
say "Core Saves / Core States evidence"
say "collected: $STAMP"
say "sd card:   $SD"
say "platform:  $PLATFORM"
say "uname:     $(uname -a 2>/dev/null)"

section "pak version"
for pak in "$SD"/Tools/*/*[Cc]ore*[Ss]aves*.pak; do
	[ -f "$pak/pak.json" ] || continue
	say "$pak"
	grep -E '"version"' "$pak/pak.json" >> "$SUMMARY"
done

section "NextUI settings (stateFormat: 0 MinUI, 1/2 RetroArch-ish, 3 RA compressed, 4 RA uncompressed; saveFormat: 0 MinUI, 1 RA compressed, 2 generic, 3 RA raw)"
grab "$SHARED/minuisettings.txt"
grep -E '^(stateFormat|saveFormat)=' "$SHARED/minuisettings.txt" >> "$SUMMARY" 2>/dev/null

section "pak data folder (reports, markers, tables)"
for dir in "$SHARED"/*[Cc]ore*[Ss]aves*; do
	[ -d "$dir" ] || continue
	name=$(basename "$dir")
	mkdir -p "$OUT/pak-data" && say "data folder: $dir"
	for f in conversion-report.txt enabled mounts.conf states-mounts.conf features.conf migration.manifest operation.journal minui-list-error.json; do
		if [ -f "$dir/$f" ]; then cp -p "$dir/$f" "$OUT/pak-data/$f"; say "  present: $f"; else say "  absent:  $f"; fi
	done
	say "  (operation.journal must be absent after every finished step)"
done

section "logs"
grab "$USERDATA/logs/core-saves.txt"
grab "$USERDATA/logs/core-saves.txt.1"
grab "$USERDATA/logs/mounts.txt"
grab "$USERDATA/logs/mounts.txt.old"

section "mountctl"
if [ -f "$USERDATA/Mounts/mountctl.sh" ]; then
	sh "$USERDATA/Mounts/mountctl.sh" status > "$OUT/mountctl-status.txt" 2>&1
	say "mountctl status saved"
	ls -la "$USERDATA/Mounts/layers.d" >> "$SUMMARY" 2>&1
else
	say "mountctl is not installed (expected after a revert)"
fi
[ -f "$USERDATA/.hooks/boot.d/00-mounts.sync.sh" ] && say "boot hook present" || say "boot hook absent"

section "live bind mounts"
grep -E 'States/Cores|Saves/Cores|/\.userdata/shared/[A-Za-z0-9]+-[A-Za-z0-9_]+ ' /proc/self/mountinfo > "$OUT/mountinfo-filtered.txt" 2>/dev/null
say "$(wc -l < "$OUT/mountinfo-filtered.txt" 2>/dev/null | tr -d ' ') matching mount lines (mountinfo-filtered.txt)"

section "synced trees (listings and checksums only)"
for tree in "$SD/States/Cores" "$SD/Saves/Cores"; do
	label=$(printf '%s' "${tree#"$SD"/}" | tr '/' '-')
	if [ -d "$tree" ]; then
		(cd "$tree" && find . -type f -exec ls -l {} \; 2>/dev/null) > "$OUT/listing-$label.txt"
		hash_tree "$tree" > "$OUT/hashes-$label.txt"
		say "$tree: $(find "$tree" -type f | wc -l | tr -d ' ') files"
	else
		say "$tree: absent"
	fi
done

section "NextUI states folders in shared userdata"
for dir in "$SHARED"/*-*; do
	[ -d "$dir" ] || continue
	case "$(basename "$dir")" in .*|*[Cc]ore*[Ss]aves*) continue ;; esac
	say "$(basename "$dir"): $(find "$dir" -type f 2>/dev/null | wc -l | tr -d ' ') files"
done > "$OUT/.states-folders" 2>/dev/null
cat "$OUT/.states-folders" >> "$SUMMARY"; rm -f "$OUT/.states-folders"
find "$SHARED" -maxdepth 2 -path "$SHARED/.*" -prune -o -type f -name '*state*' -print 2>/dev/null | LC_ALL=C sort > "$OUT/listing-shared-states.txt"
say "(full list: listing-shared-states.txt)"

section "backups (what is in them, not the contents)"
for root in "$SD/.core-saves-backups" "$SD"/.profiles/*/.core-saves-backups; do
	[ -d "$root" ] || continue
	say "$root"
	for b in "$root"/*; do
		[ -d "$b" ] || continue
		say "  $(basename "$b"): Saves=$(find "$b/Saves" -type f 2>/dev/null | wc -l | tr -d ' ') States=$(find "$b/States" -type f 2>/dev/null | wc -l | tr -d ' ')"
		[ -d "$b/States" ] && hash_tree "$b/States" > "$OUT/hashes-backup-$(basename "$b")-States.txt"
	done
done

section "profiles"
grab "$SD/.profiles/active"
grab "$SD/.profiles/core-saves-profile"
[ -d "$SD/.profiles" ] || say "Profiles.pak not in use"

if command -v tar >/dev/null 2>&1; then
	tar -C "$(dirname "$OUT")" -czf "$OUT.tar.gz" "$(basename "$OUT")" 2>/dev/null && say "archive: $OUT.tar.gz"
fi

echo "Evidence collected in: $OUT"
[ -f "$OUT.tar.gz" ] && echo "Archive: $OUT.tar.gz"
echo "Attach summary.txt (and the archive) to the pull request."
