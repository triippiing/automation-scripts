# padmin.kshrc - installed to /home/padmin/.kshrc by vios_standardise.ksh / push_files.ksh
export CLI=/usr/ios/cli/ioscli

if [ "$(whoami)" != "root" ]; then
        export PS1="[$(whoami)@$(/usr/bin/hostname)]\$PWD$ "
else
        export PS1="[$(whoami)@$(/usr/bin/hostname)]\$PWD# "
fi

set -o vi

# arrow keys and home/end in ksh vi mode
alias -x __A="$(echo '\020')"
alias -x __B="$(echo '\016')"
alias -x __C="$(echo '\006')"
alias -x __D="$(echo '\002')"
alias -x __H="$(echo '\001')"
alias -x __Y="$(echo '\005')"
