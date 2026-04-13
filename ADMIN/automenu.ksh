#!/bin/ksh
# =============================================================================
# automenu.ksh - Root Automation Menu Launcher
# Location  : /software/automation/automenu.ksh
# Purpose   : Interactive menu for all automation scripts
# Shell     : KornShell (ksh) - AIX compatible
# Invoked   : Via /root/.profile on interactive login
# =============================================================================

SCRIPT_DIR="/software/automation"

# -----------------------------------------------------------------------------
# Colour / terminal helpers (tput with fallback)
# -----------------------------------------------------------------------------
if tput colors >/dev/null 2>&1 && [ "$(tput colors)" -ge 8 ]; then
    C_RESET=$(tput sgr0)
    C_BOLD=$(tput bold)
    C_CYAN=$(tput setaf 6)
    C_GREEN=$(tput setaf 2)
    C_YELLOW=$(tput setaf 3)
    C_RED=$(tput setaf 1)
    C_WHITE=$(tput setaf 7)
else
    C_RESET="" ; C_BOLD="" ; C_CYAN="" ; C_GREEN=""
    C_YELLOW="" ; C_RED="" ; C_WHITE=""
fi

# -----------------------------------------------------------------------------
# draw_banner
# -----------------------------------------------------------------------------
draw_banner() {
    clear
    printf "%s" "${C_CYAN}${C_BOLD}"
    printf "+=======================================================+\n"
    printf "|          ROOT AUTOMATION MENU                         |\n"
    printf "|          Host: %-37s|\n" "$(hostname)"
    printf "|          Date: %-37s|\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "+=======================================================+\n"
    printf "%s\n" "${C_RESET}"
}

# -----------------------------------------------------------------------------
# draw_menu
# -----------------------------------------------------------------------------
draw_menu() {
    printf "%s  SYSTEM & DIAGNOSTICS%s\n" "${C_YELLOW}${C_BOLD}" "${C_RESET}"
    printf "  %s[1]%s  sysinfo.sh             - AIX system info gather (hardware/net/storage)\n" \
        "${C_GREEN}" "${C_RESET}"
    printf "  %s[2]%s  fsmonitor.sh           - Filesystem usage monitor / alerting\n" \
        "${C_GREEN}" "${C_RESET}"
    printf "  %s[3]%s  perftuning.ksh         - AIX performance tuning (disk/net/ODM)\n" \
        "${C_GREEN}" "${C_RESET}"
    printf "\n"
    printf "%s  BACKUP & RECOVERY%s\n" "${C_YELLOW}${C_BOLD}" "${C_RESET}"
    printf "  %s[4]%s  tsmsnap.ksh            - TSM on-demand snapshot backup\n" \
        "${C_GREEN}" "${C_RESET}"
    printf "  %s[5]%s  tsm_restore_prep.sh    - TSM DR restore prep (pre/post/dryrun)\n" \
        "${C_GREEN}" "${C_RESET}"
    printf "\n"
    printf "%s  ORACLE / RMAN SCHEDULING%s\n" "${C_YELLOW}${C_BOLD}" "${C_RESET}"
    printf "  %s[6]%s  L0L1rmanschedcreator.sh  - RMAN L0/L1 incremental schedule builder\n" \
        "${C_GREEN}" "${C_RESET}"
    printf "  %s[7]%s  L0MYrmanschedcreator.sh  - RMAN L0 MySQL schedule builder\n" \
        "${C_GREEN}" "${C_RESET}"
    printf "\n"
    printf "%s  MENU OPTIONS%s\n" "${C_YELLOW}${C_BOLD}" "${C_RESET}"
    printf "  %s[r]%s  Refresh menu\n" "${C_CYAN}" "${C_RESET}"
    printf "  %s[s]%s  Spawn subshell (return to menu with 'exit')\n" "${C_CYAN}" "${C_RESET}"
    printf "  %s[q]%s  Quit menu (returns to shell)\n" "${C_RED}" "${C_RESET}"
    printf "\n"
    printf "%s+-------------------------------------------------------+%s\n" \
        "${C_CYAN}" "${C_RESET}"
}

