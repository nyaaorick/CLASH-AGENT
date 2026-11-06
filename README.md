# CLASH-AGENT

Set up a VPS with Reality + Vision and a ready-to-import Clash subscription in one command. Built on [mack-a/v2ray-agent](https://github.com/mack-a/v2ray-agent), CLASH-AGENT reuses its core installation, Reality configuration, key generation, and service functions without the numbered installation menus.

## Install from GitHub

Run this on the target VPS. No Git clone, source upload, or local checkout is needed:

```bash
(set -e; installer=$(mktemp); trap 'rm -f "$installer"' EXIT; curl -fsSL https://raw.githubusercontent.com/nyaaorick/CLASH-AGENT/main/install.sh -o "$installer"; if [ "$(id -u)" -eq 0 ]; then bash "$installer"; else sudo bash "$installer"; fi)
```

The command downloads the complete standalone installer before executing it. Installation finishes by printing a Clash.Meta/mihomo subscription URL.

Requires Debian or Ubuntu, a running systemd host, amd64 or arm64, root privileges, and a kernel that supports BBR and swap. Outbound Internet access is needed to download packages and the sing-box core.

## Defaults

- **Proxy:** sing-box, VLESS + Reality + Vision over TCP.
- **Random values:** UUID, X25519 key pair, short ID, node name, two available TCP ports, and a 256-bit subscription token.
- **Reality target:** a random candidate from the upstream list, checked for a working TLS 1.3 connection.
- **Networking:** BBR + fq, persisted across reboots.
- **Swap:** at least 1 GiB; sufficient existing active swap is retained, otherwise a dedicated 1 GiB file is added without disabling existing swap.
- **Client configuration:** a complete Clash.Meta/mihomo profile with its proxy, selection group, and routing rule, served by a separate nginx instance.

The subscription uses **plaintext HTTP**, so no personal domain or certificate is required. Its random URL is an access credential: keep the full URL private. Configure HTTPS separately if encrypted subscription delivery is required. The Reality proxy connection uses Reality independently of subscription delivery.

Allow the two printed TCP ports in your provider's security group or external firewall. The installer adds the required supported host-firewall rules, preserves existing nginx sites, and leaves SSH settings unchanged.

## Repeat runs and management

Installations that CLASH-AGENT does not manage are left unchanged, and automatic installation stops. On a managed installation, rerunning the same command resumes an interrupted setup and keeps existing credentials and ports.

State is stored in `/etc/clash-agent/state.json`, including the private key and subscription credential. The state file is readable only by root.

The standalone installer accepts these commands:

| Command | Action |
| --- | --- |
| `install` or no argument | Apply the unattended defaults. |
| `show` | Check ready state, services, HTTP subscription, BBR, and swap, then print the existing link. |
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

Validation includes isolated installation and failure-recovery tests, Bash syntax checks, and configuration parsing by real sing-box and mihomo binaries. A live VPS deployment and external reachability have not been verified.

## License and upstream

GNU Affero General Public License v3.0. See [LICENSE](https://github.com/nyaaorick/CLASH-AGENT/blob/main/scripts/CLASH-AGENT/LICENSE), [upstream and modification notes](https://github.com/nyaaorick/CLASH-AGENT/blob/main/scripts/CLASH-AGENT/UPSTREAM.md), and the preserved [upstream README](https://github.com/nyaaorick/CLASH-AGENT/blob/main/scripts/CLASH-AGENT/README.upstream.md).
