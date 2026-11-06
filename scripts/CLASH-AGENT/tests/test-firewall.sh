#!/usr/bin/env bash
# Exercise the real upstream allowPort and CLASH-AGENT verifier with command
# functions only. No real firewall manager, sudo or system service is invoked.
set -euo pipefail
test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
test_root=$(mktemp -d /tmp/clash-agent-firewall-tests.XXXXXX)
trap 'rm -rf -- "$test_root"' EXIT
source "${test_dir}/../install.sh"
echoType='echo -e'
printN=''

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
record() { printf '%s\n' "$*" >>"$case_dir/events"; }
new_case() {
    case_dir="${test_root}/$1"
    mkdir -p "$case_dir"
    : >"$case_dir/events"
    firewall=none
    ufw_has_rule=false
    ufw_add_rule=false
    permanent_rule=false
    runtime_rule=false
    iptables_insert_fails=false
    save_fails=false
}

dpkg() {
    [[ $# == 1 && $1 == -l ]] || { record unexpected-dpkg; return 90; }
    case $firewall in
        ufw) printf 'ii  ufw  0.36  all  fixture\n' ;;
        iptables) printf 'ii  netfilter-persistent  1.0  all  fixture\n' ;;
        *) return 0 ;;
    esac
}
ufw() {
    record "ufw $*"
    if [[ ${1:-} == status ]]; then
        if [[ $firewall == ufw ]]; then
            printf 'Status: active\n'
            if [[ $ufw_has_rule == true || -e $case_dir/ufw-rule ]]; then printf '23456/tcp                  ALLOW       Anywhere\n'; fi
        else
            printf 'Status: inactive\n'
        fi
    elif [[ $# == 2 && $1 == allow && $2 == 23456/tcp ]]; then
        [[ $ufw_add_rule != true ]] || : >"$case_dir/ufw-rule"
    else
        record unexpected-ufw
        return 90
    fi
}
sudo() {
    record "sudo $*"
    [[ $# == 3 && $1 == ufw && $2 == allow && $3 == 23456/tcp ]] || return 90
    ufw allow "$3"
}
systemctl() {
    record "systemctl $*"
    if [[ ${1:-} == status && ${2:-} == firewalld ]]; then
        [[ $firewall == firewalld ]] || return 1
        printf 'Active: active (running)\n'
    elif [[ ${1:-} == status && ${2:-} == netfilter-persistent ]]; then
        [[ $firewall == iptables ]] || return 1
        printf 'Active: active (exited)\n'
    elif [[ ${1:-} == is-active ]]; then
        [[ $firewall == show || ($firewall == firewalld && ${*: -1} == firewalld) ]]
    else
        record unexpected-systemctl
        return 90
    fi
}
rc-update() { record "rc-update $*"; return 1; }
firewall-cmd() {
    record "firewall-cmd $*"
    case "$*" in
        '--list-ports --permanent')
            [[ $permanent_rule != true ]] || printf '23456/tcp\n'
            ;;
        '--zone=public --add-port=23456/tcp --permanent')
            [[ $permanent_rule == true ]]
            ;;
        '--zone=public --query-port=23456/tcp') [[ $runtime_rule == true ]] ;;
        --reload) return 0 ;;
        *) record unexpected-firewalld; return 90 ;;
    esac
}
iptables() {
    record "iptables $*"
    if [[ $# == 1 && $1 == -L ]]; then
        [[ ! -e $case_dir/iptables-rule ]] || printf 'ACCEPT tcp -- anywhere anywhere /* allow 23456/tcp(mack-a) */\n'
    elif [[ $* == '-I INPUT -p tcp --dport 23456 -m comment --comment allow 23456/tcp(mack-a) -j ACCEPT' ]]; then
        [[ $iptables_insert_fails != true ]] || return 1
        : >"$case_dir/iptables-rule"
    else
        record unexpected-iptables
        return 90
    fi
}
netfilter-persistent() {
    record "netfilter-persistent $*"
    [[ $# == 1 && $1 == save && $save_fails != true ]]
}

expect_failure() {
    if clash_agent_open_port 23456 >"$case_dir/output" 2>"$case_dir/errors"; then fail "$1"; fi
    if grep -q '^unexpected-' "$case_dir/events"; then fail 'unexpected host command'; fi
}
expect_success() {
    if ! clash_agent_open_port 23456 >"$case_dir/output" 2>"$case_dir/errors"; then
        cat "$case_dir/errors" >&2
        fail "$1"
    fi
    if grep -q '^unexpected-' "$case_dir/events"; then fail 'unexpected host command'; fi
}

new_case ufw-legacy-exit
firewall=ufw
# Upstream checkUFWAllowPort calls exit 0 when its rule did not appear. The
# wrapper must contain that exit and still reject the missing active rule.
(
    expect_failure 'UFW missing rule was accepted after upstream exit 0'
    printf 'survived\n' >"$case_dir/returned"
)
[[ -e $case_dir/returned ]] || fail 'upstream exit escaped the firewall wrapper'
grep -q '端口开放失败' "$case_dir/output" || fail 'legacy UFW failure path was not exercised'
grep -q '^sudo ufw allow 23456/tcp$' "$case_dir/events"

new_case ufw-valid-existing
firewall=ufw
ufw_has_rule=true
expect_success 'valid UFW rule rejected'
if grep -q '^sudo ' "$case_dir/events"; then fail 'existing UFW rule was rewritten'; fi

new_case ufw-new-rule
firewall=ufw
ufw_add_rule=true
expect_success 'new UFW rule rejected'
[[ -e $case_dir/ufw-rule ]] || fail 'mock UFW rule was not added'

new_case iptables-insert-failure
firewall=iptables
iptables_insert_fails=true
expect_failure 'iptables insertion failure was ignored'
grep -q '^iptables -I ' "$case_dir/events"
if grep -q '^netfilter-persistent save$' "$case_dir/events"; then fail 'failed insertion was persisted'; fi

new_case iptables-save-failure
firewall=iptables
save_fails=true
expect_failure 'netfilter persistence failure was ignored'
[[ -e $case_dir/iptables-rule ]] || fail 'save failure did not follow insertion'
grep -q '^netfilter-persistent save$' "$case_dir/events"

new_case iptables-new-rule
firewall=iptables
expect_success 'inserted and persisted iptables rule rejected'
grep -q '^iptables -I ' "$case_dir/events"
grep -q '^netfilter-persistent save$' "$case_dir/events"
expect_success 'existing iptables rule rejected'
[[ $(grep -c '^iptables -I ' "$case_dir/events") == 1 ]] || fail 'existing iptables rule inserted twice'

new_case firewalld-missing-runtime-rule
firewall=firewalld
permanent_rule=true
expect_failure 'firewalld permanent-only rule was accepted without a runtime rule'
grep -q '^firewall-cmd --zone=public --query-port=23456/tcp$' "$case_dir/events"

new_case firewalld-valid-rule
firewall=firewalld
permanent_rule=true
runtime_rule=true
expect_success 'valid active firewalld rule rejected'

# Saved installing state must not print a configured summary even when every
# service/system check would succeed. All checks remain local fixture functions.
new_case incomplete-show
firewall=show
export CLASH_AGENT_STATE_DIR="$case_dir/state"
export CLASH_AGENT_CORE_DIR="$case_dir/core"
export CLASH_AGENT_PROFILE_DIR="$case_dir/profiles"
export CLASH_AGENT_UNIT_DIR="$case_dir/units"
export CLASH_AGENT_LOCK_FILE="$case_dir/lock"
clash_agent_paths
mkdir "$CA_STATE_DIR"
CA_SERVER=203.0.113.7
CA_SNI=www.example.com
CA_UUID=123e4567-e89b-42d3-a456-426614174000
CA_PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
CA_PUBLIC_KEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
CA_SHORT_ID=0123456789abcdef
CA_TOKEN=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
CA_NODE_NAME=CLASH-AGENT-test
CA_REALITY_PORT=23456
CA_SUB_PORT=34567
clash_agent_write_state installing
clash_agent_check_subscription() { record check-subscription; return 0; }
clash_agent_verify_system() { record verify-system; return 0; }
if clash_agent_main show >"$case_dir/show-output" 2>"$case_dir/show-errors"; then fail 'show accepted incomplete state'; fi
[[ ! -s $case_dir/show-output ]] || fail 'show emitted a result for incomplete state'
[[ ! -s $case_dir/events ]] || fail 'incomplete state reached service checks'

printf 'PASS: real firewall wrapper, legacy exit containment, UFW/firewalld rules, iptables/save failures and incomplete-state show.\n'
