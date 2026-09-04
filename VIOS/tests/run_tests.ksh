#!/bin/ksh
#|-----------------------------------------------------------------------------------------------------------------|
#| run_tests.ksh - unit tests for the VIOS scripts, runnable on any ksh93 (macOS, Linux, AIX).
#|
#| AIX commands are replaced by stubs created per test with mkstub; sibling scripts called by vios_build.ksh
#| are replaced by stub scripts that record their arguments. Every stub appends "<name> <args>" to $STUB_LOG.
#|
#| Usage: ksh tests/run_tests.ksh [test_name ...]
#|-----------------------------------------------------------------------------------------------------------------|

set -u
TESTDIR=$(cd "$(dirname "$0")" && pwd)
SRCDIR=$(cd "$TESTDIR/.." && pwd)
WORK=${TMPDIR:-/tmp}; WORK="${WORK%/}/vios_tests.$$"
pass=0 fail=0 failed_names=""

#############################################
# Helpers available to tests
#############################################

# mkstub <name> [rc] [output...] : create a stub command in $STUBS that logs its call, prints output, exits rc
mkstub() {
    name=$1; rc=${2:-0}; shift 2 2>/dev/null || shift $#
    {
        print '#!/bin/ksh'
        print 'print -- "'"$name"' $*" >> "$STUB_LOG"'
        for line in "$@"; do print 'print -- '"'$line'"; done
        print "exit $rc"
    } > "$STUBS/$name"
    chmod +x "$STUBS/$name"
}

# mkscript <name> [rc] : stub sibling script in $BASE that records its args
mkscript() {
    name=$1; rc=${2:-0}
    {
        print '#!/bin/ksh'
        print 'print -- "'"$name"' $*" >> "$STUB_LOG"'
        print "exit $rc"
    } > "$BASE/$name"
    chmod +x "$BASE/$name"
}

# fresh_base : copy the real driver and library into a fresh $BASE with stub siblings
fresh_base() {
    rm -rf "$BASE"; mkdir -p "$BASE"
    cp "$SRCDIR/vios_lib.ksh" "$BASE/"
    [[ -f "$SRCDIR/vios_build.ksh" ]] && cp "$SRCDIR/vios_build.ksh" "$BASE/"
    for s in vios_standardise.ksh rulestoset.ksh sea_status.ksh unused_adapters.ksh lldp_setup.ksh; do
        mkscript "$s" 0
    done
}

calls()      { grep -- "^$1" "$STUB_LOG" 2>/dev/null; }
call_count() { grep -c -- "^$1" "$STUB_LOG" 2>/dev/null || true; }

assert_eq() {   # assert_eq <expected> <actual> <label>
    if [[ "$1" == "$2" ]]; then :; else
        print "    FAIL $3: expected [$1] got [$2]"; t_fail=1
    fi
}
assert_contains() {   # assert_contains <text> <needle> <label>
    if [[ "$1" == *"$2"* ]]; then :; else
        print "    FAIL $3: [$2] not found in:"; print -- "$1" | sed 's/^/      | /'; t_fail=1
    fi
}
assert_not_contains() {
    if [[ "$1" == *"$2"* ]]; then
        print "    FAIL $3: [$2] unexpectedly found"; t_fail=1
    fi
}
assert_file() { [[ -f "$1" ]] || { print "    FAIL $2: file missing $1"; t_fail=1; }; }
assert_no_file() { [[ -f "$1" ]] && { print "    FAIL $2: file exists $1"; t_fail=1; } || true; }

# run_build <args...> : run the driver under test with the stub PATH; output in $OUT, rc in $RC
run_build() {
    OUT=$(PATH="$STUBS:$PATH" LOGDIR="$LOGDIR" IOSCLI="$STUBS/ioscli" STUB_LOG="$STUB_LOG" \
          ksh "$BASE/vios_build.ksh" "$@" 2>&1 < "${STDIN:-/dev/null}")
    RC=$?
}

# run_standardise <args...>
run_standardise() {
    OUT=$(PATH="$STUBS:$PATH" LOGDIR="$LOGDIR" IOSCLI="$STUBS/ioscli" STUB_LOG="$STUB_LOG" \
          ksh "$BASE/vios_standardise.ksh" "$@" 2>&1 < /dev/null)
    RC=$?
}

#############################################
# Per-test setup: a clean stub dir, log dir and base dir; default stubs for a healthy VIOS
#############################################

setup() {
    STUBS="$WORK/stubs"; LOGDIR="$WORK/log"; BASE="$WORK/base"; STUB_LOG="$WORK/calls.log"
    rm -rf "$WORK"; mkdir -p "$STUBS" "$LOGDIR"
    : > "$STUB_LOG"
    STDIN=""
    mkstub id 0 0                                  # root
    mkstub uname 0 vios1                           # -n / -s both answer something harmless
    mkstub who 0 "   .       system boot  Sep  4 10:00"
    mkstub ioscli 0 "4.1.2.10"
    mkstub netstat 0 "default 10.0.0.1 UG 0 0 en0"
    mkstub hostname 0 vios1
    mkstub lssrc 0 "xntpd active"
    mkstub ifconfig 0 "en0: flags=... inet 10.0.0.5 netmask 0xffffff00"
    fresh_base
}

#############################################
# Runner
#############################################

run_test() {
    t_fail=0
    setup
    "$1"
    if (( t_fail )); then
        fail=$((fail + 1)); failed_names="$failed_names $1"; print "not ok - $1"
    else
        pass=$((pass + 1)); print "ok - $1"
    fi
}

. "$TESTDIR/tests_vios_build.ksh"
[[ -f "$TESTDIR/tests_standardise.ksh" ]] && . "$TESTDIR/tests_standardise.ksh"
[[ -f "$TESTDIR/tests_tarball.ksh" ]] && . "$TESTDIR/tests_tarball.ksh"

if (( $# )); then
    tests="$*"
else
    tests=$(typeset +f | grep '^test_' | sed 's/()$//')
fi
for t in $tests; do run_test "$t"; done
rm -rf "$WORK"

print ""
print "$pass passed, $fail failed${failed_names:+ :$failed_names}"
(( fail == 0 ))
