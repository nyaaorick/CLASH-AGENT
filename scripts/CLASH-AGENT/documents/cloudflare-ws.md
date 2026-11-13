# Automatic Cloudflare + VLESS-WS installation

This mode is available in CLASH-AGENT **1.2.0** and later. It configures the same topology used by RackNerd: Cloudflare → nginx HTTPS on TCP 443 → sing-box VLESS-WS on `127.0.0.1:10443`. It is separate from the default Reality + Vision installation.

## Inputs and command

Supply a hostname in a Cloudflare-managed zone and a Cloudflare **API Token**. A Global API Key alone is not supported. The installer discovers the owning zone and account, detects the origin IPv4 address, generates credentials and paths, obtains a DNS-01 certificate, enables the proxied A record, and prints an HTTPS Clash subscription after verification.

With a token file readable only by its owner:

```bash
sudo bash install.sh install --mode cloudflare-ws \
  --domain node.example.com \
  --cf-token-file /root/cloudflare-token
```

The token file must be a regular file with mode `600` or stricter. Do not put its contents on a command line, in shell history, or in a public document. Alternatively, omit `--cf-token-file` and paste the token at the hidden terminal prompt, or provide `CF_API_TOKEN` through a protected environment. Never use an example token as a real credential.

Check the artifact before using it:

```bash
bash install.sh --version
bash install.sh --help
```

These commands require the rebuilt 1.2.0 artifact; updating local source does not update a previously downloaded installer or the published GitHub release automatically. The existing GitHub one-line command without extra arguments still chooses Reality defaults.

## Preconditions and Cloudflare scope

- Root on Debian/Ubuntu with systemd, an amd64/arm64 CPU, and a reachable public IPv4 origin. Allow inbound TCP 443 through the provider firewall/security group. Host rules alone cannot change the provider firewall.
- Cloudflare Token permissions on the relevant zone: **Zone Read**, **DNS Edit**, and **Zone Settings Read**. Limit the token to the zone that owns the node hostname.
- The zone must already have WebSockets enabled and SSL mode **Full** or **Full (strict)**. Full (strict) is preferred. The installer checks these settings and stops on Flexible/Off or disabled WebSockets; it does not change zone-wide settings used by other hosts.
- The exact hostname must have no records, or one A record already pointing at this origin. An unrelated A record, AAAA/CNAME record or multiple records is rejected. Other hostnames are not modified.
- The hostname's Cloudflare edge certificate must be provisioned, and zone rules must allow the WS and private subscription paths. The final probes detect failures but the installer does not rewrite WAF, Access, redirects, cache rules or other account policies.
- Outbound access to Cloudflare API, the official acme.sh source, the ACME CA, core/package downloads, ipify and STUN is required. DNS-01 validation can take several minutes.

`CLASH_AGENT_SERVER_IP` can override public IPv4 detection when necessary. `CLASH_AGENT_SERVER_NAME` belongs to Reality mode and does not configure this mode's hostname.

## Generated configuration

| Component | Result |
| --- | --- |
| Public hostname | Proxied Cloudflare A record, automatic TTL |
| TLS | Host certificate from Let's Encrypt using Cloudflare DNS-01 |
| nginx | Port 443, exact WS path, exact random HTTPS subscription path, fallback 404 |
| sing-box | VLESS + WS, IPv4 loopback only, one account; effective config and WS source fragment are kept consistent |
| Clash profile | Domain endpoint, correct SNI/Host/path, TLS and UDP enabled, standalone routing, local-only SOCKS and DNS listeners |
| Subscription | `https://HOST/s/<random-256-bit-token>/clash.yaml`; `Cache-Control: no-store`, access logging disabled |
| Origin protection | Cloudflare IPv4 ranges plus loopback allowed on the managed TCP/443 path; unrelated ports and SSH preserved |
| Maintenance | Independent systemd certificate timer and weekly Cloudflare address refresh |
| System defaults | Existing BBR/fq, swap and SSH fail2ban helpers reused |

The normal profile uses the hostname. Fixed Cloudflare IP selection is not automatically benchmarked or added. The host-side IPv4 origin and Cloudflare's client-facing IPv6 availability are different things; this version does not add IPv6 origin listeners.

The standalone profile defaults to SOCKS5 on local port 7890. Clash Verge controls its own listener ports and TUN settings; importing the subscription does not replace GUI-managed settings such as the existing SOCKS5 7898 and mixed 7897 setup.

TCP and application UDP travel inside the WS/TCP transport to the origin. This does not turn the ordinary Cloudflare CDN into a native UDP, Reality or Hysteria2 relay.

## Existing installation: explicit adoption

An existing installation is never silently overwritten. For the narrowly supported RackNerd layout:

```bash
sudo bash install.sh install --mode cloudflare-ws \
  --domain node.example.com \
  --cf-token-file /root/cloudflare-token \
  --adopt-existing
```

