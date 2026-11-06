#!/usr/bin/env bash
# All host-changing boundaries are mocks; optional native ConfigReader checks
# use only temporary configuration trees, never a running Fail2ban server.
set -euo pipefail
test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "${test_dir}/../lib/fail2ban.sh"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/clash-agent-fail2ban-tests.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
mkdir -p "${test_root}/bin"
export PATH="${test_root}/bin:$PATH"
export CLASH_AGENT_FAIL2BAN_PYTHON
CLASH_AGENT_FAIL2BAN_PYTHON=$(command -v python3)
eval "$(declare -f clash_agent_fail2ban_existing_ignores | sed '1s/clash_agent_fail2ban_existing_ignores/clash_agent_fail2ban_native_ignores/')"
clash_agent_fail2ban_existing_ignores() {
    [[ ${TEST_FAIL:-} != reader ]] || return 1
    local file="${CLASH_AGENT_FAIL2BAN_DIR}/jail.d/zz-clash-agent-sshd.local"
    if [[ -f $file ]]; then sed -n 's/^ignoreip = //p' "$file"
    else printf '%s\n' "${TEST_PRIOR_IGNORES:-}"; fi
}
cat >"${test_root}/bin/sshd" <<'MOCK'
#!/usr/bin/env bash
[[ $* == -T ]] || exit 90
[[ ${TEST_FAIL:-} != sshd ]] || exit 1
printf '%s\n' "${TEST_SSHD_CONFIG- port 22}" | sed 's/^ //'
MOCK
cat >"${test_root}/bin/ss" <<'MOCK'
#!/usr/bin/env bash
[[ $* == '-H -ltnp' ]] || exit 90
[[ ${TEST_FAIL:-} != ss ]] || exit 1
printf '%s\n' "${TEST_LISTENERS-}"
MOCK
cat >"${test_root}/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf 'systemctl %s\n' "$*" >>"$TEST_DIR/events"
case ${1:-} in
    is-active)
        case ${3:-} in
            ssh.socket) [[ ${TEST_SOCKET_ACTIVE:-0} == 1 ]] ;;
            sshd.socket) exit 1 ;;
            fail2ban.service) [[ $(cat "$TEST_DIR/active") == 1 ]] ;;
            *) exit 90 ;;
        esac ;;
    is-enabled) [[ $(cat "$TEST_DIR/enabled") == 1 ]] ;;
    show)
        [[ ${TEST_FAIL:-} != socket-show ]] || exit 1
        printf '%s\n' "${TEST_SOCKET_LISTEN:-[::]:2222 (Stream)}" ;;
    start)
        [[ ${TEST_FAIL:-} != start ]] || exit 1
        printf 1 >"$TEST_DIR/active" ;;
    enable)
        [[ ${TEST_FAIL:-} != enable ]] || exit 1
        printf 1 >"$TEST_DIR/enabled" ;;
    stop) printf 0 >"$TEST_DIR/active" ;;
    disable) printf 0 >"$TEST_DIR/enabled" ;;
    *) exit 90 ;;
esac
MOCK
cat >"${test_root}/bin/fail2ban-client" <<'MOCK'
#!/usr/bin/env bash
set -eu
[[ $1 == -c && $2 == "$CLASH_AGENT_FAIL2BAN_DIR" ]] || exit 90
shift 2
printf 'client %s\n' "$*" >>"$TEST_DIR/events"
file="$CLASH_AGENT_FAIL2BAN_DIR/jail.d/zz-clash-agent-sshd.local"
case ${1:-} in
    -t) [[ ${TEST_FAIL:-} != config ]] ;;
    reload) [[ ${TEST_FAIL:-} != reload ]] ;;
    status)
        [[ ${TEST_FAIL:-} != status ]] || exit 1
        if [[ ${TEST_READY_AFTER:-0} != 0 ]]; then
            count=$(cat "$TEST_DIR/status-count" 2>/dev/null || printf 0)
            count=$((count+1)); printf '%s' "$count" >"$TEST_DIR/status-count"
            (( count > TEST_READY_AFTER ))
        fi ;;
    set)
        [[ ${2:-} == sshd && ${3:-} == unbanip && -n ${4:-} && $# == 4 ]] || exit 90
        [[ ${TEST_FAIL:-} != unban ]] ;;
    get)
        [[ $2 == sshd ]] || exit 90
        case $3 in
            maxretry|findtime|bantime)
                [[ ${TEST_FAIL:-} != "$3" ]] || { printf '1\n'; exit; }
                sed -n "s/^$3 = //p" "$file" ;;
            actions) printf 'The jail sshd has the following actions:\niptables-multiport\n' ;;
            action)
                [[ $4 == iptables-multiport && $5 == port ]] || exit 90
                if [[ ${TEST_FAIL:-} == ports ]]; then printf '22\n'
                else sed -n 's/^port = //p' "$file"; fi ;;
            ignoreip)
                printf 'These IP addresses/networks are ignored:\n'
                if [[ ${TEST_FAIL:-} == ignores ]]; then printf '`- 127.0.0.0/8\n'
                else
                    value=$(sed -n 's/^ignoreip = //p' "$file")
                    for item in $value; do printf '|- %s\n' "$item"; done
                fi ;;
            *) exit 90 ;;
        esac ;;
    *) exit 90 ;;
