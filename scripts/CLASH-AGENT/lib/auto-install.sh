#!/usr/bin/env bash
# Thin orchestration: retain upstream core installer, key generation, Reality
# emitter and service registration; replace interactive choices with defaults.

clash_agent_error() { printf 'CLASH-AGENT: %s\n' "$*" >&2; return 1; }

clash_agent_paths() {
    CA_STATE_DIR=${CLASH_AGENT_STATE_DIR:-/etc/clash-agent}
    CA_CORE_DIR=${CLASH_AGENT_CORE_DIR:-/etc/v2ray-agent}
    CA_PROFILE_DIR=${CLASH_AGENT_PROFILE_DIR:-/var/lib/clash-agent}
    CA_UNIT_DIR=${CLASH_AGENT_UNIT_DIR:-/etc/systemd/system}
    CA_LOCK_FILE=${CLASH_AGENT_LOCK_FILE:-/run/clash-agent/install.lock}
    CA_STATE_FILE="${CA_STATE_DIR}/state.json"
    CA_BINARY="${CA_CORE_DIR}/sing-box/sing-box"
    CA_CONF_DIR="${CA_CORE_DIR}/sing-box/conf"
}

clash_agent_check_host() {
    [[ $(uname -s) == Linux && $(id -u) == 0 ]] || { clash_agent_error 'Run as root on a Linux VPS.'; return 1; }
    [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null && command -v flock >/dev/null || {
        clash_agent_error 'A running systemd host and flock are required.'; return 1;
    }
    CA_OS=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
    [[ $CA_OS == debian || $CA_OS == ubuntu ]] || { clash_agent_error 'Automatic installation supports Debian and Ubuntu.'; return 1; }
    case $(uname -m) in x86_64|amd64|aarch64|armv8) ;; *) clash_agent_error 'Supported architectures: amd64 and arm64.'; return 1 ;; esac
}

clash_agent_preflight() {
    clash_agent_check_host || return 1
    [[ ! -L $CA_STATE_DIR && ! -L $CA_CORE_DIR && ! -L $CA_PROFILE_DIR ]] || { clash_agent_error 'Managed directories cannot be symlinks.'; return 1; }
    if [[ -f ${CA_STATE_DIR}/owner && $(cat "${CA_STATE_DIR}/owner") == CLASH-AGENT ]]; then
        return 0
    fi
    if [[ -e $CA_STATE_DIR || -e $CA_CORE_DIR || -e $CA_PROFILE_DIR || -e ${CA_UNIT_DIR}/clash-agent-subscription.service ]] ||
        systemctl cat sing-box.service >/dev/null 2>&1; then
        clash_agent_error 'An unmanaged installation exists; it was left unchanged. Use a fresh VPS or migrate it explicitly.'
        return 1
    fi
}

