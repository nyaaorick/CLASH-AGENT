#!/usr/bin/env bash
set -euo pipefail
test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$test_dir/../install.sh"
work=$(mktemp -d /tmp/clash-agent-cf-config.XXXXXX)
trap 'rm -rf "$work"' EXIT
uuid=123e4567-e89b-42d3-a456-426614174000
token=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
clash_agent_cf_render_core node.example.com 10443 "$uuid" /samplews Example >"$work/core.json"
jq -e '.inbounds[0].listen == "127.0.0.1" and .inbounds[0].listen_port == 10443 and
 .inbounds[0].transport.path == "/samplews" and (.inbounds[0] | has("tls") | not) and
 .outbounds[0].type == "direct"' "$work/core.json" >/dev/null
clash_agent_cf_render_profile node.example.com "$uuid" /samplews Example >"$work/profile.yaml"
if command -v sing-box >/dev/null; then sing-box check -c "$work/core.json"; fi
if command -v mihomo >/dev/null; then mihomo -t -d "$work" -f "$work/profile.yaml" >"$work/mihomo.log" 2>&1; fi
if command -v ruby >/dev/null; then
    ruby -ryaml -e 'd=YAML.load_file(ARGV[0]); n=d["proxies"][0]; abort unless n["network"]=="ws" && n["udp"] && n["servername"]=="node.example.com" && n["ws-opts"]["headers"]["Host"]=="node.example.com"; abort unless d["allow-lan"]==false && !d.key?("external-controller")' "$work/profile.yaml"
fi
clash_agent_cf_render_nginx node.example.com 10443 /samplews /var/lib/clash-agent/clash.yaml "$token" /etc/clash-agent/tls/node.crt /etc/clash-agent/tls/node.key /etc/clash-agent/cloudflare-allow.conf >"$work/site.conf"
grep -Fq 'proxy_pass http://127.0.0.1:10443;' "$work/site.conf"
grep -Fq "location = /s/$token/clash.yaml" "$work/site.conf"
grep -Fq 'Cache-Control "no-store"' "$work/site.conf"
if clash_agent_cf_render_core 'bad;domain' 10443 "$uuid" /samplews Example >"$work/reject" 2>/dev/null; then exit 1; fi
[[ ! -s $work/reject ]]
clash_agent_cf_install() { printf 'MODE=%s DOMAIN=%s ADOPT=%s\n' "$CA_MODE" "$CA_CF_DOMAIN" "$CA_CF_ADOPT"; }
[[ $(clash_agent_main install --mode cloudflare-ws --domain node.example.com --adopt-existing) == 'MODE=cloudflare-ws DOMAIN=node.example.com ADOPT=true' ]]
if clash_agent_main install --mode unknown >"$work/reject" 2>/dev/null; then exit 1; fi
printf 'PASS: Cloudflare chain renderers and CLI.\n'