# -----------------------------------------------------------------------------
# script_exists  - validate before exec, warn cleanly if missing
# -----------------------------------------------------------------------------
script_exists() {
    typeset script="$1"
    if [ ! -f "${SCRIPT_DIR}/${script}" ]; then
        printf "%s[ERROR]%s Script not found: %s/%s\n" \
            "${C_RED}" "${C_RESET}" "${SCRIPT_DIR}" "${script}"
        return 1
    fi
    if [ ! -x "${SCRIPT_DIR}/${script}" ]; then
        printf "%s[ERROR]%s Script not executable: %s/%s\n" \
            "${C_RED}" "${C_RESET}" "${SCRIPT_DIR}" "${script}"
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# run_script  - exec with optional arg prompt, pause on return
# -----------------------------------------------------------------------------
run_script() {
    typeset script="$1"
    typeset description="$2"
    typeset args=""

    script_exists "${script}" || { pause_return; return; }

    printf "\n%s--- Launching: %s ---%s\n" "${C_CYAN}${C_BOLD}" "${script}" "${C_RESET}"
    printf "Description : %s\n" "${description}"
    printf "Path        : %s/%s\n\n" "${SCRIPT_DIR}" "${script}"

    printf "Enter arguments (or press ENTER for none): "
    read args

    printf "%s\n" "${C_CYAN}+-------------------------------------------------------+${C_RESET}"

    if [ -n "${args}" ]; then
        # Use eval to honour quoted arg groups passed interactively
        eval "${SCRIPT_DIR}/${script}" ${args}
    else
        "${SCRIPT_DIR}/${script}"
    fi

    typeset rc=$?
    printf "\n%s+-------------------------------------------------------+%s\n" \
        "${C_CYAN}" "${C_RESET}"
    printf "Script exited with return code: %s%d%s\n" \
        "$([ ${rc} -eq 0 ] && printf '%s' "${C_GREEN}" || printf '%s' "${C_RED}")" \
        "${rc}" "${C_RESET}"
    pause_return
}

# -----------------------------------------------------------------------------
# pause_return
# -----------------------------------------------------------------------------
pause_return() {
    printf "\nPress ENTER to return to menu..."
    read _dummy
}

# -----------------------------------------------------------------------------
# spawn_subshell
# -----------------------------------------------------------------------------
spawn_subshell() {
    printf "\n%s[INFO]%s Spawning subshell. Type 'exit' to return to automation menu.\n\n" \
        "${C_YELLOW}" "${C_RESET}"
    ${SHELL:-/bin/ksh}
}

# -----------------------------------------------------------------------------
# main_loop
# -----------------------------------------------------------------------------
main_loop() {
    typeset choice

    while true; do
        draw_banner
        draw_menu
        printf "Select option: "
        read choice

        case "${choice}" in
            1)  run_script "sysinfo.sh" \
                    "AIX system info gather - hardware, storage, networking, PowerHA" ;;
            2)  run_script "fsmonitor.sh" \
                    "Filesystem usage monitor with threshold alerting" ;;
            3)  run_script "perftuning.ksh" \
                    "AIX perf tuning - disk, network adapters, ioo/no/acfo/ODM tunables" ;;
            4)  run_script "tsmsnap.ksh" \
                    "TSM on-demand snapshot backup" ;;
            5)  run_script "tsm_restore_prep.sh" \
                    "TSM DR restore prep - use --prerestore, --postrestore, or --dryrun [--vg <name>]" ;;
            6)  run_script "L0L1rmanschedcreator.sh" \
                    "RMAN L0/L1 incremental schedule creator" ;;
            7)  run_script "L0MYrmanschedcreator.sh" \
                    "RMAN L0 MySQL schedule creator" ;;
            r|R) continue ;;
            s|S) spawn_subshell ;;
            q|Q)
                printf "\n%s[INFO]%s Exiting automation menu. Shell available.\n\n" \
                    "${C_YELLOW}" "${C_RESET}"
                break ;;
            *)
                printf "\n%s[WARN]%s Invalid selection: '%s'\n" \
                    "${C_YELLOW}" "${C_RESET}" "${choice}"
                pause_return ;;
        esac
    done
}

# =============================================================================
# Entry point
# Defensive: do not launch menu if stdin is not a terminal (e.g. cron, ssh cmd)
# =============================================================================
if [ ! -t 0 ]; then
    # Non-interactive context - silently do nothing
    return 0 2>/dev/null || exit 0
fi

# Root check - menu is root-only, warn and abort if not
if [ "$(id -u)" -ne 0 ]; then
    printf "[WARN] automenu.ksh is intended for root only. Skipping.\n" >&2
    return 0 2>/dev/null || exit 1
fi

main_loop
