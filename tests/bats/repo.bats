#!/usr/bin/env bats
# bats file_tags=host
#
# Checks on the repository and on what a release contains. Nothing here knows about this
# pak in particular: platforms, the version and the binaries it needs come from pak.json
# and the files themselves.

load '../helpers/common'

setup_file() {
    require_tools jq git unzip file sha256sum
}

@test "pak.json is valid and has the fields NextUI needs" {
    run jq -e '.name and .version and .type and (.platforms | length > 0) and .description' "$REPO_DIR/pak.json"
    assert_success
}

@test "the current version has a changelog entry" {
    version="$(jq -r .version "$REPO_DIR/pak.json")"
    run jq -e --arg v "$version" '.changelog[$v] | type == "string" and length > 0' "$REPO_DIR/pak.json"
    assert_success
}

@test "settings.json is valid JSON" {
    run jq -e . "$REPO_DIR/settings.json"
    assert_success
}

@test "every platform in pak.json has the binaries the pak runs" {
    local p b missing=""
    for p in $(jq -r '.platforms[]' "$REPO_DIR/pak.json"); do
        for b in jq minui-list minui-presenter save-rzip; do
            [ -x "$REPO_DIR/bin/$p/$b" ] || missing="$missing bin/$p/$b"
        done
    done
    [ -z "$missing" ] || fail "missing or not executable:$missing"
}

@test "the binaries have the right CPU architecture for their platform" {
    local p b desc bad=""
    for p in $(jq -r '.platforms[]' "$REPO_DIR/pak.json"); do
        for b in "$REPO_DIR/bin/$p"/*; do
            desc="$(file -b "$b")"
            case "$p" in
            my285) want='ARM, EABI5' ;; # 32-bit ARM
            *) want='ARM aarch64' ;;
            esac
            case "$desc" in *"$want"*) ;; *) bad="$bad $(basename "$b")@$p($desc)" ;; esac
        done
    done
    [ -z "$bad" ] || fail "unexpected architecture:$bad"
}

@test "bin/SHA256SUMS matches the files" {
    cd "$REPO_DIR"
    run sha256sum -c bin/SHA256SUMS
    assert_success
}

@test "devices.env.example has host and ssh options for every platform" {
    local p upper missing=""
    for p in $(jq -r '.platforms[]' "$REPO_DIR/pak.json"); do
        upper="$(printf '%s' "$p" | tr '[:lower:]' '[:upper:]')"
        grep -q "^${upper}_HOST" "$TESTS_DIR/devices.env.example" || missing="$missing ${upper}_HOST"
        grep -q "^${upper}_SSH_OPTS" "$TESTS_DIR/devices.env.example" || missing="$missing ${upper}_SSH_OPTS"
    done
    [ -z "$missing" ] || fail "missing from tests/devices.env.example:$missing"
}

@test "devices.env is git-ignored" {
    cd "$REPO_DIR"
    run git check-ignore tests/devices.env
    assert_success
}

@test "the release archive has the pak and none of the test or doc files" {
    local zip="${RELEASE_ZIP:-}"
    if [ -z "$zip" ]; then
        zip="$BATS_TEST_TMPDIR/release.zip"
        # git archive honours export-ignore in .gitattributes, as `make release` does.
        (cd "$REPO_DIR" && git archive --worktree-attributes --format=zip --output="$zip" HEAD)
    fi
    run unzip -Z1 "$zip"
    assert_success
    assert_line "launch.sh"
    assert_line "pak.json"
    assert_line "settings.json"
    assert_line --partial "bin/tg5040/minui-list"
    refute_line --regexp '^tests/'
    refute_line --regexp '^docs/'
    refute_line --regexp '^bin/tests/'
    refute_line --regexp '^bin/desktop/'
    refute_line --regexp '^\.github/'
    refute_line "Makefile"
}

@test "shellcheck is clean on the test scripts" {
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck is not installed"
    cd "$REPO_DIR"
    run shellcheck -x -S warning tests/*.sh tests/helpers/*.bash
    assert_success
}
