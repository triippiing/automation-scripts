# Tests for make_tarball.sh - sourced by run_tests.ksh

run_tarball() {
    OUT=$(sh "$SRCDIR/make_tarball.sh" "$@" 2>&1)
    RC=$?
}
members() { tar tf "$1" | sed 's|/$||' | sort; }

test_tarball_holds_scripts_payload_and_fixes_but_not_tests_or_hosts() {
    mkdir -p "$WORK/fixes/4.1.2.10/fix1"
    : > "$WORK/fixes/4.1.2.10/fix1/x.epkg.Z"
    run_tarball -o "$WORK/out.tar" -f "$WORK/fixes"
    assert_eq 0 "$RC" "rc: $OUT"
    assert_file "$WORK/out.tar" "tar written"
    m=$(members "$WORK/out.tar")
    assert_contains "$m" "vios_build/vios_build.ksh" "driver"
    assert_contains "$m" "vios_build/vios_lib.ksh" "library"
    assert_contains "$m" "vios_build/vios_standardise.ksh" "standardise"
    assert_contains "$m" "vios_build/payload/SEbanner" "payload"
    assert_contains "$m" "vios_build/adapter_rules.conf" "rules conf"
    assert_contains "$m" "vios_build/RUNBOOK.md" "runbook"
    assert_contains "$m" "vios_build/fixes/4.1.2.10/fix1/x.epkg.Z" "fix package"
    assert_not_contains "$m" "vios_build/tests" "tests excluded"
    assert_not_contains "$m" "vios_build/hosts" "host lists excluded"
    assert_contains "$OUT" "$WORK/out.tar" "reports the output path"
}

test_tarball_without_fixes_dir_still_builds() {
    run_tarball -o "$WORK/out.tar"
    assert_eq 0 "$RC" "rc: $OUT"
    m=$(members "$WORK/out.tar")
    assert_contains "$m" "vios_build/vios_build.ksh" "driver"
    assert_not_contains "$m" "vios_build/fixes" "no fixes dir"
}

test_tarball_refuses_missing_fixes_dir() {
    run_tarball -o "$WORK/out.tar" -f "$WORK/nowhere"
    assert_eq 1 "$RC" "rc"
    assert_contains "$OUT" "nowhere" "names the missing dir"
    assert_no_file "$WORK/out.tar" "nothing written"
}