esac
MOCK
cat >"${test_root}/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
[[ $* == 0.2 ]] || exit 90
MOCK
chmod +x "${test_root}/bin/"*
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cases=0
new_case() {
    cases=$((cases+1))
    export TEST_DIR="${test_root}/$1" CLASH_AGENT_FAIL2BAN_DIR="${test_root}/$1/fail2ban"
    unset TEST_FAIL TEST_PRIOR_IGNORES TEST_SOCKET_ACTIVE TEST_SOCKET_LISTEN TEST_SSHD_CONFIG TEST_READY_AFTER SSH_CLIENT
    export TEST_LISTENERS='LISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:(("sshd",pid=42,fd=3))'
    export SSH_CONNECTION='198.51.100.17 52300 203.0.113.7 2222'
    mkdir -p "$CLASH_AGENT_FAIL2BAN_DIR/jail.d"
    printf '[DEFAULT]\n# stock\n[sshd]\n' >"$CLASH_AGENT_FAIL2BAN_DIR/jail.conf"
    printf '[smtp]\nenabled = true\nignoreip = 192.0.2.90\n' >"$CLASH_AGENT_FAIL2BAN_DIR/jail.local"
    printf 0 >"$TEST_DIR/active"; printf 0 >"$TEST_DIR/enabled"; : >"$TEST_DIR/events"
}
expect_failure() { if "$@" >"$TEST_DIR/failure.log" 2>&1; then fail "Failure ignored: $*"; fi; }
managed_file() { printf '%s/jail.d/zz-clash-agent-sshd.local\n' "$CLASH_AGENT_FAIL2BAN_DIR"; }
assert_unrelated() { grep -qx 'ignoreip = 192.0.2.90' "$CLASH_AGENT_FAIL2BAN_DIR/jail.local" || fail 'Unrelated jail changed'; }

new_case fresh-no-ignoreip
clash_agent_configure_fail2ban
grep -qx 'port = 2222' "$(managed_file)"
grep -qx 'ignoreip = 127.0.0.1/8 ::1 198.51.100.17' "$(managed_file)"
! grep -q 'known/' "$(managed_file)"
grep -qx 'client set sshd unbanip 198.51.100.17' "$TEST_DIR/events"
clash_agent_verify_fail2ban
assert_unrelated

new_case existing-ignores-and-rerun
export TEST_PRIOR_IGNORES='192.0.2.0/24,admin.example 2001:db8::/32'
printf 1 >"$TEST_DIR/active"; printf 1 >"$TEST_DIR/enabled"
clash_agent_configure_fail2ban
grep -q '^ignoreip = 192.0.2.0/24 admin.example 2001:db8::/32 ' "$(managed_file)"
grep -qx 'client reload' "$TEST_DIR/events"
! grep -q '^systemctl start' "$TEST_DIR/events"
export SSH_CONNECTION='198.51.100.18 52300 203.0.113.7 2222'
clash_agent_configure_fail2ban
grep -q '198.51.100.17 198.51.100.18$' "$(managed_file)"
[[ $(grep -o '127.0.0.1/8' "$(managed_file)" | wc -l | tr -d ' ') == 1 ]]
assert_unrelated

new_case socket-activation
export TEST_LISTENERS='' TEST_SOCKET_ACTIVE=1 TEST_SOCKET_LISTEN='[::]:58172 (Stream)' SSH_CONNECTION='198.51.100.17 52300 203.0.113.7 58172'
clash_agent_configure_fail2ban
grep -qx 'port = 58172' "$(managed_file)"

new_case multichannel-ports
export TEST_LISTENERS=$'LISTEN 0 128 [::]:2222 [::]:* users:(("sshd",pid=42,fd=3))\nLISTEN 0 128 0.0.0.0:8022 0.0.0.0:* users:(("sshd",pid=42,fd=4))'
export SSH_CONNECTION='198.51.100.17 52300 203.0.113.7 8564'
[[ $(clash_agent_fail2ban_ssh_ports) == 2222,8022,8564 ]]

new_case legacy-session-ipv6
unset SSH_CONNECTION
export SSH_CLIENT='2001:db8::17 52300 2222'
clash_agent_configure_fail2ban
grep -q '2001:db8::17$' "$(managed_file)"
grep -qx 'client set sshd unbanip 2001:db8::17' "$TEST_DIR/events"

