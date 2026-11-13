#!/usr/bin/env bash
# Automatic nginx-fronted VLESS-WS mode. Existing Reality state is never adopted.

clash_agent_cf_paths() {
    clash_agent_paths
    CA_CF_NGINX_DIR=${CLASH_AGENT_NGINX_DIR:-/etc/nginx}
    CA_CF_SITE=${CA_CF_SITE:-${CA_CF_NGINX_DIR}/conf.d/clash-agent-cloudflare.conf}
    CA_CF_CERT="${CA_STATE_DIR}/tls/${CA_CF_DOMAIN}.crt"
    CA_CF_KEY="${CA_STATE_DIR}/tls/${CA_CF_DOMAIN}.key"
    CA_CF_ACME_HOME="${CA_STATE_DIR}/acme"
    CA_CF_ALLOW="${CA_STATE_DIR}/cloudflare-allow.conf"
    CA_CF_PORT=10443
}

clash_agent_cf_read_state() {
    [[ -f $CA_STATE_FILE && ! -L $CA_STATE_FILE ]] || return 1
    jq -e '.product=="CLASH-AGENT" and .schema==2 and .mode=="cloudflare-ws" and
        (.status=="ready" or .status=="installing") and .ws_port==10443 and
        (.adopted | type=="boolean")' "$CA_STATE_FILE" >/dev/null || return 1
    local saved_domain
    saved_domain=$(jq -er .domain "$CA_STATE_FILE") || return 1
    [[ -z ${CA_CF_DOMAIN:-} || $CA_CF_DOMAIN == "$saved_domain" ]] || {
        clash_agent_error 'Managed hostname differs; migrate explicitly instead of changing identity.'; return 1;
    }
    CA_CF_DOMAIN=$saved_domain
    CA_SERVER=$(jq -er .server "$CA_STATE_FILE")
    CA_CF_ZONE=$(jq -er .zone_id "$CA_STATE_FILE")
    CA_UUID=$(jq -er .uuid "$CA_STATE_FILE")
    CA_TOKEN=$(jq -er .token "$CA_STATE_FILE")
    CA_CF_WS_PATH=$(jq -er .ws_path "$CA_STATE_FILE")
    CA_NODE_NAME=$(jq -er .node_name "$CA_STATE_FILE")
    CA_CF_SITE=$(jq -er .nginx_site "$CA_STATE_FILE")
    CA_CF_ADOPTED=$(jq -er '.adopted | tostring' "$CA_STATE_FILE") || CA_CF_ADOPTED=false
    CA_STATUS=$(jq -er .status "$CA_STATE_FILE")
    clash_agent_cf_node_args "$CA_CF_DOMAIN" "$CA_UUID" "$CA_CF_WS_PATH" "$CA_NODE_NAME" &&
        clash_agent_subscription_valid_token "$CA_TOKEN" && clash_agent_cf_file_path "$CA_CF_SITE" &&
        [[ $CA_CF_ZONE =~ ^[a-f0-9]{32}$ && $CA_SERVER =~ ^[0-9.]+$ ]] && clash_agent_subscription_valid_ip "$CA_SERVER"
}

clash_agent_cf_write_state() {
    local temp
    temp=$(mktemp "${CA_STATE_DIR}/.state.XXXXXX") || return 1
    jq -n --arg status "$1" --arg domain "$CA_CF_DOMAIN" --arg server "$CA_SERVER" \
        --arg uuid "$CA_UUID" --arg token "$CA_TOKEN" --arg path "$CA_CF_WS_PATH" \
        --arg name "$CA_NODE_NAME" --arg site "$CA_CF_SITE" --arg zone "$CA_CF_ZONE" --argjson adopted "$CA_CF_ADOPTED" \
        '{product:"CLASH-AGENT",schema:2,mode:"cloudflare-ws",status:$status,domain:$domain,server:$server,
          uuid:$uuid,token:$token,ws_path:$path,ws_port:10443,node_name:$name,nginx_site:$site,zone_id:$zone,adopted:$adopted}' >"$temp" &&
        chmod 600 "$temp" && mv -f "$temp" "$CA_STATE_FILE"
}

