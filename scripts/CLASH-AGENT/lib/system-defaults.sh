#!/usr/bin/env bash
# Non-interactive equivalents of the upstream menu's original BBR + FQ choice.
# The caller checks root/Linux; path overrides keep tests away from host settings.

clash_agent_system_error() {
    printf 'CLASH-AGENT: %s\n' "$*" >&2
    return 1
}

clash_agent_enable_bbr() {
    local etc_dir=${CLASH_AGENT_ETC_DIR:-/etc}
    local config_dir="${etc_dir}/sysctl.d" config_file
    local available old_cc old_qdisc temp_file
    config_file="${config_dir}/99-clash-agent.conf"

    command -v sysctl >/dev/null 2>&1 || {
        clash_agent_system_error 'sysctl is required to enable BBR.'; return 1;
    }
    if command -v modprobe >/dev/null 2>&1; then
        modprobe tcp_bbr >/dev/null 2>&1 || true
        modprobe sch_fq >/dev/null 2>&1 || true
    fi
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null) || {
        clash_agent_system_error 'Cannot read available TCP congestion controls.'; return 1;
    }
    case " ${available} " in
        *' bbr '*) ;;
        *) clash_agent_system_error 'This kernel does not provide BBR; no kernel replacement was attempted.'; return 1 ;;
    esac
    old_cc=$(sysctl -n net.ipv4.tcp_congestion_control) || return 1
    old_qdisc=$(sysctl -n net.core.default_qdisc) || return 1
    [[ ! -L "${config_file}" ]] || {
        clash_agent_system_error "Refusing to replace symlink ${config_file}."; return 1;
    }
    mkdir -p "${config_dir}" || return 1
    temp_file=$(mktemp "${config_dir}/.clash-agent.XXXXXX") || return 1
    if ! printf '%s\n' '# Managed by CLASH-AGENT' \
        'net.core.default_qdisc = fq' 'net.ipv4.tcp_congestion_control = bbr' >"${temp_file}"; then
        rm -f "${temp_file}"; return 1
    fi
    if ! sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 ||
        ! sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 ||
        [[ $(sysctl -n net.core.default_qdisc) != fq ]] ||
        [[ $(sysctl -n net.ipv4.tcp_congestion_control) != bbr ]] ||
        ! chmod 644 "${temp_file}" || ! mv -f "${temp_file}" "${config_file}"; then
        sysctl -w "net.core.default_qdisc=${old_qdisc}" >/dev/null 2>&1 || true
        sysctl -w "net.ipv4.tcp_congestion_control=${old_cc}" >/dev/null 2>&1 || true
        rm -f "${temp_file}"
        clash_agent_system_error 'Failed to apply and persist BBR + FQ.'
        return 1
    fi
    printf 'CLASH-AGENT: BBR enabled; default qdisc is fq.\n'
}

clash_agent_active_swap_kib() {
    local proc_swaps=${CLASH_AGENT_PROC_SWAPS:-/proc/swaps}
    [[ -r "${proc_swaps}" ]] || return 1
    awk 'NR > 1 { total += $3 } END { printf "%.0f\n", total }' "${proc_swaps}"
}

