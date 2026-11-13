#!/usr/bin/env bash
# Only the managed TCP/443 jump and its private chains are changed. SSH, other
# ports, other firewall chains and IPv6 rules remain outside this module.
clash_agent_cf_firewall_fetch() {
    curl --proto '=https' -fsS --connect-timeout 10 --max-time 30 https://www.cloudflare.com/ips-v4
}

clash_agent_cf_validate_ranges() {
    python3 -c 'import ipaddress,sys
lines=sorted(set(sys.stdin.read().split()))
if not 1 <= len(lines) <= 100: raise SystemExit("Invalid Cloudflare address list")
for line in lines:
 n=ipaddress.ip_network(line,strict=True)
 if n.version!=4 or not n.is_global or n.prefixlen<8: raise SystemExit("Invalid Cloudflare IPv4 range")
print("\n".join(lines))'
}

clash_agent_cf_firewall_prepare() {
    local ranges
    ranges=$(clash_agent_cf_firewall_fetch) && ranges=$(printf '%s\n' "$ranges" | clash_agent_cf_validate_ranges) || return 1
    printf '%s\n' "$ranges" >"${CA_STATE_DIR}/cloudflare-ipv4"
    { printf 'allow 127.0.0.1;\n'; while read -r range; do printf 'allow %s;\n' "$range"; done <<<"$ranges"; printf 'deny all;\n'; } >"$CA_CF_ALLOW"
}

clash_agent_cf_firewall_refresh() (
    set -e
    umask 077
    local ranges work old= new= created=false installed=false finished=false
    exec 8>"${CA_STATE_DIR}/firewall.lock" || return 1
    flock -w 30 8 || return 1
    work=$(mktemp -d "${CA_STATE_DIR}/.firewall.XXXXXX") || return 1
    trap 'code=$?; if [[ $finished != true ]]; then
        if [[ -f $work/allow.previous ]]; then cp "$work/allow.previous" "$CA_CF_ALLOW"; fi;
        if [[ -n $old ]] && ! iptables -w 5 -C INPUT -p tcp --dport 443 -j "$old" 2>/dev/null; then iptables -w 5 -I INPUT 1 -p tcp --dport 443 -j "$old" || true; fi;
        if [[ $installed == true ]]; then iptables -w 5 -D INPUT -p tcp --dport 443 -j "$new" || true; fi;
        if [[ $created == true ]]; then iptables -w 5 -F "$new" 2>/dev/null || true; iptables -w 5 -X "$new" 2>/dev/null || true; fi;
        if [[ -f $work/chain.previous ]]; then cp "$work/chain.previous" "${CA_STATE_DIR}/firewall-chain"; fi;
      fi; rm -rf "$work"; exit "$code"' EXIT
    if ! ranges=$(clash_agent_cf_firewall_fetch); then
        ranges=$(cat "${CA_STATE_DIR}/cloudflare-ipv4") || return 1
    fi
    ranges=$(printf '%s\n' "$ranges" | clash_agent_cf_validate_ranges) || return 1
    [[ ! -s ${CA_STATE_DIR}/firewall-chain ]] || old=$(cat "${CA_STATE_DIR}/firewall-chain")
    [[ -z $old || $old =~ ^CACF_[a-f0-9]{8}$ ]] || return 1
    [[ -z $old ]] || cp "${CA_STATE_DIR}/firewall-chain" "$work/chain.previous" || return 1
    cp "$CA_CF_ALLOW" "$work/allow.previous" || return 1
    new="CACF_$(openssl rand -hex 4)" || return 1
    iptables -w 5 -N "$new" || return 1
    created=true
    while read -r range; do iptables -w 5 -A "$new" -s "$range" -j ACCEPT || return 1; done <<<"$ranges"
    iptables -w 5 -A "$new" -s 127.0.0.1/32 -j ACCEPT || return 1
    iptables -w 5 -A "$new" -j DROP || return 1
    { printf 'allow 127.0.0.1;\n'; while read -r range; do printf 'allow %s;\n' "$range"; done <<<"$ranges"; printf 'deny all;\n'; } >"$work/allow.new"
    mv -f "$work/allow.new" "$CA_CF_ALLOW" || return 1
    nginx -t || return 1
    iptables -w 5 -I INPUT 1 -p tcp --dport 443 -j "$new" || return 1
    installed=true
    if [[ ${CA_CF_NO_RELOAD:-false} != true ]] && systemctl is-active --quiet nginx.service; then systemctl reload nginx.service || return 1; fi
    if [[ -n $old ]] && iptables -w 5 -C INPUT -p tcp --dport 443 -j "$old" 2>/dev/null; then
        iptables -w 5 -D INPUT -p tcp --dport 443 -j "$old" || return 1
    fi
    printf '%s\n' "$ranges" >"${CA_STATE_DIR}/cloudflare-ipv4" || return 1
    printf '%s\n' "$new" >"${CA_STATE_DIR}/firewall-chain" || return 1
    finished=true
    if [[ -n $old && ${CA_CF_KEEP_PREVIOUS:-false} != true ]]; then
        iptables -w 5 -F "$old" 2>/dev/null || true
        iptables -w 5 -X "$old" 2>/dev/null || true
    fi
)

