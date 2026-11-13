#!/usr/bin/env bash
# Cloudflare's JSON API is the only external boundary here. Never log responses
# on errors: an upstream error can echo credentials or caller-supplied data.

clash_agent_cf_domain() {
    local value=${1%.} label
    [[ ${#value} -le 253 && $value == *.* && $value != *..* ]] || return 1
    local -a labels
    IFS=. read -r -a labels <<<"$value"
    for label in "${labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 && $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
    [[ ${labels[${#labels[@]}-1]} =~ ^[A-Za-z][A-Za-z0-9-]+$ ]] || return 1
    printf '%s\n' "$value" | tr '[:upper:]' '[:lower:]'
}

clash_agent_cf_load_token() {
    # A caller running bash -x must not turn the token into diagnostic output.
    { set +x; } 2>/dev/null
    if [[ -n ${CA_CF_TOKEN_FILE:-} ]]; then
        python3 - "$CA_CF_TOKEN_FILE" <<'PY' || return 1
import os, stat, sys
p = sys.argv[1]
s = os.lstat(p)
if not stat.S_ISREG(s.st_mode) or s.st_mode & 0o077:
    raise SystemExit('CLASH-AGENT: Token file must be a regular file with mode 600 or stricter.')
PY
        CA_CF_TOKEN=$(cat -- "$CA_CF_TOKEN_FILE") || return 1
    else
        CA_CF_TOKEN=${CF_API_TOKEN:-}
        if [[ -z $CA_CF_TOKEN && -t 0 ]]; then
            read -r -s -p 'Cloudflare API token: ' CA_CF_TOKEN
            printf '\n' >&2
        fi
    fi
    [[ ${#CA_CF_TOKEN} -ge 20 && ${#CA_CF_TOKEN} -le 256 && $CA_CF_TOKEN =~ ^[A-Za-z0-9_-]+$ ]] || {
        clash_agent_error 'Provide a valid Cloudflare API token through CF_API_TOKEN or --cf-token-file.'; return 1;
    }
}

clash_agent_cf_api() {
    local method=$1 endpoint=$2 base=${CLASH_AGENT_CF_API_BASE:-https://api.cloudflare.com/client/v4}
    local header response codes status=0
    case "$base" in
        https://api.cloudflare.com/client/v4) ;;
        http://127.0.0.1:*) [[ $base =~ ^http://127\.0\.0\.1:[0-9]+$ ]] || return 1 ;;
        *) clash_agent_error 'Unsupported Cloudflare API endpoint.'; return 1 ;;
    esac
    [[ $endpoint == /* && -n ${CA_CF_TOKEN:-} ]] || return 1
    header=$(mktemp "${TMPDIR:-/tmp}/clash-agent-auth.XXXXXX") || return 1
    chmod 600 "$header" || { rm -f "$header"; return 1; }
    printf 'header = "Authorization: Bearer %s"\n' "$CA_CF_TOKEN" >"$header"
    local -a args=(-fsS --connect-timeout 10 --max-time 30 --config "$header" -X "$method" -H 'Content-Type: application/json')
    [[ $# -lt 3 ]] || args+=(--data-binary "$3")
    response=$(curl "${args[@]}" "${base}${endpoint}" 2>/dev/null) || status=$?
    rm -f "$header"
    if ((status)) || ! jq -e '.success == true and has("result")' <<<"$response" >/dev/null 2>&1; then
        codes=$(jq -r '[.errors[]?.code | select(type == "number") | tostring] | join(",")' <<<"$response" 2>/dev/null) || codes=
        clash_agent_error "Cloudflare API request failed (HTTP transport ${status}; error codes ${codes:-unavailable})."
        return 1
    fi
    printf '%s\n' "$response"
}

clash_agent_cf_discover() {
    local candidate response count value
    CA_CF_DOMAIN=$(clash_agent_cf_domain "$CA_CF_DOMAIN") || { clash_agent_error 'Invalid node hostname.'; return 1; }
    candidate=$CA_CF_DOMAIN
    CA_CF_ZONE= CA_CF_ACCOUNT=
    while [[ $candidate == *.* ]]; do
        response=$(clash_agent_cf_api GET "/zones?name=${candidate}&status=active&per_page=50") || return 1
        count=$(jq '.result | length' <<<"$response") || return 1
        if [[ $count == 1 ]]; then
            CA_CF_ZONE=$(jq -r '.result[0].id' <<<"$response")
            CA_CF_ACCOUNT=$(jq -r '.result[0].account.id' <<<"$response")
            break
        fi
        [[ $count == 0 ]] || { clash_agent_error 'Ambiguous Cloudflare zone.'; return 1; }
        candidate=${candidate#*.}
    done
    [[ $CA_CF_ZONE =~ ^[a-f0-9]{32}$ && $CA_CF_ACCOUNT =~ ^[a-f0-9]{32}$ ]] || {
        clash_agent_error 'No active accessible Cloudflare zone owns this hostname.'; return 1;
    }
    response=$(clash_agent_cf_api GET "/zones/${CA_CF_ZONE}/settings/ssl") || return 1
    value=$(jq -r '.result.value' <<<"$response")
    [[ $value == strict || $value == full ]] || {
        clash_agent_error 'Cloudflare SSL mode must already be Full or Full (strict). Zone-wide settings were not changed.'; return 1;
    }
    response=$(clash_agent_cf_api GET "/zones/${CA_CF_ZONE}/settings/websockets") || return 1
    [[ $(jq -r '.result.value' <<<"$response") == on ]] || {
        clash_agent_error 'Enable WebSockets for the zone before installing. Zone-wide settings were not changed.'; return 1;
    }
}

clash_agent_cf_ensure_dns() {
    local response count record payload marker
    CA_CF_DNS_CREATED=false CA_CF_DNS_CHANGED=false CA_CF_DNS_OLD= CA_CF_RECORD_ID=
    [[ $CA_SERVER =~ ^[0-9.]+$ ]] && clash_agent_subscription_valid_ip "$CA_SERVER" || return 1
    response=$(clash_agent_cf_api GET "/zones/${CA_CF_ZONE}/dns_records?name=${CA_CF_DOMAIN}&per_page=100") || return 1
    [[ $(jq '.result_info.total_pages // 1' <<<"$response") == 1 ]] || return 1
    count=$(jq '.result | length' <<<"$response")
    payload=$(jq -cn --arg name "$CA_CF_DOMAIN" --arg ip "$CA_SERVER" '{type:"A",name:$name,content:$ip,proxied:true,ttl:1}')
    if [[ $count == 0 ]]; then
        marker="CLASH-AGENT CFWS $(openssl rand -hex 12)" || return 1
        payload=$(jq -c --arg marker "$marker" '.comment=$marker' <<<"$payload") || return 1
        if ! response=$(clash_agent_cf_api POST "/zones/${CA_CF_ZONE}/dns_records" "$payload"); then
            # A failed response does not prove the write failed. Reconcile only
            # this operation's unique marker before attempting rollback.
            response=$(clash_agent_cf_api GET "/zones/${CA_CF_ZONE}/dns_records?name=${CA_CF_DOMAIN}&per_page=100") || {
                clash_agent_error 'DNS create outcome is unknown; inspect this hostname before retrying.'; return 1;
            }
            CA_CF_RECORD_ID=$(jq -r --arg marker "$marker" --arg ip "$CA_SERVER" \
                '[.result[] | select(.comment==$marker and .type=="A" and .content==$ip)] | if length==1 then .[0].id else "" end' <<<"$response")
            if [[ $CA_CF_RECORD_ID =~ ^[a-f0-9]{32}$ ]]; then CA_CF_DNS_CREATED=true; fi
            return 1
        fi
        CA_CF_RECORD_ID=$(jq -r '.result.id' <<<"$response")
        CA_CF_DNS_CREATED=true
    elif [[ $count == 1 ]]; then
        record=$(jq -c '.result[0]' <<<"$response")
        if ! jq -e --arg ip "$CA_SERVER" --arg name "$CA_CF_DOMAIN" \
            '.type == "A" and .name == $name and .content == $ip' <<<"$record" >/dev/null; then
            clash_agent_error 'Hostname already has a foreign A/AAAA/CNAME record; DNS was not overwritten.'; return 1
        fi
        CA_CF_RECORD_ID=$(jq -r '.id' <<<"$record")
        [[ $CA_CF_RECORD_ID =~ ^[a-f0-9]{32}$ ]] || return 1
        if [[ $(jq -r '.proxied' <<<"$record") != true ]]; then
            CA_CF_DNS_OLD=$(jq -c '{type,name,content,proxied,ttl}' <<<"$record")
            CA_CF_DNS_CHANGED=true
            clash_agent_cf_api PATCH "/zones/${CA_CF_ZONE}/dns_records/${CA_CF_RECORD_ID}" "$payload" >/dev/null || return 1
        fi
    else
        clash_agent_error 'Hostname has multiple DNS records; refusing ambiguous origin configuration.'; return 1
    fi
    [[ $CA_CF_RECORD_ID =~ ^[a-f0-9]{32}$ ]]
}

clash_agent_cf_rollback_dns() {
    if [[ ${CA_CF_DNS_CREATED:-false} == true ]]; then
        clash_agent_cf_api DELETE "/zones/${CA_CF_ZONE}/dns_records/${CA_CF_RECORD_ID}" >/dev/null
    elif [[ ${CA_CF_DNS_CHANGED:-false} == true ]]; then
        clash_agent_cf_api PATCH "/zones/${CA_CF_ZONE}/dns_records/${CA_CF_RECORD_ID}" "$CA_CF_DNS_OLD" >/dev/null
    fi
}
