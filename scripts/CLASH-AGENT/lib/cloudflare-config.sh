#!/usr/bin/env bash
# Pure chain renderers; credentials are provided by the private installer state.
clash_agent_cf_valid_path() {
    [[ $1 =~ ^/[A-Za-z0-9_-][A-Za-z0-9_/-]{2,126}$ && $1 != *'//'* ]]
}

clash_agent_cf_file_path() {
    [[ $1 =~ ^/[A-Za-z0-9_./-]+$ && $1 != */../* && $1 != */./* ]]
}

clash_agent_cf_node_args() {
    clash_agent_cf_domain "$1" >/dev/null &&
        [[ $2 =~ ^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$ ]] &&
        clash_agent_cf_valid_path "$3" && [[ -n $4 && $4 != CLASH-AGENT && $4 != DIRECT && $4 != REJECT ]]
}

clash_agent_cf_render_core() {
    [[ $# == 5 ]] || return 1
    local domain=$1 port=$2 uuid=$3 path=$4 name=$5
    clash_agent_cf_node_args "$domain" "$uuid" "$path" "$name" && clash_agent_subscription_valid_port "$port" || return 1
    jq -n --arg uuid "$uuid" --arg path "$path" --arg name "$name" --argjson port "$port" \
        '{log:{level:"warn",timestamp:true},inbounds:[{type:"vless",tag:"VLESSWS",listen:"127.0.0.1",listen_port:$port,
          users:[{uuid:$uuid,name:$name}],transport:{type:"ws",path:$path}}],outbounds:[{type:"direct",tag:"direct"}]}'
}

clash_agent_cf_render_profile() {
    [[ $# == 4 ]] || return 1
    local domain=$1 uuid=$2 path=$3 name=$4 qdomain quuid qpath qname
    clash_agent_cf_node_args "$domain" "$uuid" "$path" "$name" || return 1
    qdomain=$(clash_agent_subscription_quote "$domain"); quuid=$(clash_agent_subscription_quote "$uuid")
    qpath=$(clash_agent_subscription_quote "$path"); qname=$(clash_agent_subscription_quote "$name")
    cat <<EOF
socks-port: 7890
allow-lan: false
bind-address: 127.0.0.1
mode: rule
log-level: warning
ipv6: false
dns:
  enable: true
  listen: 127.0.0.1:1053
  enhanced-mode: fake-ip
  nameserver:
    - 223.5.5.5
    - https://dns.alidns.com/dns-query
proxies:
  - name: ${qname}
    type: vless
    server: ${qdomain}
    port: 443
    uuid: ${quuid}
    network: ws
    tls: true
    udp: true
    servername: ${qdomain}
    client-fingerprint: chrome
    ws-opts:
      path: ${qpath}
      headers:
        Host: ${qdomain}
proxy-groups:
  - name: CLASH-AGENT
    type: select
    proxies:
      - ${qname}
rules:
  - MATCH,CLASH-AGENT
EOF
}

clash_agent_cf_render_nginx() {
    [[ $# == 8 ]] || return 1
    local domain=$1 port=$2 path=$3 profile=$4 token=$5 cert=$6 key=$7 allow=$8 p
    clash_agent_cf_domain "$domain" >/dev/null && clash_agent_subscription_valid_port "$port" &&
        clash_agent_cf_valid_path "$path" && clash_agent_subscription_valid_token "$token" || return 1
    for p in "$profile" "$cert" "$key" "$allow"; do clash_agent_cf_file_path "$p" || return 1; done
    cat <<EOF
# Managed by CLASH-AGENT: ${domain}
server {
    listen 443 ssl;
    server_name ${domain};
    ssl_certificate ${cert};
    ssl_certificate_key ${key};
    ssl_protocols TLSv1.2 TLSv1.3;
    server_tokens off;
    access_log off;
    include ${allow};
    location = ${path} {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_buffering off;
        proxy_read_timeout 86400s;
    }
    location = /s/${token}/clash.yaml {
        alias ${profile};
        default_type application/yaml;
        add_header Cache-Control "no-store" always;
        limit_except GET { deny all; }
    }
    location / { return 404; }
}
EOF
}
