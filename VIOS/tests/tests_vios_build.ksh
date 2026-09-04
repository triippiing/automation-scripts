# Tests for vios_build.ksh - sourced by run_tests.ksh

test_list_shows_phases_in_order() {
    run_build -l
    assert_eq 0 "$RC" "rc"
    assert_contains "$OUT" "check" "check listed"
    lines=$(print -- "$OUT" | grep -E '^(check|build|fixes|verify)' | awk '{print $1}' | tr '\n' ' ')
    assert_eq "check build fixes verify " "$lines" "phase order"
}

# State file the driver keeps: one line per phase  "<phase> <status> <boot id>"
STATE_FILE_NAME=vios_build.state
state() { cat "$LOGDIR/$STATE_FILE_NAME" 2>/dev/null; }
# write_state <boot id> <phase>... : pre-populate phases as done
write_state() {
    boot=$1; shift
    for p in "$@"; do print "$p done $boot"; done > "$LOGDIR/$STATE_FILE_NAME"
}

test_fresh_run_executes_check_build_fixes_then_stops_for_reboot() {
    mkdir -p "$BASE/fixes/4.1.2.10/fix1"
    run_build
    assert_eq 0 "$RC" "rc"
    assert_eq 2 "$(call_count vios_standardise.ksh)" "standardise called for build and fixes"
    assert_contains "$(calls vios_standardise.ksh | sed -n 1p)" "vios_standardise.ksh " "build call"
    assert_not_contains "$(calls vios_standardise.ksh | sed -n 1p)" "-F" "build call has no -F"
    assert_contains "$(calls vios_standardise.ksh | sed -n 2p)" "-F $BASE/fixes/4.1.2.10" "fixes call"
    assert_eq 0 "$(call_count sea_status.ksh)" "verify not run before reboot"
    assert_contains "$OUT" "reboot" "asks for reboot"
    assert_contains "$(state)" "check done" "check recorded"
    assert_contains "$(state)" "build done" "build recorded"
    assert_contains "$(state)" "fixes done" "fixes recorded"
    assert_not_contains "$(state)" "verify" "verify not recorded"
}

test_fixes_skipped_when_no_fixes_dir() {
    run_build
    assert_eq 0 "$RC" "rc"
    assert_eq 1 "$(call_count vios_standardise.ksh)" "standardise called once"
    assert_contains "$OUT" "no fixes directory" "explains skip"
    assert_contains "$(state)" "fixes skipped" "fixes recorded as skipped"
}

test_rerun_before_reboot_refuses_verify() {
    write_state "Sep 4 10:00" check build fixes
    run_build
    assert_eq 1 "$RC" "rc"
    assert_contains "$OUT" "reboot" "tells user to reboot"
    assert_eq 0 "$(call_count vios_standardise.ksh)" "build not rerun"
    assert_eq 0 "$(call_count sea_status.ksh)" "verify not run"
}

test_rerun_after_reboot_runs_verify_only() {
    write_state "Sep 4 09:00" check build fixes
    run_build
    assert_eq 0 "$RC" "rc"
    assert_eq 0 "$(call_count vios_standardise.ksh)" "build not rerun"
    assert_contains "$(calls rulestoset.ksh)" "-n" "rulestoset dry run"
    assert_contains "$(calls sea_status.ksh)" "-a" "sea_status -a"
    assert_eq 1 "$(call_count unused_adapters.ksh)" "unused_adapters run"
    assert_eq 1 "$(call_count lldp_setup.ksh)" "lldp_setup run"
    assert_contains "$(state)" "verify done" "verify recorded"
    assert_contains "$OUT" "push_files.ksh" "day-two steps printed"
}

test_dry_run_passes_n_and_records_nothing() {
    mkdir -p "$BASE/fixes/4.1.2.10/fix1"
    run_build -n
    assert_eq 0 "$RC" "rc"
    assert_contains "$(calls vios_standardise.ksh | sed -n 1p)" "-n" "build dry run"
    assert_contains "$(calls vios_standardise.ksh | sed -n 2p)" "-n" "fixes dry run"
    assert_no_file "$LOGDIR/$STATE_FILE_NAME" "no state written"
}

test_build_failure_stops_run_and_is_not_recorded() {
    mkdir -p "$BASE/fixes/4.1.2.10/fix1"
    mkscript vios_standardise.ksh 1
    run_build
    assert_eq 1 "$RC" "rc"
    assert_eq 1 "$(call_count vios_standardise.ksh)" "fixes not attempted after failed build"
    assert_contains "$(state)" "check done" "check recorded"
    assert_not_contains "$(state)" "build" "build not recorded"
}

test_reset_clears_state() {
    write_state "Sep 4 10:00" check build
    run_build -r
    assert_eq 0 "$RC" "rc"
    assert_no_file "$LOGDIR/$STATE_FILE_NAME" "state removed"
}

test_explicit_phase_runs_only_that_phase() {
    run_build -p build
    assert_eq 0 "$RC" "rc"
    assert_eq 1 "$(call_count vios_standardise.ksh)" "standardise once"
    assert_not_contains "$(state)" "check" "check not run"
    assert_contains "$(state)" "build done" "build recorded"
}

test_explicit_fixes_dir_overrides_default() {
    mkdir -p "$WORK/myfixes/a"
    run_build -p fixes -F "$WORK/myfixes"
    assert_eq 0 "$RC" "rc"
    assert_contains "$(calls vios_standardise.ksh)" "-F $WORK/myfixes" "uses -F dir"
}

test_check_fails_without_default_route_when_noninteractive() {
    mkstub netstat 0
    run_build -y
    assert_eq 1 "$RC" "rc"
    assert_contains "$OUT" "default route" "names the missing item"
    assert_eq 0 "$(call_count vios_standardise.ksh)" "build not run"
}

test_check_fails_when_license_not_accepted() {
    mkstub ioscli 1 "The license agreement has not been accepted"
    run_build -y
    assert_eq 1 "$RC" "rc"
    assert_contains "$OUT" "license" "names the license"
    assert_eq 0 "$(call_count vios_standardise.ksh)" "build not run"
}

test_check_offers_mktcpip_when_no_network_and_interactive() {
    mkstub netstat 0
    mkstub hostname 0 localhost
    STDIN="$WORK/answers"
    printf 'y\nvios1\nen0\n10.0.0.5\n255.255.255.0\n10.0.0.1\n10.0.0.2\nexample.com\n' > "$STDIN"
    # after mktcpip the network checks must pass: the mktcpip stub rewrites the netstat/hostname stubs
    cp "$TESTDIR/fixtures/ioscli_mktcpip.stub" "$STUBS/ioscli"
    chmod +x "$STUBS/ioscli"
    run_build -p check
    assert_eq 0 "$RC" "rc"
    assert_contains "$(calls 'ioscli mktcpip')" "-hostname vios1 -inetaddr 10.0.0.5 -interface en0 -netmask 255.255.255.0 -gateway 10.0.0.1 -nsrvaddr 10.0.0.2 -nsrvdomain example.com" "mktcpip args"
    assert_contains "$(state)" "check done" "check recorded"
}
