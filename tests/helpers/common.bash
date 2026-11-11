# shellcheck shell=bash
# Shared helpers for the bats tests. Load it from a .bats file with: load '../helpers/common'
#
# It loads bats-support and bats-assert (downloaded into tests/lib by the
# Makefile) and defines the settings every test file shares. Nothing in here is specific
# to one pak: the name, kind and platforms come from pak.json. Runs on the host and, with
# the bundle from `make test-bundle`, on the device (bash is all it needs).

TESTS_DIR="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"

load "$TESTS_DIR/lib/bats-support/load.bash"
load "$TESTS_DIR/lib/bats-assert/load.bash"

# Where per-case logs and kept files go (the debug bundle picks them up).
OUT_DIR="${OUT_DIR:-/tmp/pak-test-out}"

# The platform under test: $PLATFORM, or the first platform in pak.json (host runs).
pak_platform() {
    if [ -n "${PLATFORM:-}" ]; then
        printf '%s' "$PLATFORM"
    else
        jq -r '.platforms[0]' "$REPO_DIR/pak.json"
    fi
}

# The pak under test: $SRC_PAK (an unpacked release in CI, the installed pak on a device),
# else the repository checkout.
pak_src() {
    printf '%s' "${SRC_PAK:-$REPO_DIR}"
}

# The pak's name (pak.json "name"; on a device $PAK_NAME, forwarded by the runner).
pak_name() {
    local n="${PAK_NAME:-}"
    if [ -z "$n" ] && command -v jq >/dev/null 2>&1; then
        n="$(jq -r '.name // empty' "$REPO_DIR/pak.json" 2>/dev/null)"
    fi
    printf '%s' "${n:-$(basename "$REPO_DIR")}"
}

# require_tools <tool...>: fails naming every tool that is missing. The device's BusyBox is
# small, so say clearly what is missing instead of failing oddly later.
require_tools() {
    local missing="" tool
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
    done
    if [ -n "$missing" ]; then
        fail "missing tools on this system:$missing"
    fi
}

# Writes a note into the test output (shown by bats for passing tests too).
info() { echo "# $*" >&3; }

# assert_grep <file> <regex>: the file has a line matching the regex.
assert_grep() {
    grep -q -- "$2" "$1" || {
        echo "expected $1 to match: $2" >&2
        return 1
    }
}
# refute_grep <file> <regex>: no line matches.
refute_grep() {
    if grep -q -- "$2" "$1"; then
        echo "expected $1 not to match: $2" >&2
        return 1
    fi
}

# mounts_under <dir>: the mount points below <dir>, from /proc/self/mountinfo.
mounts_under() {
    awk -v root="$1" 'substr($5, 1, length(root) + 1) == root "/" { print $5 }' /proc/self/mountinfo
}
