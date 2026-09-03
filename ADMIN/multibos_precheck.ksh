#!/bin/ksh
#=============================================================================
# multibos_precheck.ksh
#
# Purpose : Pre-flight capacity check for "multibos -s" (standby BOS creation)
#           on AIX. Reports whether rootvg has enough free space to hold the
#           copied BOS logical volumes, and flags the conditions that make
#           multibos fail for reasons other than raw capacity.
#
# Usage   : multibos_precheck.ksh [-v] [-m pct] [-q]
#
#   -v        Verbose - show the per-LV and per-PV breakdown.
#   -m pct    Safety margin percentage on top of the raw requirement.
#             Default 10.
#   -q        Quiet - suppress normal output, exit code only.
#
# Exit    : 0 = sufficient space, all preconditions met
#           1 = insufficient space
#           2 = precondition failure (existing standby BOS, missing LV, etc.)
#           3 = script/environment error
#
# NOTE    : "multibos -sXp" is multibos's own preview mode and is the
#           authoritative check immediately before a real run. This script is
#           for planning ahead and for sweeping a fleet without invoking
#           multibos on every host.
#=============================================================================

PROGNAME=${0##*/}

#-- Logical volumes multibos copies into the standby BOS -----------------------
#   Everything else in rootvg (hd1 /home, hd3 /tmp, hd6 paging, hd11admin)
#   is SHARED between BOS instances and costs no additional space.
BOS_LVS="hd5 hd4 hd2 hd9var hd10opt"

MARGIN=10
VERBOSE=0
QUIET=0
RC=0

say() { (( QUIET )) || print -r -- "$*" ; }
vsay() { (( VERBOSE )) && say "$*" ; }
err() { print -u2 -r -- "${PROGNAME}: $*" ; }

usage() {
    print "Usage: $PROGNAME [-v] [-m pct] [-q]"
    exit 3
}

while getopts ":vqm:" opt; do
    case "$opt" in
        v) VERBOSE=1 ;;
        q) QUIET=1   ;;
        m) MARGIN="$OPTARG" ;;
        *) usage ;;
    esac
done

case "$MARGIN" in
    ''|*[!0-9]*) err "margin must be a whole number" ; exit 3 ;;
esac

lsvg rootvg >/dev/null 2>&1 || { err "cannot read rootvg" ; exit 3 ; }

#=============================================================================
# Volume group facts
#=============================================================================
VGINFO=$(lsvg rootvg 2>/dev/null)

# Positional awk on lsvg output is fragile because the left-hand label length
# varies by AIX level. Scan for the label instead of assuming a column.
PPSIZE=$(print -r -- "$VGINFO" | awk '{for(i=1;i<NF;i++) if($i=="PP" && $(i+1)=="SIZE:") {print $(i+2); exit}}')
FREEPP=$(print -r -- "$VGINFO" | awk '{for(i=1;i<NF;i++) if($i=="FREE" && $(i+1)=="PPs:") {print $(i+2); exit}}')
TOTPP=$(print  -r -- "$VGINFO" | awk '{for(i=1;i<NF;i++) if($i=="TOTAL" && $(i+1)=="PPs:") {print $(i+2); exit}}')

case "${PPSIZE}${FREEPP}" in
    ''|*[!0-9]*) err "could not parse PP size / free PPs from lsvg rootvg" ; exit 3 ;;
esac

#=============================================================================
# Existing standby BOS?
#=============================================================================
EXISTING=$(lsvg -l rootvg 2>/dev/null | awk '$1 ~ /^bos_/ {printf "%s ", $1}')
if [[ -n "$EXISTING" ]]; then
    say "PRECONDITION FAILURE: a standby BOS already exists in rootvg."
    say "  Present: ${EXISTING}"
    say "  Remove it first with:  multibos -RX"
    say "  (or mount and inspect it with: multibos -m)"
    exit 2
fi

#=============================================================================
# Per-LV requirement
#=============================================================================
REQ=0
MISSING=""
MIRRORED=0

vsay ""
vsay "Logical volumes copied by multibos -s:"
vsay "  LV           LPs      PPs   Copies   Size(MB)"
vsay "  ----------------------------------------------"

for lv in $BOS_LVS; do
    # $3 = LPs, $4 = PPs. Use PPs - on a mirrored rootvg PPs is what actually
    # gets allocated, and it is double the LP count.
    set -- $(lsvg -l rootvg 2>/dev/null | awk -v L="$lv" '$1==L {print $3, $4}')
    LPS="$1"
    PPS="$2"

    if [[ -z "$PPS" ]]; then
        MISSING="${MISSING}${lv} "
        vsay "  $(printf '%-12s %6s %8s %8s %10s' "$lv" "-" "-" "-" "absent")"
        continue
    fi

    COPIES=$(( PPS / LPS ))
    (( COPIES > 1 )) && MIRRORED=1
    REQ=$(( REQ + PPS ))
    vsay "  $(printf '%-12s %6d %8d %8d %10d' "$lv" "$LPS" "$PPS" "$COPIES" $(( PPS * PPSIZE )))"
