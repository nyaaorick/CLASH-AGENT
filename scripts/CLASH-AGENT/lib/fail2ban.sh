#!/usr/bin/env bash
# SSH hardening only: no SSH daemon or general firewall policy is changed.

clash_agent_fail2ban_error() { printf 'CLASH-AGENT: %s\n' "$*" >&2; return 1; }
clash_agent_fail2ban_dir() { printf '%s\n' "${CLASH_AGENT_FAIL2BAN_DIR:-${CLASH_AGENT_ETC_DIR:-/etc}/fail2ban}"; }
clash_agent_fail2ban_client() { fail2ban-client -c "$(clash_agent_fail2ban_dir)" "$@"; }
clash_agent_fail2ban_python() { "${CLASH_AGENT_FAIL2BAN_PYTHON:-/usr/bin/python3}" "$@"; }

clash_agent_fail2ban_ssh_context() {
    clash_agent_fail2ban_python - "${SSH_CONNECTION:-}" "${SSH_CLIENT:-}" <<'PY'
import ipaddress, json, sys
connection, legacy = sys.argv[1:]
client = ''; server_port = None
if connection or legacy:
    parts = (connection or legacy).split()
    if len(parts) != (4 if connection else 3):
        raise SystemExit('CLASH-AGENT: Invalid SSH connection metadata.')
    try:
        client = str(ipaddress.ip_address(parts[0]))
        if '%' in client:
            raise ValueError('scoped client address')
        if connection:
            ipaddress.ip_address(parts[2])
        for port in (parts[1], parts[-1]):
            if not port.isdecimal() or not 1 <= int(port) <= 65535:
                raise ValueError('invalid port')
        server_port = int(parts[-1])
    except ValueError as error:
        raise SystemExit('CLASH-AGENT: Invalid SSH connection metadata: ' + str(error))
print(json.dumps({'client':client, 'server_port':server_port}))
PY
}

clash_agent_fail2ban_ssh_ports() {
    local sshd_binary=${CLASH_AGENT_SSHD_BINARY:-} config listeners socket_list= active_socket=false unit value context
    context=$(clash_agent_fail2ban_ssh_context) || return 1
    if [[ -z $sshd_binary ]]; then sshd_binary=$(command -v sshd || true); fi
    if [[ -z $sshd_binary && -x /usr/sbin/sshd ]]; then sshd_binary=/usr/sbin/sshd; fi
    [[ -n $sshd_binary ]] || { clash_agent_fail2ban_error 'Cannot locate sshd to discover SSH ports.'; return 1; }
    config=$("$sshd_binary" -T 2>/dev/null) || config=
    listeners=$(ss -H -ltnp) || return 1
    for unit in ssh.socket sshd.socket; do
        if systemctl is-active --quiet "$unit"; then
            active_socket=true
            value=$(systemctl show "$unit" --property=Listen --value) || return 1
            socket_list+="$value"$'\n'
        fi
    done
    clash_agent_fail2ban_python - "$config" "$listeners" "$socket_list" "$active_socket" "$context" <<'PY'
import json, re, sys
config, listeners, sockets, socket_active, context = sys.argv[1:]
ports = set()
def add(value):
    if not value.isdecimal() or not 1 <= int(value) <= 65535:
        raise SystemExit('CLASH-AGENT: Invalid detected SSH port.')
    ports.add(int(value))
for line in listeners.splitlines():
    if re.search(r'\("sshd(?:-session)?"', line):
        fields = line.split()
        if len(fields) < 4 or not re.search(r':(\d+)$', fields[3]):
            raise SystemExit('CLASH-AGENT: Cannot parse the SSH listening port.')
        add(re.search(r':(\d+)$', fields[3]).group(1))
socket_ports = re.findall(r'(?:^|\s)(?:\[[^\]]+\]:|[^\s:]+:|\*:)?(\d+)\s+\(Stream\)', sockets)
if socket_active == 'true' and not socket_ports:
    raise SystemExit('CLASH-AGENT: Cannot determine active SSH socket ports.')
for port in socket_ports:
    add(port)
if not ports:
    for port in re.findall(r'^port\s+(\d+)\s*$', config, re.M):
        add(port)
session_port = json.loads(context)['server_port']
if session_port:
    add(str(session_port))
if not ports:
    raise SystemExit('CLASH-AGENT: No SSH port could be discovered; refusing to guess port 22.')
print(','.join(map(str, sorted(ports))))
PY
}