clash_agent_cf_adopt_site() {
    # Parse server blocks without executing nginx directives or shell content.
    # Replace only the requested hostname's block, preserving all other vhosts.
    python3 - "$1" "$CA_CF_SITE" "$CA_CF_DOMAIN" "${CA_CONF_DIR}/config.json" "${2:-}" <<'PY'
import json, pathlib, re, sys
mode, filename, domain, core, replacement = sys.argv[1:]
p = pathlib.Path(filename)
if not p.is_file() or p.is_symlink():
    raise SystemExit('CLASH-AGENT: Adoption requires a regular nginx site file.')
text = p.read_text()
tokens = list(re.finditer(r'''\#[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[{};]|[^\s{};]+''', text))
tokens = [t for t in tokens if not t.group().startswith('#')]
blocks = []
i = 0
while i < len(tokens)-1:
    if tokens[i].group() != 'server' or tokens[i+1].group() != '{':
        i += 1
        continue
    start, depth, j = i, 1, i+2
    while j < len(tokens) and depth:
        depth += (tokens[j].group() == '{') - (tokens[j].group() == '}')
        j += 1
    if depth:
        raise SystemExit('CLASH-AGENT: Unbalanced nginx server block.')
    body = text[tokens[start].start():tokens[j-1].end()]
    names = re.findall(r'\bserver_name\s+([^;]+);', body)
    listens = re.findall(r'\blisten\s+([^;]+);', body)
    https = any('ssl' in l.split() and any(a=='443' or a.endswith(':443') for a in l.split()) for l in listens)
    if https and any(domain in n.split() for n in names):
        if len(names) != 1 or names[0].split() != [domain]:
            raise SystemExit('CLASH-AGENT: Adoption refuses a shared server_name block.')
        blocks.append((tokens[start].start(), tokens[j-1].end(), body))
    i = j
if len(blocks) != 1:
    raise SystemExit('CLASH-AGENT: Expected one server block for the node hostname.')
start, end, body = blocks[0]
if mode == 'inspect':
    cp = pathlib.Path(core)
    if not cp.is_file() or cp.is_symlink():
        raise SystemExit('CLASH-AGENT: No regular effective sing-box config to adopt.')
    cfg = json.loads(cp.read_text())
    ins = cfg.get('inbounds', [])
    if len(ins) != 1:
        raise SystemExit('CLASH-AGENT: Adoption only supports a single existing VLESS-WS inbound.')
    n = ins[0]
    users = n.get('users', [])
    transport = n.get('transport', {})
    if not (n.get('type') == 'vless' and n.get('listen') == '127.0.0.1' and n.get('listen_port') == 10443
            and not n.get('tls', {}).get('enabled', False) and transport.get('type') == 'ws' and len(users) == 1):
        raise SystemExit('CLASH-AGENT: Existing inbound is not the supported nginx-fronted WS layout.')
    path = transport.get('path', '')
    locations = re.findall(r'\blocation\s+(?:=\s+)?([^\s{]+)\s*\{', body)
    if not set(locations) <= {path, '/', '/clash.yaml'} or path not in locations:
        raise SystemExit('CLASH-AGENT: Node vhost contains unsupported custom locations; adopt manually.')
    if not re.search(r'\bproxy_pass\s+http://127\.0\.0\.1:10443\s*;', body):
        raise SystemExit('CLASH-AGENT: Existing WS upstream differs.')
    print(json.dumps({'uuid':users[0]['uuid'], 'path':path, 'name':users[0].get('name', 'RackNerd-CF')}))
else:
    new = pathlib.Path(replacement).read_text()
    new = new[new.index('server {'):].strip()
    # Keep the old exact subscription URL working for clients during adoption.
    if re.search(r'location\s+=\s+/clash\.yaml\s*\{', body):
        old = re.search(r'location\s+=\s+/clash\.yaml\s*\{[^{}]*\}', body)
        if not old:
            raise SystemExit('CLASH-AGENT: Cannot preserve legacy subscription location.')
        new = new[:-1] + '\n    ' + old.group() + '\n}'
    temp = p.with_name(p.name+'.clash-agent-new')
    if temp.exists() or temp.is_symlink():
        raise SystemExit('CLASH-AGENT: Unexpected adoption staging file.')
    temp.write_text(text[:start] + new + text[end:])
    temp.chmod(p.stat().st_mode & 0o777)
    temp.replace(p)
PY
}

