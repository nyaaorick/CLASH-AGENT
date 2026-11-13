#!/usr/bin/env bash
# CLASH-AGENT: unattended defaults around mack-a/v2ray-agent.
set -o pipefail
CLASH_AGENT_SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 1
CLASH_AGENT_ENTRY="${CLASH_AGENT_SOURCE_DIR}/install.sh"
CLASH_AGENT_LIBRARY_ONLY=1
source "${CLASH_AGENT_SOURCE_DIR}/lib/upstream.sh" || exit 1
source "${CLASH_AGENT_SOURCE_DIR}/lib/system-defaults.sh" || exit 1
source "${CLASH_AGENT_SOURCE_DIR}/lib/clash-subscription.sh" || exit 1
source "${CLASH_AGENT_SOURCE_DIR}/lib/fail2ban.sh" || exit 1
source "${CLASH_AGENT_SOURCE_DIR}/lib/auto-install.sh" || exit 1
source "${CLASH_AGENT_SOURCE_DIR}/lib/cloudflare-api.sh" || exit 1
source "${CLASH_AGENT_SOURCE_DIR}/lib/cloudflare-config.sh" || exit 1
source "${CLASH_AGENT_SOURCE_DIR}/lib/cloudflare-firewall.sh" || exit 1
source "${CLASH_AGENT_SOURCE_DIR}/lib/cloudflare-install.sh" || exit 1
source "${CLASH_AGENT_SOURCE_DIR}/lib/cloudflare-dns.sh" || exit 1

clash_agent_install_options() {
    CA_MODE=reality CA_CF_DOMAIN= CA_CF_TOKEN_FILE= CA_CF_ADOPT=false
    while (($#)); do
        case $1 in
            --mode|--domain|--cf-token-file)
                [[ $# -ge 2 && -n $2 ]] || { clash_agent_error "Missing value for $1."; return 1; }
                case $1 in --mode) CA_MODE=$2 ;; --domain) CA_CF_DOMAIN=$2 ;; --cf-token-file) CA_CF_TOKEN_FILE=$2 ;; esac
                shift 2 ;;
            --adopt-existing) CA_CF_ADOPT=true; shift ;;
            *) clash_agent_error "Unknown installation option: $1"; return 1 ;;
        esac
    done
    case $CA_MODE in
        reality) [[ -z $CA_CF_DOMAIN && -z $CA_CF_TOKEN_FILE && $CA_CF_ADOPT == false ]] || return 1 ;;
        cloudflare-ws) CA_CF_DOMAIN=$(clash_agent_cf_domain "$CA_CF_DOMAIN") || { clash_agent_error 'Provide --domain with a valid hostname.'; return 1; } ;;
        *) clash_agent_error 'Mode must be reality or cloudflare-ws.'; return 1 ;;
    esac
}

clash_agent_main() {
    case ${1:-install} in
        install)
            [[ $# == 0 ]] || shift
            clash_agent_install_options "$@" || return 1
            if [[ $CA_MODE == cloudflare-ws ]]; then clash_agent_cf_install; return; fi
            clash_agent_install </dev/null || { clash_agent_error 'Installation did not complete; no success link was issued. Correct the error and run the same command again.'; return 1; }
            ;;
        show)
            clash_agent_paths
            if [[ -f $CA_STATE_FILE ]] && jq -e '.mode=="cloudflare-ws"' "$CA_STATE_FILE" >/dev/null 2>&1; then
                clash_agent_cf_show; return
            fi
            clash_agent_read_state && [[ $CA_STATUS == ready ]] &&
                clash_agent_verify_services && clash_agent_check_subscription &&
                clash_agent_verify_system && clash_agent_verify_fail2ban && clash_agent_print_result
            ;;
        dns-challenge)
            shift
            clash_agent_cf_dns_challenge "$@"
            ;;
        menu)
            # Keep the original management menu available explicitly. Updating
            # from mack-a would erase the fork; the checkout is the update source.
            updateV2RayAgent() { clash_agent_error 'Update CLASH-AGENT from its repository checkout.'; }
            aliasInstall() { :; }
            initVar ''
            checkSystem
            checkCPUVendor
            readInstallType
            readInstallProtocolType
            readConfigHostPathUUID
            readCustomPort
            readSingBoxConfig
            menu
            ;;
        --help|-h|help)
            cat <<'EOF'
CLASH-AGENT
  sudo bash install.sh [install]  Install unattended Reality + Vision defaults.
  sudo bash install.sh install --mode cloudflare-ws --domain HOST --cf-token-file FILE [--adopt-existing]
                                 Configure Cloudflare + nginx TLS + VLESS-WS.
  sudo bash install.sh show       Verify services and print the existing link.
  sudo bash install.sh menu       Open the original interactive management menu.

Defaults: random UUID, X25519 keys, short ID, node name, free TCP ports,
Reality SNI and 256-bit subscription token; BBR + fq; at least 1 GiB swap;
fail2ban SSH protection (5 failures in 10 minutes, 1-hour ban);
self-contained Clash.Meta/mihomo subscription over HTTP (no domain needed).
Requires root, Debian/Ubuntu, systemd and an amd64/arm64 Linux VPS.
Optional: CLASH_AGENT_SERVER_IP and CLASH_AGENT_SERVER_NAME.

Cloudflare mode: provide a hostname and a Cloudflare API token file (mode 600),
CF_API_TOKEN environment variable, or hidden terminal prompt. Token permissions:
Zone Read, DNS Edit, Zone Settings Read for the owning zone. The zone must already
use Full/Full (strict) SSL and have WebSockets enabled; other zone settings and
foreign DNS records are preserved. HTTPS subscription and DNS-01 renewal are automatic.
Existing nginx-fronted single VLESS-WS installations require --adopt-existing;
legacy subscription URLs remain available until explicitly retired by the operator.
EOF
            ;;
        --version) printf 'CLASH-AGENT 1.2.0\n' ;;
        *) clash_agent_error "Unknown command: $1"; return 1 ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    clash_agent_main "$@"
fi
