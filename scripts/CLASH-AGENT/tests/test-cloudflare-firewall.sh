#!/usr/bin/env bash
set -euo pipefail
test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$test_dir/../install.sh"
work=$(mktemp -d /tmp/clash-agent-cf-firewall.XXXXXX)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state" "$work/units"
export CA_STATE_DIR="$work/state" CA_UNIT_DIR="$work/units" CA_CF_ALLOW="$work/state/allow.conf"
export IPTABLES_FIXTURE="$work/iptables.json"
printf '{"INPUT":[["-p","tcp","--dport","22","-j","ACCEPT"]]}' >"$IPTABLES_FIXTURE"
cat >"$work/bin/iptables" <<'PY'
#!/usr/bin/env python3
import json, os, sys
p=os.environ['IPTABLES_FIXTURE']; d=json.load(open(p)); a=sys.argv[1:]
assert a[:2]==['-w','5']; a=a[2:]; op,chain=a[:2]; rule=a[2:]
if op=='-N':
 if chain in d: sys.exit(1)
 d[chain]=[]
elif op=='-A': d[chain].append(rule)
elif op=='-I':
 if os.environ.get('FAIL_INSERT')=='1': sys.exit(1)
 assert rule.pop(0)=='1'; d[chain].insert(0,rule)
elif op=='-C': sys.exit(0 if chain in d and rule in d[chain] else 1)
elif op=='-D':
 if chain not in d or rule not in d[chain]: sys.exit(1)
 d[chain].remove(rule)
elif op=='-F':
 assert chain.startswith('CACF_'); d[chain]=[]
elif op=='-X':
 assert chain.startswith('CACF_'); d.pop(chain,None)
else: raise AssertionError(op)
json.dump(d,open(p,'w'))
PY
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/flock"
printf '#!/usr/bin/env bash\n[[ $1 == -t ]]\n' >"$work/bin/nginx"
cat >"$work/bin/systemctl" <<'SH'
#!/usr/bin/env bash
case $1 in is-active) exit 1 ;; *) exit 0 ;; esac
SH
chmod 755 "$work/bin/"*
export PATH="$work/bin:$PATH"
clash_agent_cf_firewall_fetch() { printf '173.245.48.0/20\n103.21.244.0/22\n'; }
clash_agent_cf_firewall_prepare
clash_agent_cf_firewall_refresh
python3 - "$IPTABLES_FIXTURE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); rules=d['INPUT']; jump=rules[0]
assert jump[:5]==['-p','tcp','--dport','443','-j']
assert rules[1]==['-p','tcp','--dport','22','-j','ACCEPT']
chain=d[jump[-1]]
assert ['-s','173.245.48.0/20','-j','ACCEPT'] in chain and chain[-1]==['-j','DROP']
PY
cp "$IPTABLES_FIXTURE" "$work/before"
cp "$CA_CF_ALLOW" "$work/allow-before"
export FAIL_INSERT=1
if clash_agent_cf_firewall_refresh; then printf 'FAIL: firewall insertion failure was ignored\n' >&2; exit 1; fi
cmp "$work/before" "$IPTABLES_FIXTURE"
cmp "$work/allow-before" "$CA_CF_ALLOW"
unset FAIL_INSERT
openssl() {
    if [[ "$*" == 'rand -hex 4' ]]; then sed 's/^CACF_//' "${CA_STATE_DIR}/firewall-chain";
    else command openssl "$@"; fi
}
if clash_agent_cf_firewall_refresh; then printf 'FAIL: existing chain collision was ignored\n' >&2; exit 1; fi
cmp "$work/before" "$IPTABLES_FIXTURE"
unset -f openssl
clash_agent_cf_firewall_fetch() { printf '0.0.0.0/0\n'; }
if clash_agent_cf_firewall_refresh; then printf 'FAIL: unsafe allowlist was accepted\n' >&2; exit 1; fi
cmp "$work/before" "$IPTABLES_FIXTURE"
printf 'PASS: Cloudflare-only origin, SSH preservation, firewall rollback and range validation.\n'
