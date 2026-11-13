#!/usr/bin/env bash
set -euo pipefail
test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$test_dir/../install.sh"
work=$(mktemp -d /tmp/clash-agent-cf-cert.XXXXXX)
trap 'rm -rf "$work"' EXIT
export CA_STATE_DIR="$work/state" CA_UNIT_DIR="$work/units" CA_CF_DOMAIN=node.example.com
export CA_CF_ACME_HOME="$CA_STATE_DIR/acme" CA_CF_CERT="$CA_STATE_DIR/tls/node.crt" CA_CF_KEY="$CA_STATE_DIR/tls/node.key"
export CA_CF_TOKEN=fixture_token_12345678901234567890 CA_CF_ZONE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa CA_CF_ACCOUNT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
mkdir -p "$CA_CF_ACME_HOME/$CA_CF_DOMAIN"_ecc "$CA_UNIT_DIR" "$work/bin"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$CA_CF_ACME_HOME/${CA_CF_DOMAIN}_ecc/$CA_CF_DOMAIN.key" -out "$CA_CF_ACME_HOME/${CA_CF_DOMAIN}_ecc/fullchain.cer" -days 30 -subj /CN=node.example.com -addext subjectAltName=DNS:node.example.com >/dev/null 2>&1
cat >"$CA_CF_ACME_HOME/acme.sh" <<'SH'
#!/usr/bin/env bash
args=("$@")
for option in --home --config-home --cert-home; do
 found=false
 for ((i=0;i<${#args[@]}-1;i++)); do
  if [[ ${args[i]} == "$option" && ${args[i+1]} == "$CA_CF_ACME_HOME" ]]; then found=true; fi
 done
 [[ $found == true ]] || exit 93
done
if [[ $1 == --issue ]]; then
 [[ -z ${CF_Token:-} && -n ${CLASH_CF_INSTALLER:-} && -n ${CLASH_CF_STATE_DIR:-} ]] || exit 91
 [[ " $* " == *' --dns dns_clash_agent_cf '* ]] || exit 94
 exit "${ACME_RESULT:-0}"
fi
[[ $1 == --install-cert ]] || exit 92
printf '%s\n' "$@" >"$CA_STATE_DIR/hook-arguments"
SH
chmod 700 "$CA_CF_ACME_HOME/acme.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/systemctl"; chmod 755 "$work/bin/systemctl"
export PATH="$work/bin:$PATH"
clash_agent_cf_certificate
cmp "$CA_CF_CERT" "$CA_CF_ACME_HOME/${CA_CF_DOMAIN}_ecc/fullchain.cer"
ACME_RESULT=2 clash_agent_cf_certificate
if ACME_RESULT=1 clash_agent_cf_certificate; then printf 'FAIL: issuance error hidden by an old certificate\n' >&2; exit 1; fi
clash_agent_cf_finish_certificate
python3 - "$CA_UNIT_DIR" "$CA_STATE_DIR/hook-arguments" <<'PY'
import configparser,pathlib,sys
root=pathlib.Path(sys.argv[1]); timer=configparser.ConfigParser(); timer.read(root/'clash-agent-cf-renew.timer')
assert timer['Timer']['Persistent']=='true'
unit=configparser.ConfigParser(); unit.read(root/'clash-agent-cf-renew.service')
assert '--cron --home ' in unit['Service']['ExecStart']
args=pathlib.Path(sys.argv[2]).read_text().splitlines()
assert args[args.index('--reloadcmd')+1]=='nginx -t && systemctl reload nginx.service'
PY
printf 'PASS: DNS-01 exit handling, certificate installation and independent renewal timer/hook.\n'

if [[ -n ${ACME_REFERENCE_SCRIPT:-} ]]; then
    # Genuine pinned acme.sh path initialization and install-cert. A future
    # renewal timestamp makes --issue skip locally, without any CA/API call.
    cp "$ACME_REFERENCE_SCRIPT" "$CA_CF_ACME_HOME/acme.sh"
    chmod 700 "$CA_CF_ACME_HOME/acme.sh"
    mkdir -p "$work/home/.acme.sh/${CA_CF_DOMAIN}_ecc"
    for home in "$CA_CF_ACME_HOME" "$work/home/.acme.sh"; do
        marker=PRIVATE-HOME; [[ $home != "$work/home/.acme.sh" ]] || marker=DEFAULT-HOME
        cat >"$home/${CA_CF_DOMAIN}_ecc/$CA_CF_DOMAIN.conf" <<EOF
Le_Domain='$CA_CF_DOMAIN'
Le_Alt='no'
Le_Keylength='ec-256'
Le_NextRenewTime='9999999999'
Le_NextRenewTimeStr='$marker'
EOF
    done
    cp "$CA_CF_ACME_HOME/${CA_CF_DOMAIN}_ecc/fullchain.cer" "$work/home/.acme.sh/${CA_CF_DOMAIN}_ecc/fullchain.cer"
    cp "$CA_CF_ACME_HOME/${CA_CF_DOMAIN}_ecc/$CA_CF_DOMAIN.key" "$work/home/.acme.sh/${CA_CF_DOMAIN}_ecc/$CA_CF_DOMAIN.key"
    cp "$work/home/.acme.sh/${CA_CF_DOMAIN}_ecc/$CA_CF_DOMAIN.conf" "$work/default-before"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/nginx"; chmod 755 "$work/bin/nginx"
    (
        export HOME="$work/home"
        unset LE_WORKING_DIR LE_CONFIG_HOME CERT_HOME ACCOUNT_CONF_PATH
        clash_agent_cf_certificate
        grep -q PRIVATE-HOME "$CA_STATE_DIR/acme-issue.log"
        clash_agent_cf_finish_certificate
    )
    cmp "$work/default-before" "$work/home/.acme.sh/${CA_CF_DOMAIN}_ecc/$CA_CF_DOMAIN.conf"
    printf 'PASS: genuine pinned acme.sh keeps issue/install-cert inside the private home.\n'
else
    printf 'SKIP: pinned acme.sh reference (set ACME_REFERENCE_SCRIPT to the official 3.1.2 script).\n'
fi
