# Tests for the tunables step of vios_standardise.ksh - sourced by run_tests.ksh

# real standardise script in $BASE, with the tunable tools stubbed at given current values
setup_standardise() {   # setup_standardise <ioo current> <no current> <acfo current>
    cp "$SRCDIR/vios_standardise.ksh" "$SRCDIR/push_files.manifest.example" "$BASE/"
    mkstub ioo  0 "j2_dynamicBufferPreallocation = $1"
    mkstub no   0 "tcp_fastlo = $2"
    mkstub acfo 0 "in_core_enabled: $3"
    export TUNABLES="ioo:j2_dynamicBufferPreallocation=256 no:tcp_fastlo=1 acfo:in_core_enabled=1"
}

test_tunables_from_config_are_applied_with_before_and_after() {
    setup_standardise 128 0 0
    run_standardise -s tunables
    assert_eq 0 "$RC" "rc"
    assert_eq 1 "$(call_count 'ioo -p -o j2_dynamicBufferPreallocation=256')" "ioo set"
    assert_eq 1 "$(call_count 'no -p -o tcp_fastlo=1')" "no set"
    assert_eq 1 "$(call_count 'acfo -p -t in_core_enabled=1')" "acfo set"
    assert_contains "$OUT" "128 -> 256" "before and after shown"
}

test_tunable_already_at_value_is_not_reapplied() {
    setup_standardise 256 1 1
    run_standardise -s tunables
    assert_eq 0 "$RC" "rc"
    assert_eq 0 "$(call_count 'ioo -p')" "ioo not set"
    assert_eq 0 "$(call_count 'no -p')" "no not set"
    assert_eq 0 "$(call_count 'acfo -p')" "acfo not set"
    assert_contains "$OUT" "already 256" "reports current value"
}

test_tunables_dry_run_changes_nothing() {
    setup_standardise 128 0 0
    run_standardise -n -s tunables
    assert_eq 0 "$RC" "rc"
    assert_eq 0 "$(call_count 'ioo -p')" "ioo not set"
    assert_contains "$OUT" "j2_dynamicBufferPreallocation" "names the tunable"
    assert_contains "$OUT" "would" "dry run wording"
}

test_tunable_tool_missing_is_skipped_not_failed() {
    setup_standardise 128 0 0
    rm -f "$STUBS/acfo"
    run_standardise -s tunables
    assert_eq 0 "$RC" "rc"
    assert_contains "$OUT" "acfo" "names the tool"
    assert_contains "$OUT" "not available" "skip wording"
    assert_eq 1 "$(call_count 'ioo -p')" "other tunables still applied"
}
