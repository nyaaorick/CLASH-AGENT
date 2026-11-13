#!/usr/bin/env bash
# ACME invokes this entry point with a public challenge value, never the API
# token. Reuse the protected curl-config API transport for both issue and renew.
clash_agent_cf_dns_challenge() {
    [[ $# == 3 && ($1 == add || $1 == remove) ]] || return 1
    local action=$1 name=${2%.} value=$3 response ids id payload
    CA_CF_DOMAIN= CA_CF_SITE=
    clash_agent_cf_paths
    clash_agent_cf_read_state || return 1
    name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
    [[ $name == "_acme-challenge.${CA_CF_DOMAIN}" && $value =~ ^[A-Za-z0-9_-]{20,200}$ ]] || return 1
    CA_CF_TOKEN_FILE="${CA_STATE_DIR}/cloudflare-token"
    clash_agent_cf_load_token || return 1
    response=$(clash_agent_cf_api GET "/zones/${CA_CF_ZONE}/dns_records?type=TXT&name=${name}&per_page=100") || return 1
    [[ $(jq '.result_info.total_pages // 1' <<<"$response") == 1 ]] || return 1
    ids=$(jq -r --arg name "$name" --arg value "$value" '.result[] | select(.type=="TXT" and .name==$name and .content==$value) | .id' <<<"$response") || return 1
    if [[ $action == add ]]; then
        [[ -z $ids ]] || return 0
        payload=$(jq -cn --arg name "$name" --arg value "$value" '{type:"TXT",name:$name,content:$value,ttl:120}') || return 1
        if ! clash_agent_cf_api POST "/zones/${CA_CF_ZONE}/dns_records" "$payload" >/dev/null; then
            clash_agent_cf_dns_challenge remove "$name" "$value" || printf 'CLASH-AGENT: DNS-01 cleanup needs inspection.\n' >&2
            return 1
        fi
    else
        while read -r id; do
            [[ -n $id ]] || continue
            [[ $id =~ ^[a-f0-9]{32}$ ]] || return 1
            clash_agent_cf_api DELETE "/zones/${CA_CF_ZONE}/dns_records/${id}" >/dev/null || return 1
        done <<<"$ids"
    fi
}

clash_agent_cf_render_dns_hook() {
    cat <<'HOOK'
#!/usr/bin/env sh
# Public DNS-01 values are passed on argv; the DNS Edit token stays in a private
# file and a 0600 curl configuration created by the CLASH-AGENT runtime helper.
_clash_cf_run() {
    _clash_installer="${CLASH_CF_INSTALLER:-$(_readaccountconf_mutable CLASH_CF_INSTALLER)}"
    _clash_state="${CLASH_CF_STATE_DIR:-$(_readaccountconf_mutable CLASH_CF_STATE_DIR)}"
    [ -f "$_clash_installer" ] && [ -d "$_clash_state" ] || return 1
    _saveaccountconf_mutable CLASH_CF_INSTALLER "$_clash_installer" || return 1
    _saveaccountconf_mutable CLASH_CF_STATE_DIR "$_clash_state" || return 1
    [ "$(_readaccountconf_mutable CLASH_CF_INSTALLER)" = "$_clash_installer" ] || return 1
    [ "$(_readaccountconf_mutable CLASH_CF_STATE_DIR)" = "$_clash_state" ] || return 1
    CLASH_AGENT_STATE_DIR="$_clash_state" /bin/bash "$_clash_installer" dns-challenge "$1" "$2" "$3"
}
dns_clash_agent_cf_add() { _clash_cf_run add "$1" "$2"; }
dns_clash_agent_cf_rm() { _clash_cf_run remove "$1" "$2"; }
HOOK
}

clash_agent_cf_prepare_dns_hook() {
    local runtime="${CA_STATE_DIR}/installer.sh" token="${CA_STATE_DIR}/cloudflare-token"
    [[ ! -L $runtime && ! -L $token ]] || return 1
    if [[ -n ${CLASH_AGENT_SOURCE_DIR:-} && -f ${CLASH_AGENT_SOURCE_DIR}/build.sh ]]; then
        bash "${CLASH_AGENT_SOURCE_DIR}/build.sh" "${runtime}.new" >/dev/null || return 1
    else
        cp "$CLASH_AGENT_ENTRY" "${runtime}.new" || return 1
    fi
    chmod 700 "${runtime}.new" && mv -f "${runtime}.new" "$runtime" || return 1
    printf '%s\n' "$CA_CF_TOKEN" >"${token}.new" && chmod 600 "${token}.new" && mv -f "${token}.new" "$token" || return 1
    mkdir -p "${CA_CF_ACME_HOME}/dnsapi" || return 1
    clash_agent_cf_render_dns_hook >"${CA_CF_ACME_HOME}/dnsapi/dns_clash_agent_cf.sh" &&
        chmod 600 "${CA_CF_ACME_HOME}/dnsapi/dns_clash_agent_cf.sh"
}
