#!/usr/bin/env bash
set -euo pipefail

module_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)
# shellcheck source=../lib/system-defaults.sh
source "${module_dir}/system-defaults.sh"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/clash-agent-system-tests.XXXXXX")
trap 'rm -rf "${test_root}"' EXIT
mkdir -p "${test_root}/bin"
export PATH="${test_root}/bin:${PATH}"

cat >"${test_root}/bin/sysctl" <<'MOCK'
#!/usr/bin/env bash
set -eu
key=${2%%=*}
case "$key" in
    net.ipv4.tcp_available_congestion_control) printf '%s\n' "${TEST_AVAILABLE_CC:-reno cubic bbr}"; exit ;;
    net.ipv4.tcp_congestion_control) file="$TEST_DIR/cc" ;;
    net.core.default_qdisc) file="$TEST_DIR/qdisc" ;;
    *) exit 40 ;;
esac
if [[ $1 == -n ]]; then cat "$file"; exit; fi
if [[ ${TEST_SYSCTL_REJECT:-} == bbr && $2 == net.ipv4.tcp_congestion_control=bbr ]]; then exit 1; fi
printf '%s\n' "${2#*=}" >"$file"
MOCK
cat >"${test_root}/bin/modprobe" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
cat >"${test_root}/bin/dd" <<'MOCK'
#!/usr/bin/env bash
set -eu
echo dd >>"$TEST_DIR/commands"
[[ ${TEST_DD_FAIL:-0} == 0 ]] || exit 1
for arg do case "$arg" in of=*) file=${arg#of=} ;; esac; done
python3 - "$file" <<'PY'
import sys
with open(sys.argv[1], 'wb') as f:
    f.truncate(1073741824)
PY
MOCK
cat >"${test_root}/bin/mkswap" <<'MOCK'
#!/usr/bin/env bash
echo mkswap >>"$TEST_DIR/commands"
MOCK
cat >"${test_root}/bin/swapon" <<'MOCK'
#!/usr/bin/env bash
set -eu
echo swapon >>"$TEST_DIR/commands"
[[ ${TEST_SWAPON_FAIL:-0} == 0 ]] || exit 1
printf '%s file 1048572 0 -2\n' "$1" >>"$CLASH_AGENT_PROC_SWAPS"
if [[ ${TEST_FSTAB_BLOCK:-0} == 1 ]]; then
    mv "$CLASH_AGENT_ETC_DIR/fstab" "$TEST_DIR/fstab-backup"
    mkdir "$CLASH_AGENT_ETC_DIR/fstab"
fi
MOCK
cat >"${test_root}/bin/swapoff" <<'MOCK'
#!/usr/bin/env bash
echo 'ERROR: swapoff must never be invoked' >&2
exit 80
MOCK
cat >"${test_root}/bin/blkid" <<'MOCK'
#!/usr/bin/env bash
if [[ ${TEST_EXISTING_SWAP:-0} == 1 ]] || grep -q '^mkswap$' "$TEST_DIR/commands"; then
    printf 'swap\n'
fi
MOCK
chmod +x "${test_root}/bin/"*

new_case() {
    export TEST_DIR="${test_root}/$1"
    export CLASH_AGENT_ETC_DIR="${TEST_DIR}/etc"
    export CLASH_AGENT_SWAP_FILE="${TEST_DIR}/swapfile"
    export CLASH_AGENT_PROC_SWAPS="${TEST_DIR}/proc-swaps"
    unset TEST_AVAILABLE_CC TEST_SYSCTL_REJECT TEST_DD_FAIL TEST_SWAPON_FAIL TEST_EXISTING_SWAP TEST_FSTAB_BLOCK
    mkdir -p "${CLASH_AGENT_ETC_DIR}"
    printf 'cubic\n' >"${TEST_DIR}/cc"
    printf 'fq_codel\n' >"${TEST_DIR}/qdisc"
    printf 'Filename Type Size Used Priority\n' >"${CLASH_AGENT_PROC_SWAPS}"
    printf '# original fstab\n' >"${CLASH_AGENT_ETC_DIR}/fstab"
    : >"${TEST_DIR}/commands"
}

expect_failure() {
    if "$@" >"${TEST_DIR}/failure.log" 2>&1; then
        printf 'Expected failure: %s\n' "$*" >&2
        exit 1
    fi
}

new_case bbr
clash_agent_enable_bbr
[[ $(cat "${TEST_DIR}/cc") == bbr && $(cat "${TEST_DIR}/qdisc") == fq ]]
grep -q '^net.ipv4.tcp_congestion_control = bbr$' "${CLASH_AGENT_ETC_DIR}/sysctl.d/99-clash-agent.conf"
clash_agent_enable_bbr
[[ $(grep -c '^net.ipv4.tcp_congestion_control' "${CLASH_AGENT_ETC_DIR}/sysctl.d/99-clash-agent.conf") == 1 ]]

new_case unsupported-kernel
export TEST_AVAILABLE_CC='reno cubic'
expect_failure clash_agent_enable_bbr
[[ ! -e "${CLASH_AGENT_ETC_DIR}/sysctl.d/99-clash-agent.conf" ]]
[[ $(cat "${TEST_DIR}/cc") == cubic ]]

new_case failed-sysctl
export TEST_SYSCTL_REJECT=bbr
expect_failure clash_agent_enable_bbr
[[ $(cat "${TEST_DIR}/cc") == cubic && $(cat "${TEST_DIR}/qdisc") == fq_codel ]]
[[ ! -e "${CLASH_AGENT_ETC_DIR}/sysctl.d/99-clash-agent.conf" ]]

new_case sufficient-swap
printf '/dev/existing partition 2097152 0 -2\n' >>"${CLASH_AGENT_PROC_SWAPS}"
clash_agent_ensure_swap
[[ ! -e "${CLASH_AGENT_SWAP_FILE}" && ! -s "${TEST_DIR}/commands" ]]
[[ $(cat "${CLASH_AGENT_ETC_DIR}/fstab") == '# original fstab' ]]

new_case fresh-swap
clash_agent_ensure_swap
python3 - "${CLASH_AGENT_SWAP_FILE}" <<'PY'
from pathlib import Path
import stat, sys
p = Path(sys.argv[1])
assert p.stat().st_size == 1073741824
assert stat.S_IMODE(p.stat().st_mode) == 0o600
PY
[[ $(grep -c 'CLASH-AGENT$' "${CLASH_AGENT_ETC_DIR}/fstab") == 1 ]]
clash_agent_ensure_swap
[[ $(grep -c '^dd$' "${TEST_DIR}/commands") == 1 ]]
[[ $(grep -c 'CLASH-AGENT$' "${CLASH_AGENT_ETC_DIR}/fstab") == 1 ]]

new_case smaller-existing-swap
printf '/dev/small partition 524288 0 -2\n' >>"${CLASH_AGENT_PROC_SWAPS}"
clash_agent_ensure_swap
grep -q '^/dev/small partition 524288 ' "${CLASH_AGENT_PROC_SWAPS}"
[[ $(clash_agent_active_swap_kib) == 1572860 ]]

new_case occupied-path
printf 'keep my data\n' >"${CLASH_AGENT_SWAP_FILE}"
expect_failure clash_agent_ensure_swap
[[ $(cat "${CLASH_AGENT_SWAP_FILE}") == 'keep my data' && ! -s "${TEST_DIR}/commands" ]]

new_case valid-inactive-file
python3 - "${CLASH_AGENT_SWAP_FILE}" <<'PY'
import sys
with open(sys.argv[1], 'wb') as f:
    f.truncate(1073741824)
PY
export TEST_EXISTING_SWAP=1
clash_agent_ensure_swap
[[ $(cat "${TEST_DIR}/commands") == swapon ]]

new_case rejected-swapon
export TEST_SWAPON_FAIL=1
expect_failure clash_agent_ensure_swap
[[ ! -e "${CLASH_AGENT_SWAP_FILE}" ]]
[[ $(cat "${CLASH_AGENT_ETC_DIR}/fstab") == '# original fstab' ]]

new_case failed-allocation
export TEST_DD_FAIL=1
expect_failure clash_agent_ensure_swap
[[ ! -e "${CLASH_AGENT_SWAP_FILE}" ]]
[[ $(cat "${TEST_DIR}/commands") == dd ]]

new_case conflicting-fstab
printf '%s none swap noauto 0 0\n' "${CLASH_AGENT_SWAP_FILE}" >>"${CLASH_AGENT_ETC_DIR}/fstab"
expect_failure clash_agent_ensure_swap
[[ ! -e "${CLASH_AGENT_SWAP_FILE}" && ! -s "${TEST_DIR}/commands" ]]

new_case missing-kernel-interface
rm "${CLASH_AGENT_PROC_SWAPS}"
expect_failure clash_agent_ensure_swap
[[ ! -e "${CLASH_AGENT_SWAP_FILE}" ]]

new_case invalid-path
export CLASH_AGENT_SWAP_FILE="${TEST_DIR}/not safe"
expect_failure clash_agent_ensure_swap
[[ ! -e "${CLASH_AGENT_SWAP_FILE}" ]]

new_case fstab-without-final-newline
printf '# original without newline' >"${CLASH_AGENT_ETC_DIR}/fstab"
clash_agent_ensure_swap
grep -q '^# original without newline$' "${CLASH_AGENT_ETC_DIR}/fstab"
grep -q "^${CLASH_AGENT_SWAP_FILE} none swap sw 0 0 # CLASH-AGENT$" "${CLASH_AGENT_ETC_DIR}/fstab"

new_case retry-failed-persistence
export TEST_FSTAB_BLOCK=1
expect_failure clash_agent_ensure_swap
[[ $(clash_agent_active_swap_kib) == 1048572 ]]
rmdir "${CLASH_AGENT_ETC_DIR}/fstab"
mv "${TEST_DIR}/fstab-backup" "${CLASH_AGENT_ETC_DIR}/fstab"
unset TEST_FSTAB_BLOCK
clash_agent_ensure_swap
[[ $(grep -c '^swapon$' "${TEST_DIR}/commands") == 1 ]]
[[ $(grep -c 'CLASH-AGENT$' "${CLASH_AGENT_ETC_DIR}/fstab") == 1 ]]

printf 'PASS: 15 isolated system-default scenarios; no host sysctl, swap or fstab changes.\n'