clash_agent_fail2ban_existing_ignores() {
    # Use Fail2ban's parser, including its include/interpolation/precedence rules.
    # Stock ignoreip may be undefined, so unconditional %(known/ignoreip)s is unsafe.
    clash_agent_fail2ban_python - "$(clash_agent_fail2ban_dir)" <<'PY'
import sys
from fail2ban.client.configreader import ConfigReader, NoOptionError, NoSectionError
reader = ConfigReader()
reader.setBaseDir(sys.argv[1])
if not reader.read('jail'):
    raise SystemExit('CLASH-AGENT: Cannot read the existing Fail2ban configuration.')
# ConfigReader.get is available in 0.10 as well as newer releases; has_option
# is absent from older adapters. Only a missing option/section means no whitelist.
try:
    print(reader.get('sshd', 'ignoreip'))
except (NoOptionError, NoSectionError):
    print('')
PY
}

clash_agent_fail2ban_ignore_list() {
    local existing context
    existing=$(clash_agent_fail2ban_existing_ignores) || return 1
    context=$(clash_agent_fail2ban_ssh_context) || return 1
    clash_agent_fail2ban_python - "$existing" "$context" <<'PY'
import json, re, sys
tokens = [value for value in re.split(r'[\s,]+', sys.argv[1]) if value] + ['127.0.0.1/8', '::1']
client = json.loads(sys.argv[2])['client']
if client:
    tokens.append(client)
result = []
for token in tokens:
    if not re.fullmatch(r'[A-Za-z0-9_.:/%-]+', token):
        raise SystemExit('CLASH-AGENT: Existing ignoreip contains an unsupported token; it was preserved unchanged.')
    if token not in result:
        result.append(token)
print(' '.join(result))
PY
}

clash_agent_fail2ban_wait() {
    local attempt
    for ((attempt=0; attempt<20; attempt++)); do
        if clash_agent_fail2ban_client status sshd >/dev/null 2>&1; then return 0; fi
        sleep 0.2
    done
    clash_agent_fail2ban_error 'The Fail2ban SSH jail did not become ready.'
}

clash_agent_fail2ban_unban_client() {
    local client=$1 output
    if output=$(clash_agent_fail2ban_client set sshd unbanip "$client" 2>&1); then
        [[ -z $output ]] || printf '%s\n' "$output"
        return 0
    fi
    # Fail2ban 0.10 reports a missing ban as an error. Accept only its exact
    # current-client response; socket, jail, action and other errors still fail.
    if clash_agent_fail2ban_python - "$client" "$output" <<'PY'
import sys
message = sys.argv[1] + ' is not banned'
expected = [message, 'NOK: ' + repr((message,))]
actual = [line.strip() for line in sys.argv[2].splitlines()]
raise SystemExit(0 if sorted(actual) == sorted(expected) else 1)
PY
    then return 0; fi
    [[ -z $output ]] || printf '%s\n' "$output" >&2
    return 1
}

clash_agent_verify_fail2ban() {
    local dir file ports actions action action_ports matched=false ignores expected_ignores key value
    dir=$(clash_agent_fail2ban_dir); file="${dir}/jail.d/zz-clash-agent-sshd.local"
    [[ -f $file && ! -L $file ]] || return 1
    systemctl is-active --quiet fail2ban.service && systemctl is-enabled --quiet fail2ban.service || return 1
    clash_agent_fail2ban_client status sshd >/dev/null || return 1
    for key in maxretry findtime bantime; do
        value=$(clash_agent_fail2ban_client get sshd "$key") || return 1
        case "$key:$value" in maxretry:5|findtime:600|bantime:3600) ;; *) return 1 ;; esac
    done
    ports=$(clash_agent_fail2ban_ssh_ports) || return 1
    actions=$(clash_agent_fail2ban_client get sshd actions) || return 1
    while IFS= read -r action; do
        [[ $action =~ ^[A-Za-z0-9_.:-]+$ ]] || continue
        action_ports=$(clash_agent_fail2ban_client get sshd action "$action" port 2>/dev/null) || continue
        if clash_agent_fail2ban_python - "$ports" "$action_ports" <<'PY'
import re, sys
expected = set(sys.argv[1].split(','))
actual = sys.argv[2].strip()
if not re.fullmatch(r'[0-9,\s]+', actual):
    raise SystemExit(1)
raise SystemExit(0 if expected <= set(re.split(r'[,\s]+', actual)) else 1)
PY
        then matched=true; fi
    done < <(printf '%s\n' "$actions" | tail -n +2 | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ $matched == true ]] || { clash_agent_fail2ban_error 'The active SSH banning action does not cover the detected SSH ports.'; return 1; }
    ignores=$(clash_agent_fail2ban_client get sshd ignoreip) || return 1
    expected_ignores=$(sed -n 's/^ignoreip[[:space:]]*=[[:space:]]*//p' "$file")
    [[ -n $expected_ignores ]] || return 1
    clash_agent_fail2ban_python - "$expected_ignores" "$ignores" <<'PY'
