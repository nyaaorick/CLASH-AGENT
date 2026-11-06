#!/usr/bin/env bash
# Run the real unattended orchestration and renderers with every host-changing
# boundary replaced by a local fixture. No installer, network request, service,
# firewall, sysctl or swap operation reaches the test host.
set -euo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
test_root=$(mktemp -d /tmp/clash-agent-auto-tests.XXXXXX)
trap 'rm -rf -- "$test_root"' EXIT
export TEST_REAL_SING_BOX
TEST_REAL_SING_BOX=$(command -v sing-box || true)
source "${test_dir}/../install.sh"
declare -F clash_agent_check_host >/dev/null

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
record() { printf '%s\n' "$*" >>"$TEST_EVENT_LOG"; }
stage() {
    record "$1"
    [[ ${TEST_FAIL_STAGE:-} != "$1" ]]
}

# Retain real state serialization and the shared upstream Reality emitter;
# wrappers only introduce failures at their public call boundaries.
eval "$(declare -f clash_agent_write_state | sed '1s/clash_agent_write_state/clash_agent_real_write_state/')"
eval "$(declare -f writeSingBoxRealityInbound | sed '1s/writeSingBoxRealityInbound/clash_agent_real_write_inbound/')"
clash_agent_write_state() {
    local phase=state-initial
    [[ ! -e $CA_STATE_FILE ]] || phase=state-installing
    [[ $1 != ready ]] || phase=state-ready
    stage "$phase" || return 1
    clash_agent_real_write_state "$@"
}
writeSingBoxRealityInbound() {
    stage reality-emitter || return 1
    clash_agent_real_write_inbound "$@"
}

clash_agent_check_host() { stage preflight || return 1; CA_OS=debian; }
clash_agent_install_dependencies() { stage dependencies; }
clash_agent_detect_ip() { stage detect-ip || return 1; printf '203.0.113.7\n'; }
clash_agent_select_sni() { stage select-sni || return 1; printf 'www.example.com\n'; }
clash_agent_random_port() {
    stage random-port || return 1
    if [[ ${1:-0} == 0 ]]; then printf '23456\n'; else printf '34567\n'; fi
}
initRealityKey() {
    stage reality-keys || return 1
    realityPrivateKey=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    realityPublicKey=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
}
clash_agent_configure_system() { stage system-defaults; }
installSingBoxService() {
    stage core-service || return 1
    [[ ${1:-} == 2 && ${2:-} == defer ]] || return 1
    printf 'fixture sing-box service\n' >"${CA_UNIT_DIR}/sing-box.service"
}
clash_agent_open_port() {
    if [[ $1 == "$CA_REALITY_PORT" ]]; then stage open-reality; else stage open-subscription; fi
}
clash_agent_prepare_core() {
    stage prepare-core || return 1
    mkdir -p "${CA_CONF_DIR}/config" || return 1
    cp "${test_root}/bin/sing-box-fixture" "$CA_BINARY" || return 1
    chmod 755 "$CA_BINARY"
}

mkdir -p "${test_root}/bin"
cat >"${test_root}/bin/sing-box-fixture" <<'MOCK'
#!/usr/bin/env bash
set -eu
case ${1:-} in
    generate)
        [[ ${2:-} == uuid ]] || exit 90
        printf 'generate-uuid\n' >>"$TEST_EVENT_LOG"
        [[ ${TEST_FAIL_STAGE:-} != generate-uuid ]] || exit 1
        printf '123e4567-e89b-42d3-a456-426614174000\n'
        ;;
    check)
        printf 'core-check\n' >>"$TEST_EVENT_LOG"
        [[ ${TEST_FAIL_STAGE:-} != core-check ]] || exit 1
        [[ ${2:-} == -c && -s ${3:-} ]] || exit 90
        if [[ -n ${TEST_REAL_SING_BOX:-} ]]; then
            exec "$TEST_REAL_SING_BOX" "$@"
        fi
        jq -e '.inbounds[0].tls.reality.enabled == true' "$3" >/dev/null
        ;;
    version) printf 'sing-box fixture\n' ;;
    *) printf 'Unexpected core invocation\n' >&2; exit 90 ;;
