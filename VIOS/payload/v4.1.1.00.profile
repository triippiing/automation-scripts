# @(#)27        1.20  src/bos/etc/profile/profile, cmdsh, bos730, initial_extract 8/9/94 12:01:38
# IBM_PROLOG_BEGIN_TAG
# This is an automatically generated prolog.
#
# bos730 src/bos/etc/profile/profile 1.20
#
# Licensed Materials - Property of IBM
#
# COPYRIGHT International Business Machines Corp. 1989,1994
# All Rights Reserved
#
# US Government Users Restricted Rights - Use, duplication or
# disclosure restricted by GSA ADP Schedule Contract with IBM Corp.
#
# IBM_PROLOG_END_TAG
#
# COMPONENT_NAME: (CMDSH) Shell related commands
#
# FUNCTIONS:
#
# ORIGINS: 3, 26, 27
#
# (C) COPYRIGHT International Business Machines Corp. 1989, 1994
# All Rights Reserved
# Licensed Materials - Property of IBM
#
# US Government Users Restricted Rights - Use, duplication or
# disclosure restricted by GSA ADP Schedule Contract with IBM Corp.
#
################################################################

# System wide profile.  All variables set here may be overridden by
# a user's personal .profile file in their $HOME directory.  However,
# all commands here will be executed at login regardless.

trap "" 1 2 3
readonly LOGNAME

# Automatic logout, include in export line if uncommented
# TMOUT=120

# The MAILMSG will be printed by the shell every MAILCHECK seconds
# (default 600) if there is mail in the MAIL system mailbox.
MAIL=/usr/spool/mail/$LOGNAME
MAILMSG="[YOU HAVE NEW MAIL]"

# If termdef command returns terminal type (i.e. a non NULL value),
# set TERM to the returned value, else set TERM to default lft.
TERM_DEFAULT=lft
TERM=`termdef`
TERM=${TERM:-$TERM_DEFAULT}

# If LC_MESSAGES is set to "C@lft" and TERM is not set to "lft",
# unset LC_MESSAGES.
if [ "$LC_MESSAGES" = "C@lft" -a "$TERM" != "lft" ]
then
        unset LC_MESSAGES
fi

export LOGNAME MAIL MAILMSG TERM

########################################################################
# SE section #
################################################################
# VIOS / AIX global profile
################################################################
# ---------------------------------------------------------------------
# Basic environment
# ---------------------------------------------------------------------
export EDITOR=vi
export VISUAL=vi
export EXTENDED_HISTORY=ON
typeset -r EXTENDED_HISTORY
export HISTSIZE=10000
export HISTFILESIZE=10000
export HISTCONTROL=ignoredups
export HISTTIMEFORMAT='%Y-%m-%d %H:%M:%S '
# ---------------------------------------------------------------------
# Current user
# ---------------------------------------------------------------------
CURUSER="${LOGNAME:-$(whoami)}"
export CURUSER
# ---------------------------------------------------------------------
# Interactive login banner
# ---------------------------------------------------------------------
case "$-" in
    *i*)           # interactive-only stuff should help with scp/automation
        #clear
        echo ""
        echo "========================================="
        echo "           VIOS LOGIN SESSION"
        echo "========================================="
        # -------------------------------------------------------------
        # padmin restricted shell limitations
        # -------------------------------------------------------------
        if [ "${CURUSER}" = "padmin" ]
        then
            echo ""
            echo "Hostname : `/usr/bin/hostname`"
            echo "User     : padmin"
            echo "Date     : $(date)"
            echo ""
        else
            echo ""
            echo "Hostname : $(uname -n)"
            echo "User     : ${CURUSER}"
            echo "Date     : $(date)"
            echo "Uptime   : $(uptime)"
            echo ""
        fi
        ;;
esac
# ---------------------------------------------------------------------
# Leave padmin environment untouched
# ---------------------------------------------------------------------
if [ "${CURUSER}" != "padmin" ]
then
    # -----------------------------------------------------------------
    # Always deploy managed bashrc
    # -----------------------------------------------------------------
    if [ -f /usr/local/bin/default.bashrc ]
    then
        cp /usr/local/bin/default.bashrc "${HOME}/.bashrc"
        chown "$(id -un)":"$(id -gn)" "${HOME}/.bashrc"
        chmod 644 "${HOME}/.bashrc"
    fi
    # -----------------------------------------------------------------
    # Ensure .profile loads .bashrc
    # -----------------------------------------------------------------
    if [ -f "${HOME}/.profile" ]
    then
        grep -q '\.bashrc' "${HOME}/.profile"
        if [ $? -ne 0 ]
        then
            echo '[ -r "${HOME}/.bashrc" ] && . "${HOME}/.bashrc"' >> "${HOME}/.profile"
        fi
    fi
fi
################################################################

trap 1 2 3

