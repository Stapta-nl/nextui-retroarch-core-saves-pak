#!/usr/bin/env bats
# bats file_tags=host
#
# The three sh suites under bin/tests/ (Core Saves, Core States, and both with real bind
# mounts), run as bats tests so they show up in the JUnit report and the debug bundle.
# They stay plain POSIX sh: the same scripts run on the device (see device.bats).

load '../helpers/common'

run_suite() {
    run sh "$REPO_DIR/bin/tests/$1"
    echo "$output" >"$OUT_DIR/legacy-$1.log"
    [ "$status" -eq 0 ] || echo "$output" >&2
    [ "$status" -eq 0 ]
}

setup_file() {
    mkdir -p "$OUT_DIR"
}

@test "Core Saves: conversion, mappings, profiles, backups" {
    run_suite test-core-saves.sh
    assert_output --partial "RetroArch Core Saves tests passed"
}

@test "Core States: naming, transaction, rollback, recovery, menu rows" {
    run_suite test-core-states.sh
    assert_output --partial "RetroArch Core States tests passed"
}

@test "Core Saves and Core States with real bind mounts (unshare -rm)" {
    command -v unshare >/dev/null 2>&1 || skip "unshare is not available"
    unshare -rm true 2>/dev/null || skip "unshare -rm is not permitted here (no user namespaces)"
    run_suite test-core-saves-mounts.sh
    assert_output --partial "PASS: Core Saves with real mounts"
    assert_output --partial "PASS: Core States with real mounts"
}

@test "the suites leave nothing mounted" {
    run mounts_under "${TMPDIR:-/tmp}"
    refute_output --partial "core-saves-mounts"
    refute_output --partial "core-states-tests"
    refute_output --partial "core-saves-tests"
}