esac
MOCK
cat >"${test_root}/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
set -eu
case ${1:-} in
    cat)
        printf 'service-discovery\n' >>"$TEST_EVENT_LOG"
        [[ ${TEST_EXISTING_SERVICE:-0} == 1 ]]
        ;;
    daemon-reload|enable|restart)
        printf 'systemctl-%s\n' "$1" >>"$TEST_EVENT_LOG"
        [[ ${TEST_FAIL_STAGE:-} != "systemctl-$1" ]]
        ;;
    is-active)
        printf 'verify-%s\n' "${*: -1}" >>"$TEST_EVENT_LOG"
        [[ ${TEST_FAIL_STAGE:-} != verify-services ]]
        ;;
    *) printf 'Unexpected systemctl invocation\n' >&2; exit 90 ;;
esac
MOCK
cat >"${test_root}/bin/flock" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf 'lock\n' >>"$TEST_EVENT_LOG"
[[ $# == 2 && $1 == -n && $2 == 9 ]] || exit 90
[[ ${TEST_FAIL_STAGE:-} != lock ]]
MOCK
cat >"${test_root}/bin/nginx" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf 'nginx-check\n' >>"$TEST_EVENT_LOG"
[[ ${1:-} == -t ]] || { printf 'Only nginx configuration parsing is allowed\n' >&2; exit 90; }
[[ ${TEST_FAIL_STAGE:-} != nginx-check ]]
MOCK
cat >"${test_root}/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf 'subscription-fetch\n' >>"$TEST_EVENT_LOG"
[[ ${TEST_FAIL_STAGE:-} != subscription-fetch ]] || exit 1
output= url=
while (($#)); do
    case $1 in
        -o) output=$2; shift 2 ;;
        http://127.0.0.1:*) url=$1; shift ;;
        *) shift ;;
    esac
done
[[ -n $output && -n $url && $output == "$CLASH_AGENT_STATE_DIR/"* ]] || {
    printf 'Network access is forbidden in this test\n' >&2; exit 90;
}
if [[ ${TEST_FAIL_STAGE:-} == subscription-mismatch ]]; then
    printf 'wrong profile\n' >"$output"
else
    cp "$CLASH_AGENT_PROFILE_DIR/clash.yaml" "$output"
fi
MOCK
chmod 755 "${test_root}/bin/"*
export PATH="${test_root}/bin:$PATH"

new_case() {
    export TEST_CASE_ROOT="${test_root}/$1"
    export TEST_EVENT_LOG="${TEST_CASE_ROOT}/events"
    export CLASH_AGENT_STATE_DIR="${TEST_CASE_ROOT}/state"
    export CLASH_AGENT_CORE_DIR="${TEST_CASE_ROOT}/core"
    export CLASH_AGENT_PROFILE_DIR="${TEST_CASE_ROOT}/profiles"
    export CLASH_AGENT_UNIT_DIR="${TEST_CASE_ROOT}/units"
    export CLASH_AGENT_LOCK_FILE="${TEST_CASE_ROOT}/install.lock"
    unset TEST_FAIL_STAGE TEST_EXISTING_SERVICE
    mkdir -p "$TEST_CASE_ROOT" "$CLASH_AGENT_UNIT_DIR"
    : >"$TEST_EVENT_LOG"
    clash_agent_paths
}

install_success() {
    if ! clash_agent_main install >"$TEST_CASE_ROOT/output" 2>"$TEST_CASE_ROOT/errors"; then
        cat "$TEST_CASE_ROOT/errors" >&2
        fail 'mock installation failed'
    fi
    grep -q '^CLASH-AGENT configured:' "$TEST_CASE_ROOT/output" || fail 'success summary missing'
    [[ $(grep -c '^http://.*clash.yaml$' "$TEST_CASE_ROOT/output") == 1 ]] || fail 'expected one final subscription link'
}
install_failure() {
    if clash_agent_main install >"$TEST_CASE_ROOT/output" 2>"$TEST_CASE_ROOT/errors"; then
        fail "failure was ignored: ${TEST_FAIL_STAGE:-preflight}"
    fi
    if grep -Eq '^CLASH-AGENT configured:|^https?://' "$TEST_CASE_ROOT/output"; then
        fail 'failed installation printed a success summary or subscription link'
    fi
}

new_case fresh
install_success
jq -e '.product == "CLASH-AGENT" and .schema == 1 and .status == "ready" and
    .reality_port == 23456 and .subscription_port == 34567 and
    (.short_id | test("^[a-f0-9]{16}$")) and (.token | test("^[a-f0-9]{64}$")) and
    (.node_name | test("^CLASH-AGENT-[a-f0-9]{8}$"))' "$CA_STATE_FILE" >/dev/null
jq -e --slurpfile state "$CA_STATE_FILE" '
    (.inbounds | length) == 1 and .inbounds[0].type == "vless" and
    .inbounds[0].listen_port == $state[0].reality_port and
    .inbounds[0].users[0].uuid == $state[0].uuid and
    .inbounds[0].users[0].flow == "xtls-rprx-vision" and
    .inbounds[0].tls.reality.private_key == $state[0].private_key and
    .inbounds[0].tls.reality.short_id == [$state[0].short_id] and
    .inbounds[0].tls.reality.handshake.server == $state[0].sni and
    .inbounds[0].tls.reality.handshake.server_port == 443 and
    .outbounds == [{type:"direct",tag:"direct"}]' "${CA_CONF_DIR}/config.json" >/dev/null
token=$(jq -r .token "$CA_STATE_FILE")
short_id=$(jq -r .short_id "$CA_STATE_FILE")
grep -Fq "http://203.0.113.7:34567/s/$token/clash.yaml" "$TEST_CASE_ROOT/output"
grep -Fq "short-id: \"$short_id\"" "${CA_PROFILE_DIR}/clash.yaml"
grep -Fq "location = /s/$token/clash.yaml" "${CA_STATE_DIR}/subscription.conf"
grep -Fq 'ExecStart=' "${CA_UNIT_DIR}/clash-agent-subscription.service"
if grep -Fq 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' "${CA_PROFILE_DIR}/clash.yaml"; then fail 'private key leaked into Clash profile'; fi
python3 - "$CA_STATE_FILE" "${CA_STATE_DIR}/owner" "${CA_CONF_DIR}/config.json" <<'PY'
from pathlib import Path
import stat, sys
for name in sys.argv[1:]:
    assert stat.S_IMODE(Path(name).stat().st_mode) == 0o600, name
assert stat.S_IMODE(Path(sys.argv[1]).parent.stat().st_mode) == 0o700
PY

# A completed installation reruns without replacing its identities or token.
identity=$(jq -cS 'del(.status)' "$CA_STATE_FILE")
profile=$(cat "${CA_PROFILE_DIR}/clash.yaml")
install_success
[[ $(jq -cS 'del(.status)' "$CA_STATE_FILE") == "$identity" ]] || fail 'rerun replaced saved credentials'
[[ $(cat "${CA_PROFILE_DIR}/clash.yaml") == "$profile" ]] || fail 'rerun changed the profile'
[[ $(grep -c '^reality-keys$' "$TEST_EVENT_LOG") == 1 ]] || fail 'rerun regenerated keys'
[[ $(grep -c '^generate-uuid$' "$TEST_EVENT_LOG") == 1 ]] || fail 'rerun regenerated UUID'
[[ $(grep -c '^select-sni$' "$TEST_EVENT_LOG") == 1 ]] || fail 'rerun regenerated SNI'
[[ $(grep -c '^random-port$' "$TEST_EVENT_LOG") == 2 ]] || fail 'rerun regenerated ports'

# Inject an error at every stage before final publication. Real file generation,
# state reads/writes and profile rendering remain in place in each fixture.
for failure in preflight lock dependencies prepare-core detect-ip select-sni random-port \
    generate-uuid reality-keys state-initial state-installing system-defaults reality-emitter \
    core-check core-service nginx-check open-reality open-subscription systemctl-daemon-reload \
    systemctl-enable systemctl-restart verify-services subscription-fetch subscription-mismatch state-ready; do
    new_case "failure-$failure"
    export TEST_FAIL_STAGE=$failure
    install_failure
done

# A partial installation can resume with exactly the values already persisted.
new_case recovery
export TEST_FAIL_STAGE=system-defaults
install_failure
[[ $(jq -r .status "$CA_STATE_FILE") == installing ]] || fail 'partial state not saved'
identity=$(jq -cS 'del(.status)' "$CA_STATE_FILE")
unset TEST_FAIL_STAGE
install_success
[[ $(jq -cS 'del(.status)' "$CA_STATE_FILE") == "$identity" ]] || fail 'recovery replaced saved credentials'
[[ $(grep -c '^reality-keys$' "$TEST_EVENT_LOG") == 1 ]] || fail 'recovery regenerated keys'

# Test the actual preflight ownership checks, only replacing host/OS detection.
for existing in core state profiles unit service symlink; do
    new_case "unmanaged-$existing"
    case $existing in
        core) mkdir "$CA_CORE_DIR"; printf 'keep\n' >"$CA_CORE_DIR/foreign" ;;
        state) mkdir "$CA_STATE_DIR"; printf 'foreign\n' >"$CA_STATE_DIR/owner" ;;
        profiles) mkdir "$CA_PROFILE_DIR"; printf 'keep\n' >"$CA_PROFILE_DIR/foreign" ;;
        unit) printf 'foreign service\n' >"$CA_UNIT_DIR/clash-agent-subscription.service" ;;
        service) export TEST_EXISTING_SERVICE=1 ;;
        symlink) mkdir "$TEST_CASE_ROOT/foreign"; printf 'keep\n' >"$TEST_CASE_ROOT/foreign/data"; ln -s "$TEST_CASE_ROOT/foreign" "$CA_STATE_DIR" ;;
    esac
    install_failure
    if grep -Eq '^dependencies$|^prepare-core$' "$TEST_EVENT_LOG"; then fail 'unmanaged installation reached mutating stages'; fi
    case $existing in
        core) [[ $(cat "$CA_CORE_DIR/foreign") == keep ]] ;;
        state) [[ $(cat "$CA_STATE_DIR/owner") == foreign ]] ;;
        profiles) [[ $(cat "$CA_PROFILE_DIR/foreign") == keep ]] ;;
        unit) [[ $(cat "$CA_UNIT_DIR/clash-agent-subscription.service") == 'foreign service' ]] ;;
        symlink) [[ -L $CA_STATE_DIR && $(cat "$TEST_CASE_ROOT/foreign/data") == keep ]] ;;
    esac