clash_agent_cf_firewall_setup() {
    local script="${CA_STATE_DIR}/refresh-firewall.sh"
    {
        printf '#!/usr/bin/env bash\nexport PATH=/usr/sbin:/usr/bin:/sbin:/bin\n'
        printf 'CA_STATE_DIR=%q\nCA_CF_ALLOW=%q\n' "$CA_STATE_DIR" "$CA_CF_ALLOW"
        declare -f clash_agent_cf_firewall_fetch clash_agent_cf_validate_ranges clash_agent_cf_firewall_refresh
        printf '\nclash_agent_cf_firewall_refresh\n'
    } >"$script"
    chmod 700 "$script" || return 1
    cat >"${CA_UNIT_DIR}/clash-agent-cf-firewall.service" <<EOF
[Unit]
Description=CLASH-AGENT Cloudflare HTTPS origin firewall
Wants=network-online.target
After=network-online.target
Before=nginx.service
[Service]
Type=oneshot
RemainAfterExit=yes
Environment=CA_CF_NO_RELOAD=true
ExecStart=${script}
[Install]
WantedBy=multi-user.target
EOF
    cat >"${CA_UNIT_DIR}/clash-agent-cf-refresh.service" <<EOF
[Unit]
Description=Refresh CLASH-AGENT Cloudflare origin addresses
After=network-online.target
[Service]
Type=oneshot
ExecStart=${script}
EOF
    cat >"${CA_UNIT_DIR}/clash-agent-cf-firewall.timer" <<'EOF'
[Unit]
Description=Refresh Cloudflare origin address ranges weekly
[Timer]
OnCalendar=weekly
RandomizedDelaySec=1h
Persistent=true
Unit=clash-agent-cf-refresh.service
[Install]
WantedBy=timers.target
EOF
    mkdir -p "${CA_UNIT_DIR}/nginx.service.d" || return 1
    cat >"${CA_UNIT_DIR}/nginx.service.d/clash-agent-cloudflare.conf" <<'EOF'
[Unit]
Requires=clash-agent-cf-firewall.service
After=clash-agent-cf-firewall.service
EOF
    CA_CF_KEEP_PREVIOUS=true clash_agent_cf_firewall_refresh || return 1
    systemctl daemon-reload && systemctl enable clash-agent-cf-firewall.service &&
        systemctl enable --now clash-agent-cf-firewall.timer
}

clash_agent_cf_firewall_restore() {
    local current= previous= index path
    [[ -f ${CA_STATE_DIR}/firewall-chain ]] && current=$(cat "${CA_STATE_DIR}/firewall-chain")
    while IFS=$'\t' read -r index path; do
        if [[ $path == "${CA_STATE_DIR}/firewall-chain" && $index != absent ]]; then previous=$(cat "$CA_CF_BACKUP/$index"); fi
    done <"$CA_CF_BACKUP/files"
    if [[ -n $previous && $previous =~ ^CACF_[a-f0-9]{8}$ ]]; then
        if ! iptables -w 5 -C INPUT -p tcp --dport 443 -j "$previous" 2>/dev/null; then
            iptables -w 5 -I INPUT 1 -p tcp --dport 443 -j "$previous" || return 1
        fi
    fi
    if [[ -n $current && $current != "$previous" && $current =~ ^CACF_[a-f0-9]{8}$ ]]; then
        iptables -w 5 -D INPUT -p tcp --dport 443 -j "$current" || return 1
        iptables -w 5 -F "$current" && iptables -w 5 -X "$current"
    fi
}