clash_agent_install_dependencies() {
    local spec command package had_nginx=false
    local -a packages=()
    command -v nginx >/dev/null 2>&1 && had_nginx=true
    for spec in curl:curl wget:wget jq:jq openssl:openssl tar:tar ss:iproute2 sysctl:procps \
        mkswap:util-linux swapon:util-linux blkid:util-linux modprobe:kmod sudo:sudo nginx:nginx \
        fail2ban-client:fail2ban iptables:iptables nft:nftables; do
        command=${spec%%:*}; package=${spec#*:}
        command -v "$command" >/dev/null 2>&1 || packages+=("$package")
    done
    # The systemd journal backend needs the distro Python binding even when
    # fail2ban is already installed and apt recommendations are disabled.
    /usr/bin/python3 -c 'import systemd.journal' >/dev/null 2>&1 || packages+=(python3-systemd)
    if ((${#packages[@]})); then
        DEBIAN_FRONTEND=noninteractive apt-get update || return 1
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates "${packages[@]}" || return 1
    fi
    # A fresh distro nginx package auto-enables its default site. Use a separate
    # CLASH-AGENT instance instead; preserve a previously installed nginx service.
    if [[ $had_nginx == false ]]; then systemctl disable --now nginx.service || return 1; fi
}

clash_agent_prepare_core() {
    initVar ''
    release=$CA_OS
    selectCoreType=2
    lastInstallationConfig=true
    checkCPUVendor
    mkdirTools || return 1
    if [[ ! -x $CA_BINARY ]]; then installSingBox 1 || return 1; fi
    "$CA_BINARY" version >/dev/null || return 1
}

clash_agent_detect_ip() {
    local candidate=${CLASH_AGENT_SERVER_IP:-} family url
    if [[ -n $candidate ]]; then
        clash_agent_subscription_valid_ip "$candidate" || { clash_agent_error 'Invalid CLASH_AGENT_SERVER_IP.'; return 1; }
        printf '%s\n' "$candidate"; return 0
    fi
    for family in -4 -6; do
        for url in https://api64.ipify.org https://icanhazip.com; do
            candidate=$(curl "$family" -fsS --connect-timeout 4 --max-time 8 "$url" 2>/dev/null) || continue
            if clash_agent_subscription_valid_ip "$candidate"; then printf '%s\n' "$candidate"; return 0; fi
        done
    done
    clash_agent_error 'Public IP detection failed. Set CLASH_AGENT_SERVER_IP explicitly.'
}

clash_agent_random_port() {
    local exclude=${1:-0} hex port listeners attempt
    for ((attempt=0; attempt<128; attempt++)); do
        hex=$(openssl rand -hex 2) || return 1
        port=$((10000 + 16#$hex % 50001))
        [[ $port != "$exclude" ]] || continue
        listeners=$(ss -H -lntu "sport = :${port}") || return 1
        if [[ -z $listeners ]]; then printf '%s\n' "$port"; return 0; fi
    done
    clash_agent_error 'Could not find a free random port.'
}

clash_agent_probe_sni() {
    local host=$1 trace
    [[ $host =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && $host != *..* ]] || return 1
    timeout 8 openssl s_client -connect "${host}:443" -servername "$host" -tls1_3 \
        -verify_return_error -verify_hostname "$host" </dev/null >/dev/null 2>&1 || return 1
    trace=$(curl -fsS --connect-timeout 3 --max-time 5 "https://${host}/cdn-cgi/trace" 2>/dev/null) || trace=
    [[ $trace != *visit_scheme=https* ]]
}

clash_agent_select_sni() {
    local candidate count=0
    if [[ -n ${CLASH_AGENT_SERVER_NAME:-} ]]; then
        clash_agent_probe_sni "$CLASH_AGENT_SERVER_NAME" || { clash_agent_error 'The supplied Reality SNI did not pass the TLS 1.3 check.'; return 1; }
        printf '%s\n' "$CLASH_AGENT_SERVER_NAME"; return 0
    fi
    while IFS= read -r candidate; do
        count=$((count+1))
        if clash_agent_probe_sni "$candidate"; then printf '%s\n' "$candidate"; return 0; fi
        ((count < 8)) || break
    done < <(realityServerNames | tr ',' '\n' | shuf)
    clash_agent_error 'No reachable Reality SNI passed the TLS check; set CLASH_AGENT_SERVER_NAME.'
}

clash_agent_write_state() {
    local status=$1 tmp
    tmp=$(mktemp "${CA_STATE_DIR}/.state.XXXXXX") || return 1
    if ! jq -n --arg status "$status" --arg server "$CA_SERVER" --arg sni "$CA_SNI" \
        --arg uuid "$CA_UUID" --arg private "$CA_PRIVATE_KEY" --arg public "$CA_PUBLIC_KEY" \
        --arg sid "$CA_SHORT_ID" --arg token "$CA_TOKEN" --arg name "$CA_NODE_NAME" \
        --argjson port "$CA_REALITY_PORT" --argjson sub_port "$CA_SUB_PORT" \
        '{product:"CLASH-AGENT",schema:1,status:$status,server:$server,sni:$sni,uuid:$uuid,
          private_key:$private,public_key:$public,short_id:$sid,token:$token,node_name:$name,
          reality_port:$port,subscription_port:$sub_port}' >"$tmp" ||
        ! chmod 600 "$tmp" || ! mv -f "$tmp" "$CA_STATE_FILE"; then
        rm -f "$tmp"; return 1
    fi
}

clash_agent_read_state() {
    [[ -f $CA_STATE_FILE && ! -L $CA_STATE_FILE ]] || { clash_agent_error 'No CLASH-AGENT state file found.'; return 1; }
    jq -e '.product == "CLASH-AGENT" and .schema == 1 and
        (.reality_port | type == "number") and (.subscription_port | type == "number")' "$CA_STATE_FILE" >/dev/null || return 1
    CA_SERVER=$(jq -er .server "$CA_STATE_FILE") || return 1
    CA_SNI=$(jq -er .sni "$CA_STATE_FILE") || return 1
    CA_UUID=$(jq -er .uuid "$CA_STATE_FILE") || return 1
    CA_PRIVATE_KEY=$(jq -er .private_key "$CA_STATE_FILE") || return 1
    CA_PUBLIC_KEY=$(jq -er .public_key "$CA_STATE_FILE") || return 1
    CA_SHORT_ID=$(jq -er .short_id "$CA_STATE_FILE") || return 1
    CA_TOKEN=$(jq -er .token "$CA_STATE_FILE") || return 1
    CA_NODE_NAME=$(jq -er .node_name "$CA_STATE_FILE") || return 1
    CA_REALITY_PORT=$(jq -er .reality_port "$CA_STATE_FILE") || return 1
    CA_SUB_PORT=$(jq -er .subscription_port "$CA_STATE_FILE") || return 1
    CA_STATUS=$(jq -er .status "$CA_STATE_FILE") || return 1
    [[ $CA_STATUS == ready || $CA_STATUS == installing ]] || return 1
    [[ $CA_PRIVATE_KEY =~ ^[A-Za-z0-9_-]{43}$ && $CA_REALITY_PORT != "$CA_SUB_PORT" ]] || return 1
    clash_agent_subscription_valid_token "$CA_TOKEN" && clash_agent_subscription_valid_port "$CA_SUB_PORT" || return 1
    clash_agent_render_clash_profile "$CA_SERVER" "$CA_REALITY_PORT" "$CA_UUID" "$CA_PUBLIC_KEY" "$CA_SHORT_ID" "$CA_SNI" "$CA_NODE_NAME" >/dev/null
}

clash_agent_prepare_state() {
    if [[ -e $CA_STATE_FILE || -L $CA_STATE_FILE ]]; then clash_agent_read_state; return; fi
    CA_SERVER=$(clash_agent_detect_ip) || return 1
    CA_SNI=$(clash_agent_select_sni) || return 1
    CA_REALITY_PORT=$(clash_agent_random_port) || return 1
    CA_SUB_PORT=$(clash_agent_random_port "$CA_REALITY_PORT") || return 1
    CA_UUID=$("$CA_BINARY" generate uuid) || return 1
    initRealityKey || return 1
    CA_PRIVATE_KEY=$realityPrivateKey; CA_PUBLIC_KEY=$realityPublicKey
    [[ $CA_PRIVATE_KEY =~ ^[A-Za-z0-9_-]{43}$ && $CA_PUBLIC_KEY =~ ^[A-Za-z0-9_-]{43}$ ]] || { clash_agent_error 'Reality key generation failed.'; return 1; }
    CA_SHORT_ID=$(openssl rand -hex 8) || return 1
    CA_TOKEN=$(openssl rand -hex 32) || return 1
    CA_NODE_NAME="CLASH-AGENT-$(openssl rand -hex 4)" || return 1
    clash_agent_write_state installing && clash_agent_read_state
}

clash_agent_write_core_config() {
    local fragment="${CA_CONF_DIR}/config/07_VLESS_vision_reality_inbounds.json" tmp listen=0.0.0.0
    realityServerName=$CA_SNI; realityDomainPort=443; realityPrivateKey=$CA_PRIVATE_KEY
    currentClients=$(jq -cn --arg uuid "$CA_UUID" --arg name "${CA_NODE_NAME##*-}" '[{uuid:$uuid,name:$name,flow:"xtls-rprx-vision"}]') || return 1
    mkdir -p "${CA_CONF_DIR}/config" || return 1
    writeSingBoxRealityInbound "${fragment}.new" "$CA_REALITY_PORT" "[\"${CA_SHORT_ID}\"]" || return 1
    [[ ! -r /proc/net/if_inet6 ]] || ! grep -q . /proc/net/if_inet6 || listen=::
    tmp=$(mktemp "${CA_CONF_DIR}/.config.XXXXXX") || return 1
    if ! jq --arg listen "$listen" '.inbounds[0].listen=$listen |
        . + {log:{level:"warn",timestamp:true},outbounds:[{type:"direct",tag:"direct"}]}' "${fragment}.new" >"$tmp" ||
        ! "$CA_BINARY" check -c "$tmp" || ! chmod 600 "$tmp" "${fragment}.new" ||
        ! mv -f "$tmp" "${CA_CONF_DIR}/config.json" || ! mv -f "${fragment}.new" "$fragment"; then
        rm -f "$tmp" "${fragment}.new"; return 1
    fi
}

clash_agent_write_subscription() {
    local ipv6=false nginx_binary
    [[ ! -r /proc/net/if_inet6 ]] || ! grep -q . /proc/net/if_inet6 || ipv6=true
    mkdir -p "$CA_PROFILE_DIR" "$CA_UNIT_DIR" || return 1
    chmod 755 "$CA_PROFILE_DIR" || return 1
    clash_agent_render_clash_profile "$CA_SERVER" "$CA_REALITY_PORT" "$CA_UUID" "$CA_PUBLIC_KEY" "$CA_SHORT_ID" "$CA_SNI" "$CA_NODE_NAME" >"${CA_PROFILE_DIR}/clash.yaml.new" || return 1
    chmod 644 "${CA_PROFILE_DIR}/clash.yaml.new" && mv -f "${CA_PROFILE_DIR}/clash.yaml.new" "${CA_PROFILE_DIR}/clash.yaml" || return 1
    clash_agent_render_subscription_nginx "$CA_SUB_PORT" "${CA_PROFILE_DIR}/clash.yaml" "$CA_TOKEN" "$ipv6" >"${CA_STATE_DIR}/subscription.conf" || return 1
    cat >"${CA_STATE_DIR}/nginx.conf" <<EOF
user www-data;
worker_processes 1;
pid /run/clash-agent-subscription.pid;
error_log stderr warn;
events { worker_connections 128; }
http { access_log off; include ${CA_STATE_DIR}/subscription.conf; }
EOF
    nginx_binary=$(command -v nginx) || return 1
    cat >"${CA_UNIT_DIR}/clash-agent-subscription.service" <<EOF
[Unit]
Description=CLASH-AGENT Clash subscription
After=network.target
[Service]
Type=simple
ExecStart=${nginx_binary} -p ${CA_PROFILE_DIR}/ -c ${CA_STATE_DIR}/nginx.conf -g 'daemon off;'
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    nginx -t -p "${CA_PROFILE_DIR}/" -c "${CA_STATE_DIR}/nginx.conf"
}

clash_agent_open_port() {
    local port=$1 status
    # Contain legacy exit statements, then verify the active firewall manager.
    ( allowPort "$port" tcp ) || return 1
    if command -v ufw >/dev/null 2>&1; then
        status=$(ufw status) || return 1
        if [[ $status == *'Status: active'* ]]; then
            printf '%s\n' "$status" | grep -Eq "^${port}/tcp[[:space:]].*ALLOW" || return 1
        fi
    fi
    if systemctl is-active --quiet firewalld; then
        firewall-cmd --zone=public --query-port="${port}/tcp" >/dev/null || return 1
    fi
}

clash_agent_verify_services() {
    systemctl is-active --quiet sing-box.service && systemctl is-active --quiet clash-agent-subscription.service
}

clash_agent_check_subscription() {
    local downloaded url
    downloaded=$(mktemp "${CA_STATE_DIR}/.subscription-check.XXXXXX") || return 1
    url=$(clash_agent_subscription_url 127.0.0.1 "$CA_SUB_PORT" "$CA_TOKEN") || return 1
    if ! curl --noproxy '*' -fsS --retry 3 --retry-connrefused --retry-delay 1 --connect-timeout 3 --max-time 10 "$url" -o "$downloaded" ||
        ! cmp -s "$downloaded" "${CA_PROFILE_DIR}/clash.yaml"; then
        rm -f "$downloaded"; clash_agent_error 'The subscription endpoint did not serve the expected Clash profile.'; return 1
    fi
    rm -f "$downloaded"
}

clash_agent_verify_system() {
    local swap_kib page_size
    [[ $(sysctl -n net.ipv4.tcp_congestion_control) == bbr && $(sysctl -n net.core.default_qdisc) == fq ]] || return 1
    page_size=$(getconf PAGESIZE) || return 1
    swap_kib=$(clash_agent_active_swap_kib) || return 1
    ((swap_kib >= (1073741824 - page_size) / 1024))
}

clash_agent_print_result() {
    local url
    url=$(clash_agent_subscription_url "$CA_SERVER" "$CA_SUB_PORT" "$CA_TOKEN") || return 1
    printf '\nCLASH-AGENT configured: Reality + Vision, BBR + fq, swap >= 1 GiB, fail2ban SSH protection.\n'
    printf 'SSH protection: 5 failures in 10 minutes trigger a 1-hour ban.\n'
    printf 'Reality TCP port: %s\nSubscription TCP port: %s\n' "$CA_REALITY_PORT" "$CA_SUB_PORT"
    printf 'Clash.Meta / mihomo subscription (HTTP; keep this URL private):\n%s\n' "$url"
    printf 'State: %s\nAllow the two TCP ports in any provider security group.\n' "$CA_STATE_FILE"
}

clash_agent_install() (
    umask 077
    clash_agent_paths
    clash_agent_preflight || return 1
    export PATH="${PATH}:/usr/sbin:/sbin"
    # /run/lock can be world-writable. Keep our lock inside a private directory
    # under root-owned /run, and never truncate an existing lock target.
    [[ ! -L ${CA_LOCK_FILE%/*} && ! -L $CA_LOCK_FILE ]] || return 1
    mkdir -p "${CA_LOCK_FILE%/*}" && chmod 700 "${CA_LOCK_FILE%/*}" || return 1
    exec 9>>"$CA_LOCK_FILE" || return 1
    flock -n 9 || { clash_agent_error 'Another CLASH-AGENT installation is running.'; return 1; }
    # Recheck ownership after taking the lock to prevent concurrent first installs.
    clash_agent_preflight || return 1
    mkdir -p "$CA_STATE_DIR" || return 1
    chmod 700 "$CA_STATE_DIR" || return 1
    printf 'CLASH-AGENT\n' >"${CA_STATE_DIR}/owner" || return 1
    clash_agent_install_dependencies || return 1
    clash_agent_prepare_core || return 1
    clash_agent_prepare_state || return 1
    clash_agent_write_state installing || return 1
    clash_agent_configure_system || return 1
    clash_agent_configure_fail2ban || return 1
    clash_agent_write_core_config || return 1
    installSingBoxService 2 defer || return 1
    clash_agent_write_subscription || return 1
    clash_agent_open_port "$CA_REALITY_PORT" && clash_agent_open_port "$CA_SUB_PORT" || return 1
    systemctl daemon-reload && systemctl enable sing-box.service clash-agent-subscription.service || return 1
    systemctl restart sing-box.service clash-agent-subscription.service || return 1
    clash_agent_verify_services && clash_agent_check_subscription && clash_agent_verify_fail2ban || return 1
    clash_agent_write_state ready || return 1
    clash_agent_print_result
)