done

vsay "  ----------------------------------------------"

if (( REQ == 0 )); then
    err "none of the expected BOS logical volumes were found - is this rootvg?"
    exit 3
fi

REQ_MARGIN=$(( REQ + ( REQ * MARGIN / 100 ) ))

#=============================================================================
# Per-PV free space and boot eligibility
#=============================================================================
BOOTFREE=0
if (( VERBOSE )); then
    say ""
    say "Free space by physical volume:"
    say "  PV           Total PPs   Free PPs   Free(MB)   Bootable"
    say "  ------------------------------------------------------"
fi

lsvg -p rootvg 2>/dev/null | awk 'NR>2 && $1 != "" {print $1, $3, $4}' | while read pv tot free; do
    [[ "$free" = +([0-9]) ]] || continue
    if bootinfo -B "$pv" 2>/dev/null | grep -q '^1'; then
        BOOTABLE="yes"
        BOOTFREE=$(( BOOTFREE + free ))
    else
        BOOTABLE="no"
    fi
    (( VERBOSE )) && say "  $(printf '%-12s %9d %10d %10d   %s' "$pv" "$tot" "$free" $(( free * PPSIZE )) "$BOOTABLE")"
    print "$BOOTFREE" > /tmp/.mbpc.bootfree.$$
done
[[ -r /tmp/.mbpc.bootfree.$$ ]] && BOOTFREE=$(cat /tmp/.mbpc.bootfree.$$)
rm -f /tmp/.mbpc.bootfree.$$ 2>/dev/null

#=============================================================================
# Report
#=============================================================================
say ""
say "multibos -s space check on $(hostname)"
say "-----------------------------------------------------------"
say "  PP size                 : ${PPSIZE} MB"
say "  rootvg total / free PPs : ${TOTPP} / ${FREEPP}  (${FREEPP} PPs = $(( FREEPP * PPSIZE )) MB)"
say "  rootvg mirrored         : $( (( MIRRORED )) && print yes || print no )"
say "  Required (raw)          : ${REQ} PPs ($(( REQ * PPSIZE )) MB)"
say "  Required (+${MARGIN}% margin) : ${REQ_MARGIN} PPs ($(( REQ_MARGIN * PPSIZE )) MB)"
say "-----------------------------------------------------------"

if [[ -n "$MISSING" ]]; then
    say "  NOTE: expected LV(s) not present and therefore not counted: ${MISSING}"
    say "        Verify this is intentional before relying on the figure above."
fi

if (( MIRRORED )); then
    say "  NOTE: rootvg is mirrored. The requirement above uses PPs, so the"
    say "        mirror copies are already accounted for."
fi

#-- Verdict -------------------------------------------------------------------
if (( FREEPP >= REQ_MARGIN )); then
    say ""
    say "RESULT: PASS - ${FREEPP} free PPs against ${REQ_MARGIN} required."
    RC=0
elif (( FREEPP >= REQ )); then
    say ""
    say "RESULT: MARGINAL - ${FREEPP} free PPs covers the raw requirement of"
    say "        ${REQ} but not the ${MARGIN}% margin (${REQ_MARGIN})."
    say "        multibos -sX may still fail if it needs to expand a filesystem."
    RC=1
else
    say ""
    say "RESULT: FAIL - ${FREEPP} free PPs against ${REQ} required."
    say "        Short by $(( REQ - FREEPP )) PPs ($(( (REQ - FREEPP) * PPSIZE )) MB)."
    say "        Shrink a filesystem or add a PV to rootvg."
    RC=1
fi

#-- Boot-eligible free space --------------------------------------------------
if (( BOOTFREE > 0 && BOOTFREE < FREEPP )); then
    say ""
    say "  WARNING: only ${BOOTFREE} of ${FREEPP} free PPs are on bootable PVs."
    say "           bos_hd5 must land on a boot device. Total free space can"
    say "           look adequate while the allocation still fails."
fi

#-- /tmp working space --------------------------------------------------------
TMPFREE=$(df -m /tmp 2>/dev/null | awk 'NR==2 {print int($3)}')
if [[ "$TMPFREE" = +([0-9]) ]] && (( TMPFREE < 128 )); then
    say ""
    say "  WARNING: /tmp has only ${TMPFREE} MB free. multibos writes its logs"
    say "           and working files there. Allow at least 128 MB."
fi

say ""
say "Confirm with multibos's own preview before the change window:"
say "    multibos -sXp"
say ""

exit $RC