clash_agent_cf_origin_available() {
    if command -v ss >/dev/null 2>&1; then
        [[ -z $(ss -H -ltn 'sport = :443') ]] || {
            clash_agent_error 'TCP 443 already has an unmanaged listener; it was not replaced.'; return 1;
        }
    fi
}

clash_agent_cf_service_exists() {
    [[ -e ${CA_UNIT_DIR}/sing-box.service ]] || systemctl cat sing-box.service >/dev/null 2>&1
}

clash_agent_cf_service_matches() {
    local command
    command=$(systemctl show sing-box.service --property=ExecStart --value) || return 1
    [[ $command == *"${CA_BINARY} run -c ${CA_CONF_DIR}/config.json"* ]] || {
        clash_agent_error 'Existing sing-box service uses another binary/configuration; it was not replaced.'; return 1;
    }
}

clash_agent_cf_preflight() {
    clash_agent_check_host || return 1
    local p
    for p in "$CA_STATE_DIR" "$CA_CORE_DIR" "$CA_PROFILE_DIR" "$CA_UNIT_DIR" "$CA_CF_NGINX_DIR" "$CA_CF_SITE"; do
        clash_agent_cf_file_path "$p" && [[ ! -L $p ]] || { clash_agent_error 'Unsafe managed path.'; return 1; }
    done
    if [[ -e $CA_STATE_FILE ]]; then
        clash_agent_cf_read_state || { clash_agent_error 'Existing installer state belongs to another mode or is invalid.'; return 1; }
        if clash_agent_cf_service_exists; then clash_agent_cf_service_matches || return 1; fi
        return 0
    fi
    CA_CF_ADOPTED=false
    if [[ -e $CA_CORE_DIR ]]; then
        [[ ${CA_CF_ADOPT:-false} == true ]] || { clash_agent_error 'Existing installation requires --adopt-existing.'; return 1; }
        CA_CF_SITE="${CA_CF_NGINX_DIR}/conf.d/sub.conf"
        local adopted
        adopted=$(clash_agent_cf_adopt_site inspect) || return 1
        CA_UUID=$(jq -er .uuid <<<"$adopted")
        CA_CF_WS_PATH=$(jq -er .path <<<"$adopted")
        CA_NODE_NAME=$(jq -er .name <<<"$adopted")
        clash_agent_cf_node_args "$CA_CF_DOMAIN" "$CA_UUID" "$CA_CF_WS_PATH" "$CA_NODE_NAME" || return 1
        clash_agent_cf_service_exists && clash_agent_cf_service_matches || {
            clash_agent_error 'Adoption requires the supported existing sing-box service.'; return 1;
        }
        CA_CF_ADOPTED=true
    elif [[ -e $CA_CF_SITE ]] || clash_agent_cf_service_exists; then
        clash_agent_error 'Unmanaged nginx site or sing-box service exists; it was not overwritten.'; return 1
    else
        clash_agent_cf_origin_available || return 1
    fi
}

clash_agent_cf_service_snapshot() {
    local unit active enabled
    for unit in nginx.service sing-box.service clash-agent-cf-firewall.service clash-agent-cf-firewall.timer clash-agent-cf-renew.timer; do
        active=$(systemctl is-active "$unit" 2>/dev/null) || active=inactive
        enabled=$(systemctl is-enabled "$unit" 2>/dev/null) || enabled=disabled
        printf '%s %s %s\n' "$unit" "$active" "$enabled"
    done
}

