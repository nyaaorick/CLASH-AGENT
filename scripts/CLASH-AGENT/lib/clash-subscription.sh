#!/usr/bin/env bash
# Pure renderers for the upstream VLESS + Reality Clash/Mihomo schema.
# No installer, service, firewall, or system configuration is executed here.

clash_agent_subscription_error() {
    printf 'CLASH-AGENT: %s\n' "$1" >&2
    return 1
}

clash_agent_subscription_valid_port() {
    [[ ${1:-} =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

clash_agent_subscription_valid_ipv4() {
    local value=${1:-} octet
    local -a octets
    [[ $value =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<<"$value"
    for octet in "${octets[@]}"; do
        [[ $octet == 0 || $octet != 0* ]] || return 1
        ((10#$octet <= 255)) || return 1
    done
}

clash_agent_subscription_valid_ip() {
    local address=${1:-} tail group count=0 compressed=false
    local -a groups
    if [[ $address != *:* ]]; then
        clash_agent_subscription_valid_ipv4 "$address"
        return
    fi
    # IPv4-mapped IPv6 still occupies two of the eight IPv6 groups.
    if [[ $address == *.* ]]; then
        tail=${address##*:}
        clash_agent_subscription_valid_ipv4 "$tail" || return 1
        address=${address%:*}:0:0
    fi
    [[ $address =~ ^[0-9a-fA-F:]+$ && $address != *:::* ]] || return 1
    [[ $address != :* || $address == ::* ]] || return 1
    [[ $address != *: || $address == *:: ]] || return 1
    if [[ $address == *::* ]]; then
        compressed=true
        tail=${address#*::}
        [[ $tail != *::* ]] || return 1
    fi
    IFS=: read -r -a groups <<<"$address"
    for group in "${groups[@]}"; do
        [[ -n $group ]] || continue
        ((${#group} <= 4)) || return 1
        count=$((count + 1))
    done
    if [[ $compressed == true ]]; then
        ((count < 8))
    else
        ((count == 8))
    fi
}

clash_agent_subscription_valid_token() {
    # Caller supplies 32 cryptographically random bytes encoded as hex.
    [[ ${1:-} =~ ^[0-9a-fA-F]{64}$ ]]
}

clash_agent_subscription_quote() {
    jq -cn --arg value "$1" '$value'
}

# SERVER_IP REALITY_PORT UUID PUBLIC_KEY SHORT_ID SERVER_NAME NODE_NAME
clash_agent_render_clash_profile() {
    [[ $# == 7 ]] || { clash_agent_subscription_error 'profile renderer requires seven arguments'; return 1; }
    local server=$1 port=$2 uuid=$3 public_key=$4 short_id=$5 server_name=$6 node_name=$7
    local qserver quuid qkey qshort qsni qname
    clash_agent_subscription_valid_ip "$server" || { clash_agent_subscription_error 'invalid server IP'; return 1; }
    clash_agent_subscription_valid_port "$port" || { clash_agent_subscription_error 'invalid Reality port'; return 1; }
    [[ $uuid =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || { clash_agent_subscription_error 'invalid UUID'; return 1; }
    [[ $public_key =~ ^[A-Za-z0-9_-]{43}$ ]] || { clash_agent_subscription_error 'invalid Reality public key'; return 1; }
    [[ $short_id =~ ^[0-9a-fA-F]{2,16}$ ]] && ((${#short_id} % 2 == 0)) || { clash_agent_subscription_error 'invalid Reality short ID'; return 1; }
    [[ ${#server_name} -le 253 && $server_name =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && $server_name != *..* ]] || { clash_agent_subscription_error 'invalid Reality server name'; return 1; }
    [[ -n $node_name && $node_name != CLASH-AGENT && $node_name != DIRECT && $node_name != REJECT ]] || { clash_agent_subscription_error 'empty or reserved node name'; return 1; }
    qserver=$(clash_agent_subscription_quote "$server") || return 1
    quuid=$(clash_agent_subscription_quote "$uuid") || return 1
    qkey=$(clash_agent_subscription_quote "$public_key") || return 1
    qshort=$(clash_agent_subscription_quote "$short_id") || return 1
    qsni=$(clash_agent_subscription_quote "$server_name") || return 1
    qname=$(clash_agent_subscription_quote "$node_name") || return 1
    # Reuses showAccounts' Reality fields, without a second provider fetch or
    # downloaded rule sets. All traffic uses the explicitly selected group.
    cat <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: warning
ipv6: true
tcp-concurrent: true
profile:
  store-selected: true
dns:
  enable: true
  listen: 127.0.0.1:1053
  ipv6: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - 1.1.1.1
    - 8.8.8.8
proxies:
  - name: ${qname}
    type: vless
    server: ${qserver}
    port: $((10#$port))
    uuid: ${quuid}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    packet-encoding: xudp
    client-fingerprint: chrome
    servername: ${qsni}
    reality-opts:
      public-key: ${qkey}
      short-id: ${qshort}
proxy-groups:
  - name: CLASH-AGENT
    type: select
    proxies:
      - ${qname}
      - DIRECT
rules:
  - MATCH,CLASH-AGENT
EOF
}

# SUBSCRIPTION_PORT ABSOLUTE_PROFILE_FILE TOKEN [LISTEN_IPV6=false]
# Caller writes this into a dedicated conf.d file, checks nginx -t, then reloads.
# HTTP needs no domain/certificate; its URL and profile travel in plaintext.
clash_agent_render_subscription_nginx() {
    [[ $# == 3 || $# == 4 ]] || { clash_agent_subscription_error 'nginx renderer requires three or four arguments'; return 1; }
    local port=$1 profile=$2 token=$3 ipv6=${4:-false}
    clash_agent_subscription_valid_port "$port" || { clash_agent_subscription_error 'invalid subscription port'; return 1; }
    clash_agent_subscription_valid_token "$token" || { clash_agent_subscription_error 'subscription token must contain 64 hex characters'; return 1; }
    [[ $profile =~ ^/[A-Za-z0-9_./-]+$ && $profile != */../* && $profile != */./* ]] || { clash_agent_subscription_error 'invalid absolute profile path'; return 1; }
    [[ $ipv6 == true || $ipv6 == false ]] || { clash_agent_subscription_error 'invalid IPv6 listen flag'; return 1; }
    cat <<EOF
# CLASH-AGENT HTTP subscription: keep the bearer URL private.
server {
    listen 0.0.0.0:$((10#$port));
EOF
    if [[ $ipv6 == true ]]; then
        printf '    listen [::]:%s ipv6only=on;\n' "$((10#$port))"
    fi
    cat <<EOF
    server_name _;
    server_tokens off;
    access_log off;
    location = /s/${token}/clash.yaml {
        alias "${profile}";
        default_type application/yaml;
        add_header Cache-Control "no-store" always;
        limit_except GET { deny all; }
    }
    location / { return 404; }
}
EOF
}

# SERVER_IP SUBSCRIPTION_PORT TOKEN
clash_agent_subscription_url() {
    [[ $# == 3 ]] || { clash_agent_subscription_error 'subscription URL requires three arguments'; return 1; }
    local server=$1 port=$2 token=$3
    clash_agent_subscription_valid_ip "$server" || { clash_agent_subscription_error 'invalid subscription server IP'; return 1; }
    clash_agent_subscription_valid_port "$port" || { clash_agent_subscription_error 'invalid subscription port'; return 1; }
    clash_agent_subscription_valid_token "$token" || { clash_agent_subscription_error 'subscription token must contain 64 hex characters'; return 1; }
    if [[ $server == *:* ]]; then server="[$server]"; fi
    printf 'http://%s:%s/s/%s/clash.yaml\n' "$server" "$((10#$port))" "$token"
}