new_case console-fallback
unset SSH_CONNECTION
export TEST_LISTENERS='' TEST_SSHD_CONFIG=$'port 2200\nport 2201'
clash_agent_configure_fail2ban
grep -qx 'port = 2200,2201' "$(managed_file)"
grep -qx 'ignoreip = 127.0.0.1/8 ::1' "$(managed_file)"
! grep -q '^client set sshd unbanip' "$TEST_DIR/events"

new_case delayed-jail-readiness
export TEST_READY_AFTER=2
clash_agent_configure_fail2ban
[[ $(cat "$TEST_DIR/status-count") -ge 3 ]]

for failure in reader ss socket-show config start enable status maxretry findtime bantime ports ignores unban; do
    new_case "fail-$failure"
    export TEST_FAIL=$failure
    [[ $failure != socket-show ]] || export TEST_SOCKET_ACTIVE=1
    expect_failure clash_agent_configure_fail2ban
    [[ ! -e $(managed_file) ]] || fail "New drop-in left behind: $failure"
    assert_unrelated
done

new_case rollback-owned-config
clash_agent_configure_fail2ban >/dev/null
cp "$(managed_file)" "$TEST_DIR/previous.local"
export TEST_FAIL=config
expect_failure clash_agent_configure_fail2ban
cmp -s "$(managed_file)" "$TEST_DIR/previous.local"
[[ $(cat "$TEST_DIR/active") == 1 ]]
assert_unrelated

new_case reload-failure
clash_agent_configure_fail2ban >/dev/null
cp "$(managed_file)" "$TEST_DIR/previous.local"
export TEST_FAIL=reload
expect_failure clash_agent_configure_fail2ban
cmp -s "$(managed_file)" "$TEST_DIR/previous.local"
! grep -q '^systemctl stop' "$TEST_DIR/events"

new_case unknown-port
unset SSH_CONNECTION
export TEST_LISTENERS='' TEST_SSHD_CONFIG=''
expect_failure clash_agent_configure_fail2ban
[[ ! -e $(managed_file) ]]

new_case unknown-active-socket
export TEST_SOCKET_ACTIVE=1 TEST_SOCKET_LISTEN='not-a-listener'
expect_failure clash_agent_configure_fail2ban
[[ ! -e $(managed_file) ]]

new_case malformed-metadata
export SSH_CONNECTION=$'198.51.100.17 52300 203.0.113.7 2222\nenabled = false'
expect_failure clash_agent_configure_fail2ban
[[ ! -e $(managed_file) ]]

new_case unowned-drop-in
printf '[sshd]\nmaxretry = 1\n' >"$(managed_file)"
cp "$(managed_file)" "$TEST_DIR/previous.local"
expect_failure clash_agent_configure_fail2ban
cmp -s "$(managed_file)" "$TEST_DIR/previous.local"

new_case symlink-drop-in
printf 'unrelated\n' >"$TEST_DIR/protected"
ln -s "$TEST_DIR/protected" "$(managed_file)"
expect_failure clash_agent_configure_fail2ban
[[ $(cat "$TEST_DIR/protected") == unrelated ]]

# Optional real-package parser check (no daemon). Fail2ban's distro Python
# module is not installed on macOS, but CI/maintainers may supply its source.
if [[ -n ${CLASH_AGENT_TEST_FAIL2BAN_PYTHONPATH:-} ]]; then
    export PYTHONPATH="$CLASH_AGENT_TEST_FAIL2BAN_PYTHONPATH${PYTHONPATH:+:$PYTHONPATH}"
fi
if "$CLASH_AGENT_FAIL2BAN_PYTHON" -c 'import fail2ban.client.configreader' >/dev/null 2>&1; then
    new_case native-configreader
    [[ -z $(clash_agent_fail2ban_native_ignores) ]]
    printf '[DEFAULT]\nignoreip = 192.0.2.0/24\n[sshd]\n' >"$CLASH_AGENT_FAIL2BAN_DIR/jail.conf"
    [[ $(clash_agent_fail2ban_native_ignores) == 192.0.2.0/24 ]]
    printf '[sshd]\nignoreip = %%(known/ignoreip)s 2001:db8::/32\n' >"$CLASH_AGENT_FAIL2BAN_DIR/jail.local"
    [[ $(clash_agent_fail2ban_native_ignores) == '192.0.2.0/24 2001:db8::/32' ]]
    printf 'PASS: real Fail2ban ConfigReader (fresh, inherited, extended whitelist).\n'
fi
printf 'PASS: %s isolated Fail2ban scenarios; no SSH, firewall, Fail2ban daemon or host configuration changes.\n' "$cases"
