########################################################################
# Standard VIOS bash configuration
########################################################################
# ---------------------------------------------------------------------
# Interactive shells only
# ---------------------------------------------------------------------
  case "$-" in
      *i*) ;;
      *) return ;;
  esac
# ---------------------------------------------------------------------
# Prompt
# ---------------------------------------------------------------------
  SHORT_HOST="$(hostname -s 2>/dev/null)"
  if [ "$(id -u)" -eq 0 ]
  then
      export PS1='[root@'"${SHORT_HOST}"']:${PWD}# '
  else
      export PS1='['"${LOGNAME}"'@'"${SHORT_HOST}"']:${PWD}$ '
  fi
# ---------------------------------------------------------------------
# Group-based shell mode
# ---------------------------------------------------------------------
  USER_GROUPS="$(id -Gn 2>/dev/null)"
  if echo "${USER_GROUPS}" | grep -qw "IBMi_VIO"
  then
      set -o emacs
  else
      set -o vi
  fi
# ---------------------------------------------------------------------
# General aliases
# ---------------------------------------------------------------------
  alias ll='ls -al'
  alias la='ls -A'
  alias l='ls -CF'
  alias h='history'
  alias c='clear'
# ---------------------------------------------------------------------
# VIOS aliases
# ---------------------------------------------------------------------
  alias ioslevel='sudo /usr/ios/cli/ioscli ioslevel'
  alias slmap='sudo /usr/ios/cli/ioscli lsmap'
  alias slmapall='sudo /usr/ios/cli/ioscli lsmap -all'
  alias slmapnpiv='sudo /usr/ios/cli/ioscli lsmap -npiv -all'
  alias lsrep='sudo /usr/ios/cli/ioscli lsrep'
  alias lsvopt='sudo /usr/ios/cli/ioscli lsvopt'
  alias lsdevv='sudo /usr/ios/cli/ioscli lsdev'
  alias errptv='sudo /usr/bin/errpt'
  alias netstatv='sudo /usr/bin/netstat -in'
# ---------------------------------------------------------------------
# Show shell editor mode
# ---------------------------------------------------------------------
  set -o | egrep -w '^vi|^emacs'

