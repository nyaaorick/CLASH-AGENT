#!/usr/bin/env bash
set -euo pipefail
test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "${test_dir}/../lib/clash-subscription.sh"
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/clash-agent-subscription.XXXXXX")
trap 'rm -rf -- "$test_tmp"' EXIT

uuid=123e4567-e89b-42d3-a456-426614174000
public_key=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
short_id=abcd1234abcd1234
token=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
reject() { if "$@" >"$test_tmp/rejected.out" 2>"$test_tmp/rejected.err"; then fail 'invalid input was accepted'; fi; [[ ! -s "$test_tmp/rejected.out" ]] || fail 'rejected input emitted partial output'; }

for address in 203.0.113.7 2001:db8::7 ::1 ::ffff:192.0.2.7; do
    clash_agent_subscription_valid_ip "$address" || fail 'valid IP rejected'
done
for address in '203.0.113.256' '01.2.3.4' 'example.com' '[2001:db8::7]' '2001:db8:::7' '2001::db8::7' '2001:db8:1' '1:2:3:4:5:6:7:8::'; do
    if clash_agent_subscription_valid_ip "$address"; then fail 'invalid IP accepted'; fi
done

clash_agent_render_clash_profile 203.0.113.7 23456 "$uuid" "$public_key" "$short_id" www.example.com Reality-test >"$test_tmp/clash-v4.yaml"
clash_agent_render_clash_profile 2001:db8::7 23456 "$uuid" "$public_key" "$short_id" www.example.com Reality-test >"$test_tmp/clash-v6.yaml"
grep -q 'server: "2001:db8::7"' "$test_tmp/clash-v6.yaml" || fail 'IPv6 not quoted'
grep -q 'short-id: "abcd1234abcd1234"' "$test_tmp/clash-v4.yaml" || fail 'short ID not preserved as a string'
grep -q '^  - MATCH,CLASH-AGENT$' "$test_tmp/clash-v4.yaml" || fail 'standalone routing missing'
if grep -Eq 'private-key|proxy-providers|rule-providers' "$test_tmp/clash-v4.yaml"; then fail 'profile leaked a private key or requires a second download'; fi

# A hostile display name must remain a single YAML string in both references.
hostile_name=$'name"; $(touch /tmp/not-run)\nrules:\n  - MATCH,DIRECT'
clash_agent_render_clash_profile 203.0.113.7 23456 "$uuid" "$public_key" "$short_id" www.example.com "$hostile_name" >"$test_tmp/quoted.yaml"
encoded_name=$(jq -cn --arg value "$hostile_name" '$value')
grep -Fq -- "  - name: $encoded_name" "$test_tmp/quoted.yaml" || fail 'node name escaped incorrectly'
grep -Fq -- "      - $encoded_name" "$test_tmp/quoted.yaml" || fail 'group reference escaped incorrectly'
[[ $(grep -c '^rules:$' "$test_tmp/quoted.yaml") == 1 ]] || fail 'name injected YAML keys'

[[ $(clash_agent_subscription_url 203.0.113.7 28080 "$token") == "http://203.0.113.7:28080/s/$token/clash.yaml" ]] || fail 'IPv4 URL mismatch'
[[ $(clash_agent_subscription_url 2001:db8::7 28080 "$token") == "http://[2001:db8::7]:28080/s/$token/clash.yaml" ]] || fail 'IPv6 URL brackets missing'
clash_agent_render_subscription_nginx 28080 /etc/clash-agent/clash.yaml "$token" true >"$test_tmp/subscribe.conf"
grep -Fq "location = /s/$token/clash.yaml {" "$test_tmp/subscribe.conf" || fail 'bearer location is not an exact match'
grep -Fq 'listen [::]:28080 ipv6only=on;' "$test_tmp/subscribe.conf" || fail 'IPv6 listener missing'
grep -Fq 'location / { return 404; }' "$test_tmp/subscribe.conf" || fail 'unguarded fallback path'
grep -Fq 'access_log off;' "$test_tmp/subscribe.conf" || fail 'URL token could be logged'
grep -Fq 'alias "/etc/clash-agent/clash.yaml";' "$test_tmp/subscribe.conf" || fail 'file alias mismatch'
clash_agent_render_subscription_nginx 28080 /etc/clash-agent/clash.yaml "$token" >"$test_tmp/subscribe-v4.conf"
if grep -Fq 'listen [::]' "$test_tmp/subscribe-v4.conf"; then fail 'IPv6 enabled implicitly'; fi

reject clash_agent_render_clash_profile '203.0.113.7; bad' 23456 "$uuid" "$public_key" "$short_id" www.example.com Reality-test
reject clash_agent_render_clash_profile 203.0.113.7 65536 "$uuid" "$public_key" "$short_id" www.example.com Reality-test
reject clash_agent_render_clash_profile 203.0.113.7 23456 "$uuid" "$public_key" abc www.example.com Reality-test
reject clash_agent_render_clash_profile 203.0.113.7 23456 "$uuid" "$public_key" "$short_id" $'example.com\ninvalid' Reality-test
reject clash_agent_render_clash_profile 203.0.113.7 23456 "$uuid" "$public_key" "$short_id" www.example.com CLASH-AGENT
reject clash_agent_render_subscription_nginx 28080 '/etc/profile"; return 200;' "$token"
reject clash_agent_render_subscription_nginx 28080 '/etc/../profile' "$token"
reject clash_agent_render_subscription_nginx 28080 /etc/clash-agent/clash.yaml short-token
reject clash_agent_subscription_url 2001:db8:::7 28080 "$token"

# Parsing only: the profile uses no remote rule sets, so no network is needed.
if command -v mihomo >/dev/null 2>&1; then
    mkdir "$test_tmp/mihomo"
    for profile in clash-v4.yaml clash-v6.yaml quoted.yaml; do
        if ! mihomo -t -d "$test_tmp/mihomo" -f "$test_tmp/$profile" >"$test_tmp/mihomo.log" 2>&1; then
            cat "$test_tmp/mihomo.log" >&2
            fail 'mihomo rejected rendered profile'
        fi
    done
fi
printf 'PASS: Clash subscription renderers (IPv4/IPv6, escaping, bearer paths, input rejection).\n'
