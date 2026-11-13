# CLASH-AGENT

Set up a VPS with Reality + Vision and a ready-to-import Clash subscription in one command. Built on [mack-a/v2ray-agent](https://github.com/mack-a/v2ray-agent), CLASH-AGENT reuses its core installation, Reality configuration, key generation, and service functions without the numbered installation menus.

Version **1.2.0** also provides an automatic **Cloudflare + nginx TLS + VLESS-WS** option. Supply a hostname and an API token; DNS, certificate, private HTTPS subscription, origin protection and renewal are configured together. See the [Cloudflare mode guide](documents/cloudflare-ws.md) for token permissions, preconditions, explicit existing-install adoption and verification limits.

```bash
sudo bash install.sh install --mode cloudflare-ws --domain node.example.com --cf-token-file /root/cloudflare-token
```

Use a rebuilt 1.2.0+ artifact for this command. A local build does not update an older downloaded or published installer automatically. Omitting `--cf-token-file` uses `CF_API_TOKEN` or a hidden terminal prompt.

## Install from GitHub

Run this on the target VPS. No Git clone, source upload, or local checkout is needed:

```bash
(set -e; installer=$(mktemp); trap 'rm -f "$installer"' EXIT; curl -fsSL https://raw.githubusercontent.com/nyaaorick/CLASH-AGENT/main/install.sh -o "$installer"; if [ "$(id -u)" -eq 0 ]; then bash "$installer"; else sudo env SSH_CONNECTION="${SSH_CONNECTION:-}" SSH_CLIENT="${SSH_CLIENT:-}" bash "$installer"; fi)
```

The command downloads the complete standalone installer before executing it. Installation finishes by printing a Clash.Meta/mihomo subscription URL.

The non-root branch forwards the current SSH connection details through `sudo` so the management address remains available to fail2ban setup.

Requires Debian or Ubuntu, a running systemd host, amd64 or arm64, root privileges, and a kernel that supports BBR and swap. Outbound Internet access is needed to download packages and the sing-box core.

## Defaults

- **Proxy:** sing-box, VLESS + Reality + Vision over TCP.
- **Random values:** UUID, X25519 key pair, short ID, node name, two available TCP ports, and a 256-bit subscription token.
- **Reality target:** a random candidate from the upstream list, checked for a working TLS 1.3 connection.
- **Networking:** BBR and a persistent `fq` default. Existing interface qdiscs are not replaced.
- **Swap:** at least 1 GiB; sufficient existing active swap is retained, otherwise a dedicated 1 GiB file is added without disabling existing swap.
- **SSH protection:** fail2ban is installed and enabled automatically. Five failed SSH logins within 10 minutes trigger a 1-hour ban on the detected SSH ports.
- **Client configuration:** a complete Clash.Meta/mihomo profile with its proxy, selection group, and routing rule, served by a separate nginx instance.

The subscription uses **plaintext HTTP**, so no personal domain or certificate is required. Its random URL is an access credential: keep the full URL private. Configure HTTPS separately if encrypted subscription delivery is required. The Reality proxy connection uses Reality independently of subscription delivery.

Allow the two printed TCP ports in your provider's security group or external firewall. The installer adds the required supported host-firewall rules, preserves existing nginx sites, and leaves SSH settings unchanged.

The managed SSH policy is written to `/etc/fail2ban/jail.d/zz-clash-agent-sshd.local`. Fail2ban configuration retains unrelated jails and existing IP whitelists. When the current SSH management address is available, it is added to the ignore list. Configuration and runtime checks must pass before installation reports success.

## Repeat runs and management

The default Reality installer leaves unmanaged installations unchanged and stops. Cloudflare mode has a narrow, explicit `--adopt-existing` path for the documented nginx-fronted single WS layout; other layouts remain rejected. On a managed installation, rerunning the same mode resumes an interrupted setup and keeps existing identity.

State is stored in `/etc/clash-agent/state.json`, including the private key and subscription credential. The state file is readable only by root.

The standalone installer accepts these commands:

| Command | Action |
| --- | --- |
| `install` or no argument | Apply the unattended defaults. |
| `show` | Check ready state, services, HTTP subscription, BBR, swap, and SSH protection, then print the existing link. |
| `menu` | Open the original advanced management menu. |
| `--help` | Show usage without installing. |

For a saved copy, use `sudo bash install.sh show`. Automatic detection can be overridden with `CLASH_AGENT_SERVER_IP` or `CLASH_AGENT_SERVER_NAME` on the first installation; a supplied Reality server name must pass the TLS 1.3 check.

## Develop and build

The editable entry point is `scripts/CLASH-AGENT/install.sh`. The default installation sequence is in `lib/auto-install.sh`; the upstream implementation is in `lib/upstream.sh`.

After editing the source, run this from the repository root:

```bash
bash scripts/CLASH-AGENT/build.sh
```

This rebuilds the root `install.sh` as a single distributable file. Upstream self-update is disabled through the CLASH-AGENT entry point so it cannot replace this fork. Update the source and rebuild to publish changes.

Validation includes isolated installation and failure-recovery tests, Bash syntax checks, and configuration parsing by real sing-box and mihomo binaries. On 2026-11-06, version 1.1.2 was also verified on a fresh Debian 10 host with kernel 4.19, sing-box 1.14.4, and Fail2ban 0.10.2: public subscription HTTP 200, Reality-only HTTPS 204 requests, the expected exit IP, and a live SSH ban/unban test all passed.

Run all suites with `bash scripts/CLASH-AGENT/tests/run-all.sh`. Cloudflare coverage includes scoped API errors/DNS recovery, explicit adoption and service/config restoration, independent certificate maintenance, origin firewall preservation and real Linux nginx WS TCP/UDP integration. Real DNS/ACME deployment is a separate validation boundary.

Version 1.1.0 adds automatic fail2ban protection to the existing one-command installation. Rerun the command on a managed installation to apply the new default while retaining its proxy credentials and ports.

Version 1.1.2 also supports the legacy Fail2ban 0.10 configuration reader and its already-unbanned client response on Debian 10.

## License and upstream

GNU Affero General Public License v3.0. See [LICENSE](https://github.com/nyaaorick/CLASH-AGENT/blob/main/scripts/CLASH-AGENT/LICENSE), [upstream and modification notes](https://github.com/nyaaorick/CLASH-AGENT/blob/main/scripts/CLASH-AGENT/UPSTREAM.md), and the preserved [upstream README](https://github.com/nyaaorick/CLASH-AGENT/blob/main/scripts/CLASH-AGENT/README.upstream.md).