Adoption validates:

- The effective sing-box config has exactly one VLESS-WS inbound on `127.0.0.1:10443`, one user and no TLS on that loopback inbound.
- `/etc/nginx/conf.d/sub.conf` contains one HTTPS server block for the exact hostname and the same WS upstream/path. Its locations must be the existing WS path, optional exact `/clash.yaml`, and fallback `/`.
- Other vhosts, including a same-host HTTP redirect and a root-domain subscription vhost, stay in the file.
- Existing UUID and WS path are retained. Other effective sing-box sections are retained; the source WS fragment is reconciled with the loopback listener so later merging does not restore a public TLS listener accidentally.

This is not a general importer for every nginx/Xray/multi-protocol layout. Unsupported custom locations, shared server-name blocks, other state schemas and ambiguous ownership stop installation before adoption.

For client continuity, adoption retains an existing exact `/clash.yaml` location and other vhosts. **An old public subscription remains public.** The new random path alone does not make previously exposed credentials private. Retire old URLs and rotate credentials after updating clients in a separate planned migration; the installer prints a reminder.

## State, repeat runs and failures

- Private mode-specific state: `/etc/clash-agent/state.json`, schema 2, `mode: cloudflare-ws`.
- Private certificate/ACME home: `/etc/clash-agent/tls/` and `/etc/clash-agent/acme/`.
- DNS credential: `/etc/clash-agent/cloudflare-token`, mode 600. A controlled ACME provider invokes the private runtime installer, which reads this file and sends authentication through a 0600 curl configuration. The API token is not passed in curl/wget argv; the ACME account saves only helper/state paths. Do not publish the state directory or include it in a public support bundle.
- Published profile: `/var/lib/clash-agent/clash.yaml`.
- Saved backups and service-state inventory: `/etc/clash-agent/backups/run.*`.

Repeated installation keeps the account, WS path and subscription token. It can resume pending state but refuses to treat it as ready. A schema-1 Reality instance cannot be converted simply by selecting the other mode or inventing an owner file.

After the local/DNS transaction begins, a failure attempts to restore changed DNS, saved nginx/core/certificate files and original service states. A failed API response after a DNS write is reconciled before rollback. Backup files are retained for inspection. Packages and successful BBR/swap/fail2ban setup are not uninstalled during failure recovery. Inspect any reported rollback error before retrying; the private `files` manifest maps each saved file to its original absolute path.

Failed installation does not print a success subscription. Do not import a link from pending or failed state.

## Renewal and verification

The dedicated ACME home uses a pinned official acme.sh bootstrap. Every issue/install/cron invocation explicitly sets home, config-home and cert-home; placing the script in a private directory alone does not isolate acme.sh. It does not replace the original installation's ACME account or crontab. The certificate timer runs twice daily with jitter and persists missed runs. Renewal installs the cert/key to the managed paths and runs `nginx -t && systemctl reload nginx.service`.

The boot firewall service protects nginx startup. A separate oneshot refresh service is scheduled weekly, avoiding a timer that would repeatedly start an already-active `RemainAfterExit` unit. Validated cached Cloudflare ranges are retained if a refresh download fails.

```bash
sudo bash install.sh show
sudo systemctl list-timers 'clash-agent-cf-*'
sudo journalctl -u clash-agent-cf-renew.service
```

Before ready state, the installer checks the certificate, local HTTPS subscription contents, WS upgrade, public HTTPS subscription contents, and a temporary sing-box client through the public Cloudflare hostname. That client must pass TCP exit-IP and UDP/STUN probes. The timers, BBR/swap and SSH protection are also checked. `show` repeats checks without installing or changing DNS.

Development validation is separate from a live install: use `bash scripts/CLASH-AGENT/tests/run-all.sh`. It includes real API behavior against a local HTTP fixture, retry/failure/adoption tests, real core/profile parsing, and native nginx + WS TCP/UDP integration when Linux/nginx/sing-box are available. An external CA issuance and real Cloudflare DNS write require their own authorized live run; fixture tests do not prove those external operations succeeded.

## Source references

- [CLI](../install.sh)
- [Scoped Cloudflare API and DNS rollback](../lib/cloudflare-api.sh)
- [Core, profile and nginx renderers](../lib/cloudflare-config.sh)
- [Origin firewall and refresh](../lib/cloudflare-firewall.sh)
- [Installation, adoption, renewal and health](../lib/cloudflare-install.sh)
- [Credential-safe ACME provider and scoped TXT operations](../lib/cloudflare-dns.sh)
- [Cloudflare DNS API](https://developers.cloudflare.com/api/resources/dns/subresources/records/methods/create/)
- [Cloudflare WebSockets](https://developers.cloudflare.com/network/websockets/)
- [Cloudflare Full (strict)](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/)
- [Pinned acme.sh reference](https://github.com/acmesh-official/acme.sh/blob/3.1.2/acme.sh)