clash_agent_cf_backup() {
    CA_CF_BACKUP=$(mktemp -d "${CA_STATE_DIR}/backups/run.XXXXXX") || return 1
    chmod 700 "$CA_CF_BACKUP" || return 1
    local file n=0
    : >"$CA_CF_BACKUP/files"
    for file in "$CA_CF_SITE" "${CA_CONF_DIR}/config.json" "${CA_CONF_DIR}/config/03_VLESS_WS_inbounds.json" \
        "$CA_STATE_FILE" "${CA_STATE_DIR}/owner" "$CA_CF_ALLOW" "${CA_STATE_DIR}/firewall-chain" "$CA_CF_CERT" "$CA_CF_KEY" \
        "${CA_STATE_DIR}/installer.sh" "${CA_STATE_DIR}/cloudflare-token" \
        "${CA_PROFILE_DIR}/clash.yaml" "${CA_UNIT_DIR}/sing-box.service" \
        "${CA_UNIT_DIR}/clash-agent-cf-renew.service" "${CA_UNIT_DIR}/clash-agent-cf-renew.timer" \
        "${CA_UNIT_DIR}/clash-agent-cf-firewall.service" "${CA_UNIT_DIR}/clash-agent-cf-firewall.timer" \
        "${CA_UNIT_DIR}/clash-agent-cf-refresh.service" \
        "${CA_UNIT_DIR}/nginx.service.d/clash-agent-cloudflare.conf"; do
        [[ ! -L $file ]] || { clash_agent_error 'Managed file is a symlink; refusing replacement.'; return 1; }
        if [[ -e $file ]]; then
            [[ -f $file ]] || return 1
            cp -p "$file" "$CA_CF_BACKUP/$n" || return 1
            printf '%s\t%s\n' "$n" "$file" >>"$CA_CF_BACKUP/files"
        else printf '%s\t%s\n' absent "$file" >>"$CA_CF_BACKUP/files"; fi
        n=$((n+1))
    done
    clash_agent_cf_service_snapshot >"$CA_CF_BACKUP/services"
}

clash_agent_cf_restore() {
    local index file failed=0
    [[ -n ${CA_CF_BACKUP:-} && -f $CA_CF_BACKUP/files ]] || return 0
    clash_agent_cf_firewall_restore || printf 'CLASH-AGENT: Firewall rollback needs inspection.\n' >&2
    while IFS=$'\t' read -r index file; do
        # A first interrupted install retains its private pending identity so a
        # repeat can resume; it is never reported as ready.
        if [[ $index == absent && ($file == "$CA_STATE_FILE" || $file == "${CA_STATE_DIR}/owner") ]]; then continue; fi
        if [[ $index == absent ]]; then rm -f -- "$file" || failed=1;
        else mkdir -p "${file%/*}" && cp -p "$CA_CF_BACKUP/$index" "$file" || failed=1; fi
    done <"$CA_CF_BACKUP/files"
    clash_agent_cf_services restore || printf 'CLASH-AGENT: Service rollback needs inspection; inspect the private backup.\n' >&2
    if [[ $failed == 1 ]]; then printf 'CLASH-AGENT: Some files could not be restored; inspect the private backup.\n' >&2; fi
    printf 'CLASH-AGENT: Installation failed; recovery material: %s\n' "$CA_CF_BACKUP" >&2
}

clash_agent_cf_dependencies() { clash_agent_install_dependencies; }
clash_agent_cf_prepare_core() {
    if [[ ${CA_CF_ADOPTED:-false} == true ]]; then "$CA_BINARY" version >/dev/null;
    else clash_agent_prepare_core; fi
}

clash_agent_cf_certificate() {
    local archive stage result=0
    mkdir -p "$CA_CF_ACME_HOME" "${CA_CF_CERT%/*}" || return 1
    if [[ ! -x $CA_CF_ACME_HOME/acme.sh ]]; then
        stage=$(mktemp -d "${CA_STATE_DIR}/.acme-install.XXXXXX") || return 1
        archive="$stage/acme.tar.gz"
        if ! curl --proto '=https' -fsSL --connect-timeout 10 --max-time 90 \
            https://github.com/acmesh-official/acme.sh/archive/refs/tags/3.1.2.tar.gz -o "$archive" ||
            ! tar -xzf "$archive" -C "$stage" ||
            ! (cd "$stage/acme.sh-3.1.2" && bash ./acme.sh --install --home "$CA_CF_ACME_HOME" \
                --config-home "$CA_CF_ACME_HOME" --cert-home "$CA_CF_ACME_HOME" --nocron --no-profile) >"${CA_STATE_DIR}/acme-install.log" 2>&1; then
            rm -rf "$stage"; clash_agent_error 'acme.sh installation failed; inspect the private state log.'; return 1
        fi
        rm -rf "$stage"
    fi
    clash_agent_cf_prepare_dns_hook || return 1
    # Separate ACME home: no changes to another application's account or cron.
    env -u CF_Token -u CF_Key -u CF_Email -u CF_API_TOKEN -u CA_CF_TOKEN \
        CLASH_CF_INSTALLER="${CA_STATE_DIR}/installer.sh" CLASH_CF_STATE_DIR="$CA_STATE_DIR" \
        "$CA_CF_ACME_HOME/acme.sh" --issue --home "$CA_CF_ACME_HOME" --config-home "$CA_CF_ACME_HOME" \
        --cert-home "$CA_CF_ACME_HOME" --server letsencrypt --dns dns_clash_agent_cf -d "$CA_CF_DOMAIN" -k ec-256 \
        >"${CA_STATE_DIR}/acme-issue.log" 2>&1 || result=$?
    # 2 means skipped/not due. Other errors must not be hidden by an old cert.
    if [[ $result != 0 && $result != 2 ]]; then
        clash_agent_error 'DNS-01 certificate issuance failed; inspect the private state log.'; return 1
    fi
    cp "${CA_CF_ACME_HOME}/${CA_CF_DOMAIN}_ecc/fullchain.cer" "$CA_CF_CERT" &&
        cp "${CA_CF_ACME_HOME}/${CA_CF_DOMAIN}_ecc/${CA_CF_DOMAIN}.key" "$CA_CF_KEY" || return 1
    chmod 600 "$CA_CF_KEY" || return 1
    openssl x509 -in "$CA_CF_CERT" -noout -checkend 604800 >/dev/null &&
        openssl x509 -in "$CA_CF_CERT" -noout -checkhost "$CA_CF_DOMAIN" >/dev/null
}

