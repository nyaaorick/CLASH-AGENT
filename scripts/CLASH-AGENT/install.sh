#!/usr/bin/env bash
# CLASH-AGENT: unattended defaults around mack-a/v2ray-agent.
set -o pipefail
CLASH_AGENT_SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 1
CLASH_AGENT_LIBRARY_ONLY=1
source "${CLASH_AGENT_SOURCE_DIR}/lib/upstream.sh" || exit 1
source "${CLASH_AGENT_SOURCE_DIR}/lib/system-defaults.sh" || exit 1
source "${CLASH_AGENT_SOURCE_DIR}/lib/clash-subscription.sh" || exit 1
source "${CLASH_AGENT_SOURCE_DIR}/lib/auto-install.sh" || exit 1

clash_agent_main() {
    case ${1:-install} in
        install)
            [[ $# -le 1 ]] || { clash_agent_error 'install takes no positional options.'; return 1; }
            clash_agent_install </dev/null || { clash_agent_error 'Installation did not complete; no success link was issued. Correct the error and run the same command again.'; return 1; }
            ;;
        show)
            clash_agent_paths
            clash_agent_read_state && [[ $CA_STATUS == ready ]] &&
                clash_agent_verify_services && clash_agent_check_subscription &&
                clash_agent_verify_system && clash_agent_print_result
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
  sudo bash install.sh show       Verify services and print the existing link.
  sudo bash install.sh menu       Open the original interactive management menu.

Defaults: random UUID, X25519 keys, short ID, node name, free TCP ports,
Reality SNI and 256-bit subscription token; BBR + fq; at least 1 GiB swap;
self-contained Clash.Meta/mihomo subscription over HTTP (no domain needed).
Requires root, Debian/Ubuntu, systemd and an amd64/arm64 Linux VPS.
Optional: CLASH_AGENT_SERVER_IP and CLASH_AGENT_SERVER_NAME.
EOF
            ;;
        --version) printf 'CLASH-AGENT 1.0.0\n' ;;
        *) clash_agent_error "Unknown command: $1"; return 1 ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    clash_agent_main "$@"
fi
