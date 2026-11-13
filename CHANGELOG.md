# Changelog

## v1.2.0 — 2026-11-12

- Add `install --mode cloudflare-ws --domain HOST` to automate Cloudflare DNS, DNS-01 certificates, nginx HTTPS, loopback sing-box VLESS-WS, private HTTPS Clash subscriptions and maintenance.
- Accept a Cloudflare API Token through a hidden prompt, protected environment or owner-only token file. Scope DNS operations to the requested hostname and challenge proof; keep credentials out of HTTP command arguments.
- Add repeatable mode-specific state, narrowly validated `--adopt-existing`, pending-install retry, scoped backups and rollback. Preserve the existing node identity and transport settings during adoption.
- Add Cloudflare origin address restrictions, independent certificate renewal and scheduled address refresh. Require certificate, subscription, WS, TCP/UDP and maintenance checks before ready state.
- Preserve the default unattended Reality + Vision mode and Debian 10 fail2ban compatibility.
- Add isolated API/lifecycle/firewall/certificate coverage and native Linux nginx/VLESS-WS TCP/UDP integration. Real Cloudflare DNS mutation and external CA issuance remain separate live-validation boundaries.
