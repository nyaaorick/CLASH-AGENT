#!/usr/bin/env bash
# Run the real state/config/rollback orchestration. Only host/network boundaries
# are replaced; all writes stay under a temporary fixture root.
set -euo pipefail
test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$test_dir/../install.sh"
work=$(mktemp -d /tmp/clash-agent-cf-install.XXXXXX)
trap 'rm -rf "$work"' EXIT
real_core=$(command -v sing-box)
export TEST_REAL_CORE=$real_core
mkdir -p "$work/bin"
cat >"$work/bin/core" <<'SH'
#!/usr/bin/env bash
if [[ $1 == generate && $2 == uuid ]]; then printf '123e4567-e89b-42d3-a456-426614174000\n';
elif [[ $1 == check ]]; then exec "$TEST_REAL_CORE" "$@";
else exit 90; fi
SH
chmod 755 "$work/bin/core"
printf '#!/usr/bin/env bash\n[[ "$*" == "-n 9" ]]\n' >"$work/bin/flock"
chmod 755 "$work/bin/flock"
export PATH="$work/bin:$PATH"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/test.key" -out "$work/test.crt" -days 2 -subj /CN=node.example.com -addext subjectAltName=DNS:node.example.com >/dev/null 2>&1
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
stage() { printf '%s\n' "$1" >>"$events"; [[ ${fail_at:-} != "$1" ]]; }
clash_agent_check_host() { CA_OS=debian; stage host; }
clash_agent_cf_origin_available() { stage origin-port; }
clash_agent_cf_dependencies() { stage dependencies; }
clash_agent_cf_prepare_core() { mkdir -p "${CA_BINARY%/*}"; stage core || return 1; cp "$work/bin/core" "$CA_BINARY"; }
systemctl() {
    case ${1:-} in
        cat) [[ ${TEST_SERVICE_EXISTS:-false} == true ]] ;;
        show) printf 'argv[]=%s run -c %s/config.json\n' "${TEST_SERVICE_BINARY:-$CA_BINARY}" "$CA_CONF_DIR" ;;
        *) return 90 ;;
    esac
}
installSingBoxService() { stage core-service || return 1; printf 'fixture core service\n' >"${CA_UNIT_DIR}/sing-box.service"; }
clash_agent_cf_discover() { stage api || return 1; CA_CF_ZONE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; CA_CF_ACCOUNT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; }
clash_agent_detect_ip() { printf '203.0.113.7\n'; }
clash_agent_cf_ensure_dns() { stage dns || return 1; printf changed >"$case_root/dns"; CA_CF_DNS_CREATED=true; }
clash_agent_cf_rollback_dns() { printf restored >"$case_root/dns"; }
clash_agent_cf_certificate() { stage certificate || return 1; mkdir -p "${CA_CF_CERT%/*}"; cp "$work/test.crt" "$CA_CF_CERT"; cp "$work/test.key" "$CA_CF_KEY"; }
clash_agent_cf_nginx_check() { stage nginx-check; }
clash_agent_cf_firewall_setup() { stage firewall; }
clash_agent_cf_firewall_prepare() { printf 'allow 127.0.0.1;\ndeny all;\n' >"$CA_CF_ALLOW"; }
clash_agent_cf_firewall_restore() { stage firewall-restore; }
clash_agent_cf_services() { stage "services-$1"; }
clash_agent_cf_health() { stage health; }
clash_agent_cf_finish_certificate() { stage renewal; }
clash_agent_configure_system() { stage system; }
clash_agent_configure_fail2ban() { stage fail2ban; }
clash_agent_verify_system() { stage verify-system; }
clash_agent_verify_fail2ban() { stage verify-fail2ban; }
clash_agent_cf_verify_maintenance() { stage maintenance; }
clash_agent_cf_service_snapshot() { printf 'nginx active\nsing-box active\n'; }
new_case() {
    case_root="$work/$1"; events="$case_root/events"
    export CLASH_AGENT_STATE_DIR="$case_root/state" CLASH_AGENT_CORE_DIR="$case_root/core"
    export CLASH_AGENT_PROFILE_DIR="$case_root/profiles" CLASH_AGENT_UNIT_DIR="$case_root/units"
    export CLASH_AGENT_NGINX_DIR="$case_root/nginx" CLASH_AGENT_LOCK_FILE="$case_root/install.lock"
    export CF_API_TOKEN=fixture_token_never_logged_123456789
    mkdir -p "$case_root" "$CLASH_AGENT_UNIT_DIR" "$CLASH_AGENT_NGINX_DIR/conf.d"
    : >"$events"; fail_at=
    unset TEST_SERVICE_EXISTS TEST_SERVICE_BINARY
}
run_install() { clash_agent_main install --mode cloudflare-ws --domain node.example.com "$@" >"$case_root/out" 2>"$case_root/err"; }
new_case fresh
run_install || { cat "$case_root/err"; fail 'fresh CF installation'; }
jq -e '.schema==2 and .mode=="cloudflare-ws" and .status=="ready" and .domain=="node.example.com" and .ws_port==10443' "$CLASH_AGENT_STATE_DIR/state.json" >/dev/null
before=$(jq -c '[.uuid,.ws_path,.token]' "$CLASH_AGENT_STATE_DIR/state.json")
[[ $(grep -c '^https://node.example.com/s/' "$case_root/out") == 1 ]] || fail 'private HTTPS subscription missing'
run_install || fail 'repeat installation'
[[ $before == "$(jq -c '[.uuid,.ws_path,.token]' "$CLASH_AGENT_STATE_DIR/state.json")" ]] || fail 'repeat changed identity'
[[ $(grep -c '^state-ready$' "$events" || true) == 0 ]] || fail 'unexpected stub'