clash_agent_ensure_swap() {
    local etc_dir=${CLASH_AGENT_ETC_DIR:-/etc}
    local swap_file=${CLASH_AGENT_SWAP_FILE:-/swapfile-clash-agent}
    local fstab="${etc_dir}/fstab" total page_size required_kib size temp_file created=false already_active=false
    local fstab_state=missing

    case "${swap_file}" in
        /*) ;;
        *) clash_agent_system_error 'Swap path must be absolute.'; return 1 ;;
    esac
    if [[ "${swap_file}" == *[[:space:]\\]* ]]; then
        clash_agent_system_error 'Swap path cannot contain whitespace or backslashes.'
        return 1
    fi
    page_size=$(getconf PAGESIZE 2>/dev/null) || page_size=4096
    [[ "${page_size}" =~ ^[0-9]+$ ]] || page_size=4096
    # A 1 GiB swap file loses one page to its header in /proc/swaps.
    required_kib=$(((1073741824 - page_size) / 1024))
    total=$(clash_agent_active_swap_kib) || {
        clash_agent_system_error 'Cannot read active swap from /proc/swaps.'; return 1;
    }
    if ((total >= required_kib)); then
        if awk -v path="${swap_file}" 'NR > 1 && $1 == path { found = 1 } END { exit !found }' \
            "${CLASH_AGENT_PROC_SWAPS:-/proc/swaps}"; then
            # A previous run may have enabled our file but failed before fstab.
            already_active=true
        else
            printf 'CLASH-AGENT: Existing active swap retained (%s KiB).\n' "${total}"
            return 0
        fi
    fi
    [[ ! -L "${fstab}" ]] || {
        clash_agent_system_error "Refusing to modify symlink ${fstab}."; return 1;
    }
    if [[ -e "${fstab}" ]]; then
        fstab_state=$(awk -v path="${swap_file}" '
            $1 == path && $1 !~ /^#/ {
                if ($3 != "swap" || $4 ~ /(^|,)noauto(,|$)/) bad = 1
                else found = 1
            }
            END { if (bad) print "conflict"; else if (found) print "present"; else print "missing" }
        ' "${fstab}") || return 1
    fi
    [[ "${fstab_state}" != conflict ]] || {
        clash_agent_system_error 'Existing fstab entry conflicts with automatic swap activation.'; return 1;
    }
    if [[ -e "${swap_file}" || -L "${swap_file}" ]]; then
        [[ -f "${swap_file}" && ! -L "${swap_file}" ]] || {
            clash_agent_system_error "Swap path is not a regular file: ${swap_file}."; return 1;
        }
        size=$(wc -c <"${swap_file}") || return 1
        if ((size < 1073741824)) ||
            [[ $(blkid -s TYPE -o value "${swap_file}" 2>/dev/null) != swap ]]; then
            clash_agent_system_error "Existing file is not a reusable 1 GiB swap file: ${swap_file}."
            return 1
        fi
    else
        temp_file=$(mktemp "${swap_file}.XXXXXX") || return 1
        if ! chmod 600 "${temp_file}" ||
            ! dd if=/dev/zero of="${temp_file}" bs=1M count=1024 >/dev/null 2>&1 ||
            ! mkswap "${temp_file}" >/dev/null 2>&1 ||
            ! ln "${temp_file}" "${swap_file}"; then
            rm -f "${temp_file}"
            clash_agent_system_error 'Failed to allocate and initialize the 1 GiB swap file.'
            return 1
        fi
        rm -f "${temp_file}" || return 1
        created=true
    fi
    if ! chmod 600 "${swap_file}" ||
        { [[ "${already_active}" != true ]] && ! swapon "${swap_file}"; }; then
        if [[ "${created}" == true ]]; then rm -f "${swap_file}"; fi
        clash_agent_system_error 'Could not enable the swap file; existing swap was left active.'
        return 1
    fi
    total=$(clash_agent_active_swap_kib) || return 1
    if ((total < required_kib)); then
        clash_agent_system_error 'Swap activation did not provide the requested capacity.'
        return 1
    fi
    if [[ "${fstab_state}" != present ]]; then
        mkdir -p "${etc_dir}" || return 1
        # Prefix a newline as an existing fstab need not end in one.
        printf '\n%s none swap sw 0 0 # CLASH-AGENT\n' "${swap_file}" >>"${fstab}" || {
            clash_agent_system_error 'Swap is active but its fstab entry could not be saved.'; return 1;
        }
    fi
    printf 'CLASH-AGENT: 1 GiB swap file enabled and persisted at %s.\n' "${swap_file}"
}

clash_agent_configure_system() {
    clash_agent_enable_bbr && clash_agent_ensure_swap
}