clash_agent_cf_finish_certificate() {
    "$CA_CF_ACME_HOME/acme.sh" --install-cert --home "$CA_CF_ACME_HOME" --config-home "$CA_CF_ACME_HOME" \
        --cert-home "$CA_CF_ACME_HOME" -d "$CA_CF_DOMAIN" --ecc \
        --fullchain-file "$CA_CF_CERT" --key-file "$CA_CF_KEY" \
        --reloadcmd 'nginx -t && systemctl reload nginx.service' >"${CA_STATE_DIR}/acme-reload-hook.log" 2>&1 || return 1
    cat >"${CA_UNIT_DIR}/clash-agent-cf-renew.service" <<EOF
[Unit]
Description=CLASH-AGENT Cloudflare DNS-01 certificate renewal
[Service]
Type=oneshot
UMask=0077
Environment=PATH=/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${CA_CF_ACME_HOME}/acme.sh --cron --home ${CA_CF_ACME_HOME} --config-home ${CA_CF_ACME_HOME} --cert-home ${CA_CF_ACME_HOME}
EOF
    cat >"${CA_UNIT_DIR}/clash-agent-cf-renew.timer" <<'EOF'
[Unit]
Description=Check CLASH-AGENT certificates twice daily
[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload && systemctl enable --now clash-agent-cf-renew.timer
}

clash_agent_cf_write_configs() {
    local temp site
    mkdir -p "${CA_CONF_DIR}/config" "$CA_PROFILE_DIR" "${CA_CF_SITE%/*}" "$CA_UNIT_DIR" || return 1
    chmod 755 "$CA_PROFILE_DIR" || return 1
    temp=$(mktemp "${CA_CONF_DIR}/.cf-config.XXXXXX") || return 1
    clash_agent_cf_render_core "$CA_CF_DOMAIN" "$CA_CF_PORT" "$CA_UUID" "$CA_CF_WS_PATH" "$CA_NODE_NAME" >"$temp" || return 1
    if [[ $CA_CF_ADOPTED == true ]]; then
        jq '.inbounds[0].listen="127.0.0.1" | .inbounds[0].listen_port=10443 | del(.inbounds[0].tls)' \
            "${CA_CONF_DIR}/config.json" >"${temp}.adopt" &&
            mv -f "${temp}.adopt" "$temp" || return 1
    fi
    "$CA_BINARY" check -c "$temp" || return 1
    jq '{inbounds}' "$temp" >"${CA_CONF_DIR}/config/03_VLESS_WS_inbounds.json" &&
        chmod 600 "$temp" "${CA_CONF_DIR}/config/03_VLESS_WS_inbounds.json" &&
        mv -f "$temp" "${CA_CONF_DIR}/config.json" || return 1
    clash_agent_cf_render_profile "$CA_CF_DOMAIN" "$CA_UUID" "$CA_CF_WS_PATH" "$CA_NODE_NAME" >"${CA_PROFILE_DIR}/clash.yaml" || return 1
    chmod 644 "${CA_PROFILE_DIR}/clash.yaml" || return 1
    site=$(mktemp "${CA_STATE_DIR}/.site.XXXXXX") || return 1
    clash_agent_cf_render_nginx "$CA_CF_DOMAIN" "$CA_CF_PORT" "$CA_CF_WS_PATH" "${CA_PROFILE_DIR}/clash.yaml" \
        "$CA_TOKEN" "$CA_CF_CERT" "$CA_CF_KEY" "$CA_CF_ALLOW" >"$site" || return 1
    if [[ $CA_CF_ADOPTED == true ]]; then clash_agent_cf_adopt_site replace "$site" || return 1;
    else cp "$site" "$CA_CF_SITE" || return 1; fi
    rm -f "$site"
    if [[ $CA_CF_ADOPTED != true ]]; then
        # Reuse upstream's service registration; do not replace an adopted unit.
        installSingBoxService 2 defer || return 1
    fi
}

clash_agent_cf_nginx_check() { nginx -t; }

clash_agent_cf_services() {
    local unit active enabled failed=0
    systemctl daemon-reload || return 1
    if [[ $1 == start ]]; then
        systemctl enable nginx.service sing-box.service || return 1
        systemctl start clash-agent-cf-firewall.service && systemctl restart sing-box.service && systemctl reload-or-restart nginx.service
    else
        while read -r unit active enabled; do
            if [[ $enabled == enabled ]]; then systemctl enable "$unit" || failed=1;
            else systemctl disable "$unit" >/dev/null 2>&1 || true; fi
            if [[ $active == active ]]; then systemctl restart "$unit" || failed=1;
            else systemctl stop "$unit" >/dev/null 2>&1 || true; fi
        done <"$CA_CF_BACKUP/services"
        return "$failed"
    fi
}

clash_agent_cf_proxy_check() (
    local work port pid= attempt ready=false ip
    work=$(mktemp -d "${CA_STATE_DIR}/.proxy-check.XXXXXX") || return 1
    trap 'if [[ -n $pid ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi; rm -rf "$work"' EXIT
    port=$(python3 -c 'import socket; s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()') || return 1
    jq -n --arg host "$CA_CF_DOMAIN" --arg uuid "$CA_UUID" --arg path "$CA_CF_WS_PATH" --argjson port "$port" \
        '{log:{level:"error"},dns:{servers:[{type:"local",tag:"local"}]},route:{default_domain_resolver:"local"},
          inbounds:[{type:"socks",listen:"127.0.0.1",listen_port:$port}],
          outbounds:[{type:"vless",server:$host,server_port:443,uuid:$uuid,
            tls:{enabled:true,server_name:$host},transport:{type:"ws",path:$path,headers:{Host:$host}}}]}' >"$work/client.json" || return 1
    "$CA_BINARY" check -c "$work/client.json" >/dev/null 2>&1 || return 1
    "$CA_BINARY" run -c "$work/client.json" >"$work/client.log" 2>&1 & pid=$!
    for ((attempt=0; attempt<40; attempt++)); do
        kill -0 "$pid" 2>/dev/null || return 1
        if python3 -c 'import socket,sys;s=socket.create_connection(("127.0.0.1",int(sys.argv[1])),.2);s.close()' "$port" 2>/dev/null; then ready=true; break; fi
        sleep 0.1
    done
    [[ $ready == true ]] || return 1
    ip=$(curl --noproxy '' --proxy "socks5h://127.0.0.1:${port}" -fsS --retry 2 --connect-timeout 6 --max-time 20 \
        https://api.ipify.org 2>/dev/null) || { clash_agent_error 'Cloudflare proxy TCP probe failed.'; return 1; }
    [[ $ip == "$CA_SERVER" ]] || { clash_agent_error 'Proxy exit does not match the origin IPv4.'; return 1; }
    python3 - "$port" "$CA_SERVER" <<'PY'
import os,socket,struct,sys
def take(s,n):
    b=b''
    while len(b)<n:
        p=s.recv(n-len(b))
        if not p: raise OSError('SOCKS closed')
        b+=p
    return b
control=socket.create_connection(('127.0.0.1',int(sys.argv[1])),5);control.settimeout(6)
control.sendall(b'\x05\x01\x00')
if take(control,2)!=b'\x05\x00': raise SystemExit('CLASH-AGENT: SOCKS authentication failed.')
control.sendall(b'\x05\x03\x00\x01'+b'\x00'*6)
h=take(control,4)
if h[1]!=0 or h[3]!=1: raise SystemExit('CLASH-AGENT: UDP relay unavailable.')
address=socket.inet_ntoa(take(control,4));port=struct.unpack('!H',take(control,2))[0]
if address=='0.0.0.0': address='127.0.0.1'
success=False
for host,target_port in [('stun.cloudflare.com',3478),('stun.l.google.com',19302)]:
    udp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);udp.settimeout(6)
    try:
        ip=socket.gethostbyname(host);tx=os.urandom(12)
        message=b'\x00\x01\x00\x00\x21\x12\xa4\x42'+tx
        udp.sendto(b'\x00\x00\x00\x01'+socket.inet_aton(ip)+struct.pack('!H',target_port)+message,(address,port))
        response,_=udp.recvfrom(4096)
        if len(response)<10 or response[3]!=1: continue
        message=response[10:]
        if len(message)<20 or message[:2]!=b'\x01\x01' or message[8:20]!=tx: continue
        attrs=message[20:]
        while len(attrs)>=4:
            kind,length=struct.unpack('!HH',attrs[:4]);v=attrs[4:4+length]
            if kind==32 and len(v)>=8 and v[1]==1:
                mapped=socket.inet_ntoa(bytes(a^b for a,b in zip(v[4:8],b'\x21\x12\xa4\x42')))
                if mapped==sys.argv[2]: success=True
            attrs=attrs[4+((length+3)//4)*4:]
        if success: break
    except OSError: pass
    finally: udp.close()
control.close()
if not success: raise SystemExit('CLASH-AGENT: Cloudflare proxy UDP/STUN probe failed.')
PY
)

clash_agent_cf_health() {
    local temp headers status
    systemctl is-active --quiet nginx.service && systemctl is-active --quiet sing-box.service || return 1
    "$CA_BINARY" check -c "${CA_CONF_DIR}/config.json" >/dev/null || return 1
    openssl x509 -in "$CA_CF_CERT" -noout -checkend 604800 >/dev/null &&
        openssl x509 -in "$CA_CF_CERT" -noout -checkhost "$CA_CF_DOMAIN" >/dev/null || return 1
    temp=$(mktemp -d "${CA_STATE_DIR}/.health.XXXXXX") || return 1
    if ! curl --noproxy '*' --resolve "${CA_CF_DOMAIN}:443:127.0.0.1" -fsS --connect-timeout 4 --max-time 10 \
        "https://${CA_CF_DOMAIN}/s/${CA_TOKEN}/clash.yaml" -o "$temp/local" ||
        ! cmp -s "$temp/local" "${CA_PROFILE_DIR}/clash.yaml"; then rm -rf "$temp"; return 1; fi
    status=$(curl --noproxy '*' --resolve "${CA_CF_DOMAIN}:443:127.0.0.1" -sS --http1.1 --connect-timeout 4 --max-time 3 \
        -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
        -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -D "$temp/headers" -o /dev/null \
        "https://${CA_CF_DOMAIN}${CA_CF_WS_PATH}" 2>/dev/null) || true
    if ! grep -Eq '^HTTP/1\.[01] 101 ' "$temp/headers"; then rm -rf "$temp"; return 1; fi
    if ! curl --noproxy '*' -fsS --retry 3 --retry-delay 2 --connect-timeout 6 --max-time 20 \
        "https://${CA_CF_DOMAIN}/s/${CA_TOKEN}/clash.yaml" -o "$temp/public" ||
        ! cmp -s "$temp/public" "${CA_PROFILE_DIR}/clash.yaml"; then rm -rf "$temp"; return 1; fi
    rm -rf "$temp"
    clash_agent_cf_proxy_check
}

clash_agent_cf_print_result() {
    printf 'CLASH-AGENT configured: Cloudflare + nginx TLS + loopback VLESS-WS.\n'
    printf 'Clash.Meta / mihomo HTTPS subscription (keep private):\nhttps://%s/s/%s/clash.yaml\n' "$CA_CF_DOMAIN" "$CA_TOKEN"
    if [[ $CA_CF_ADOPTED == true ]]; then printf 'Legacy subscription endpoints were retained for existing clients; retire them and rotate credentials separately.\n'; fi
    printf 'State: %s\n' "$CA_STATE_FILE"
}

clash_agent_cf_verify_maintenance() {
    local unit
    for unit in clash-agent-cf-firewall.service clash-agent-cf-firewall.timer clash-agent-cf-renew.timer; do
        systemctl is-enabled --quiet "$unit" && systemctl is-active --quiet "$unit" || return 1
    done
}

clash_agent_cf_install() (
    umask 077
    export PATH="${PATH}:/usr/sbin:/sbin"
    clash_agent_cf_paths
    clash_agent_cf_preflight || return 1
    [[ ! -L ${CA_LOCK_FILE%/*} && ! -L $CA_LOCK_FILE ]] || return 1
    mkdir -p "${CA_LOCK_FILE%/*}" || return 1
    exec 9>>"$CA_LOCK_FILE"
    flock -n 9 || { clash_agent_error 'Another installation is running.'; return 1; }
    clash_agent_cf_preflight || return 1
    clash_agent_cf_dependencies || return 1
    clash_agent_cf_load_token || return 1
    clash_agent_cf_discover || return 1
    CA_SERVER=${CA_SERVER:-$(clash_agent_detect_ip)}
    [[ $CA_SERVER =~ ^[0-9.]+$ ]] && clash_agent_subscription_valid_ip "$CA_SERVER" || { clash_agent_error 'Cloudflare WS mode currently requires a public IPv4 origin.'; return 1; }
    mkdir -p "$CA_STATE_DIR/backups" "$CA_UNIT_DIR" || return 1
    chmod 700 "$CA_STATE_DIR" "$CA_STATE_DIR/backups" || return 1
    clash_agent_cf_backup || return 1
    local committed=false
    trap 'status=$?; if [[ $committed != true ]]; then clash_agent_cf_rollback_dns || printf "CLASH-AGENT: DNS rollback requires inspection.\n" >&2; clash_agent_cf_restore; fi; exit "$status"' EXIT
    # Persist pending ownership before any core download can leave directories.
    # UUID generation must not depend on a successfully installed core binary.
    CA_UUID=${CA_UUID:-$(python3 -c 'import uuid;print(uuid.uuid4())')} || return 1
    CA_CF_WS_PATH=${CA_CF_WS_PATH:-/$(openssl rand -hex 12)ws}
    CA_TOKEN=${CA_TOKEN:-$(openssl rand -hex 32)}
    CA_NODE_NAME=${CA_NODE_NAME:-CLASH-AGENT-CF-$(openssl rand -hex 4)}
    clash_agent_cf_node_args "$CA_CF_DOMAIN" "$CA_UUID" "$CA_CF_WS_PATH" "$CA_NODE_NAME" && clash_agent_subscription_valid_token "$CA_TOKEN" || return 1
    clash_agent_cf_write_state installing || return 1
    printf 'CLASH-AGENT\n' >"${CA_STATE_DIR}/owner"
    clash_agent_cf_prepare_core || return 1
    clash_agent_cf_ensure_dns || return 1
    clash_agent_configure_system && clash_agent_configure_fail2ban || return 1
    clash_agent_cf_certificate || return 1
    # Create the validated origin allowlist before nginx loads the managed site.
    clash_agent_cf_firewall_prepare || return 1
    clash_agent_cf_write_configs && clash_agent_cf_nginx_check || return 1
    clash_agent_cf_firewall_setup && clash_agent_cf_services start || return 1
    clash_agent_cf_health && clash_agent_cf_finish_certificate || return 1
    clash_agent_cf_verify_maintenance && clash_agent_verify_system && clash_agent_verify_fail2ban || return 1
    clash_agent_cf_write_state ready || return 1
    committed=true
    clash_agent_cf_print_result
)

clash_agent_cf_show() {
    CA_CF_DOMAIN= CA_CF_SITE=
    clash_agent_cf_paths
    clash_agent_cf_read_state && [[ $CA_STATUS == ready ]] || return 1
    clash_agent_cf_paths
    clash_agent_cf_health && clash_agent_cf_verify_maintenance && clash_agent_verify_system && clash_agent_verify_fail2ban && clash_agent_cf_print_result
}