for fail_at_stage in api dns certificate nginx-check firewall services-start health renewal maintenance verify-system verify-fail2ban; do
    new_case "failure-$fail_at_stage"; fail_at=$fail_at_stage
    if run_install; then fail "ignored failure: $fail_at_stage"; fi
    if grep -Eq '^https://|configured:' "$case_root/out"; then fail "false success: $fail_at_stage"; fi
    if [[ -f $case_root/dns && $fail_at_stage != dns ]]; then [[ $(cat "$case_root/dns") == restored ]] || fail "DNS rollback: $fail_at_stage"; fi
done

new_case unmanaged
mkdir -p "$CLASH_AGENT_CORE_DIR/sing-box/conf"
printf 'existing\n' >"$CLASH_AGENT_CORE_DIR/sing-box/conf/config.json"
if run_install; then fail 'unmanaged installation overwritten'; fi
[[ $(cat "$CLASH_AGENT_CORE_DIR/sing-box/conf/config.json") == existing ]] || fail 'unmanaged content changed'
[[ ! -s $events || $(wc -l <"$events") -le 1 ]] || fail 'unmanaged rejection too late'

new_case vendor-service
TEST_SERVICE_EXISTS=true
if run_install; then fail 'unrelated vendor sing-box service was accepted as fresh'; fi
[[ ! -e $case_root/dns ]] || fail 'vendor-service refusal mutated DNS'

new_case failed-core-retry
fail_at=core
if run_install; then fail 'core failure ignored'; fi
fail_at=
run_install || { cat "$case_root/err"; fail 'same command cannot recover core download failure'; }

new_case adopt
TEST_SERVICE_EXISTS=true
mkdir -p "$CLASH_AGENT_CORE_DIR/sing-box/conf/config"
cp "$work/bin/core" "$CLASH_AGENT_CORE_DIR/sing-box/sing-box"
clash_agent_cf_render_core node.example.com 10443 123e4567-e89b-42d3-a456-426614174000 /existingws Preserved >"$CLASH_AGENT_CORE_DIR/sing-box/conf/config.json"
jq '.inbounds[0].transport.max_early_data=2048 | .inbounds[0].transport.early_data_header_name="Sec-WebSocket-Protocol"' \
    "$CLASH_AGENT_CORE_DIR/sing-box/conf/config.json" >"$case_root/adopt.json"
mv "$case_root/adopt.json" "$CLASH_AGENT_CORE_DIR/sing-box/conf/config.json"
cat >"$CLASH_AGENT_NGINX_DIR/conf.d/sub.conf" <<EOF
server {
 listen 443 ssl;
 server_name node.example.com;
 ssl_certificate $work/test.crt;
 ssl_certificate_key $work/test.key;
 location = /clash.yaml { root /var/www/sub; }
 location /existingws { proxy_pass http://127.0.0.1:10443; }
 location / { return 200 'camouflage'; }
}
server { listen 80; server_name unrelated.example.com; return 200 'preserve-me'; }
server { listen 80; server_name node.example.com; return 301 https://node.example.com; }
EOF
original=$(cat "$CLASH_AGENT_NGINX_DIR/conf.d/sub.conf")
fail_at=health
if run_install --adopt-existing; then fail 'adoption health failure ignored'; fi
[[ $(cat "$CLASH_AGENT_NGINX_DIR/conf.d/sub.conf") == "$original" ]] || fail 'failed adoption lost original nginx site'
jq -e '.inbounds[0].transport.path=="/existingws"' "$CLASH_AGENT_CORE_DIR/sing-box/conf/config.json" >/dev/null
fail_at=
run_install --adopt-existing || { cat "$case_root/err"; fail 'adoption'; }
jq -e '.ws_path=="/existingws" and .uuid=="123e4567-e89b-42d3-a456-426614174000"' "$CLASH_AGENT_STATE_DIR/state.json" >/dev/null
jq -e '.inbounds[0].transport.max_early_data==2048 and .inbounds[0].transport.early_data_header_name=="Sec-WebSocket-Protocol"' \
    "$CLASH_AGENT_CORE_DIR/sing-box/conf/config.json" >/dev/null
grep -q preserve-me "$CLASH_AGENT_NGINX_DIR/conf.d/sub.conf" || fail 'unrelated nginx vhost lost'
[[ -s $CLASH_AGENT_CORE_DIR/sing-box/conf/config/03_VLESS_WS_inbounds.json ]] || fail 'effective/source fragment inconsistent'
printf 'PASS: Cloudflare installation, retry identity, explicit adoption and failure rollback.\n'