import ipaddress, re, sys
expected = sys.argv[1].split()
actual = [re.sub(r'^[|`]-\s*', '', line).strip() for line in sys.argv[2].splitlines() if re.match(r'^[|`]-', line)]
def covered(value):
    try:
        wanted = ipaddress.ip_network(value, strict=False)
    except ValueError:
        return value in actual
    for candidate in actual:
        try:
            network = ipaddress.ip_network(candidate, strict=False)
            if wanted.version == network.version and wanted.subnet_of(network):
                return True
        except ValueError:
            pass
    return False
raise SystemExit(0 if all(map(covered, expected)) else 1)
PY
}

clash_agent_configure_fail2ban() (
    local dir file ports ignores backup temp client had_file=false was_active=false was_enabled=false attempted=false
    dir=$(clash_agent_fail2ban_dir); file="${dir}/jail.d/zz-clash-agent-sshd.local"
    [[ -d $dir && ! -L $dir && ! -L ${dir}/jail.d && ! -L $file ]] || return 1
    if [[ -e $file ]]; then
        [[ -f $file ]] && grep -q '^# Managed by CLASH-AGENT$' "$file" || {
            clash_agent_fail2ban_error 'Refusing to overwrite an unowned Fail2ban drop-in.'; return 1;
        }
        had_file=true
    fi
    ports=$(clash_agent_fail2ban_ssh_ports) || return 1
    ignores=$(clash_agent_fail2ban_ignore_list) || return 1
    client=$(clash_agent_fail2ban_ssh_context) || return 1
    client=$(clash_agent_fail2ban_python -c 'import json,sys; print(json.loads(sys.argv[1])["client"])' "$client") || return 1
    systemctl is-active --quiet fail2ban.service && was_active=true
    systemctl is-enabled --quiet fail2ban.service && was_enabled=true
    mkdir -p "${dir}/jail.d" || return 1
    backup=$(mktemp "${dir}/.clash-agent-backup.XXXXXX") || return 1
    temp=$(mktemp "${dir}/jail.d/.clash-agent.XXXXXX") || { rm -f "$backup"; return 1; }
    trap 'rm -f "$backup" "$temp"' EXIT
    [[ $had_file != true ]] || cp -p "$file" "$backup" || return 1
    cat >"$temp" <<EOF || return 1
# Managed by CLASH-AGENT
[sshd]
enabled = true
backend = systemd
port = ${ports}
maxretry = 5
findtime = 600
bantime = 3600
ignoreip = ${ignores}
EOF
    chmod 644 "$temp" && mv -f "$temp" "$file" || return 1
    clash_agent_fail2ban_rollback() {
        if [[ $had_file == true ]]; then cp -p "$backup" "$file" || return 1
        else rm -f "$file" || return 1; fi
        if [[ $attempted == true ]]; then
            if [[ $was_active == true ]]; then
                clash_agent_fail2ban_client -t >/dev/null 2>&1 && clash_agent_fail2ban_client reload >/dev/null 2>&1 || true
            else systemctl stop fail2ban.service >/dev/null 2>&1 || true; fi
            if [[ $was_enabled != true ]]; then systemctl disable fail2ban.service >/dev/null 2>&1 || true; fi
        fi
    }
    if ! clash_agent_fail2ban_client -t; then
        clash_agent_fail2ban_rollback
        clash_agent_fail2ban_error 'Fail2ban configuration validation failed; the previous drop-in was restored.'
        return 1
    fi
    attempted=true
    if { [[ $was_active == true ]] && ! clash_agent_fail2ban_client reload; } ||
       { [[ $was_active != true ]] && ! systemctl start fail2ban.service; } ||
       ! clash_agent_fail2ban_wait ||
       { [[ -n $client ]] && ! clash_agent_fail2ban_unban_client "$client"; } ||
       ! systemctl enable fail2ban.service || ! clash_agent_verify_fail2ban; then
        clash_agent_fail2ban_rollback
        clash_agent_fail2ban_error 'Fail2ban activation or verification failed; the previous drop-in was restored.'
        return 1
    fi
    printf 'CLASH-AGENT: fail2ban protects SSH port(s) %s (5 failures / 10 minutes, ban 1 hour).\n' "$ports"
)