done

new_case lock-rejected
export TEST_FAIL_STAGE=lock
install_failure
[[ ! -e $CA_STATE_DIR && ! -e $CA_CORE_DIR && ! -e $CA_PROFILE_DIR ]] || fail 'lock rejection changed managed paths'

# A corrupt managed state must not be silently replaced with fresh credentials.
new_case corrupt-state
mkdir "$CA_STATE_DIR"
printf 'CLASH-AGENT\n' >"$CA_STATE_DIR/owner"
printf '{"product":"CLASH-AGENT","schema":1}\n' >"$CA_STATE_FILE"
before=$(cat "$CA_STATE_FILE")
install_failure
[[ $(cat "$CA_STATE_FILE") == "$before" ]] || fail 'corrupt state was overwritten'
if grep -q '^reality-keys$' "$TEST_EVENT_LOG"; then fail 'corrupt state triggered new credentials'; fi

new_case command-line
clash_agent_main --help >"$TEST_CASE_ROOT/help"
grep -q '^CLASH-AGENT$' "$TEST_CASE_ROOT/help"
[[ ! -s $TEST_EVENT_LOG ]] || fail 'help triggered installation work'
if clash_agent_main install unexpected >"$TEST_CASE_ROOT/output" 2>"$TEST_CASE_ROOT/errors"; then fail 'extra installation argument accepted'; fi
[[ ! -s $TEST_EVENT_LOG ]] || fail 'invalid command triggered installation work'

printf 'PASS: unattended orchestration, real Reality/Clash output, 25 failure stages, rerun/recovery, unmanaged paths, lock and corrupt state.\n'
