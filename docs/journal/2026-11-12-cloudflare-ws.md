---
author: nyaaorick
progress:
  - date: 2026-11-12
    text: "Prepare CLASH-AGENT v1.2.0 with automatic Cloudflare WS installation, documentation, reviewed standalone artifact and release assets. Validation includes 12 API tests, 34 isolated fail2ban scenarios, 15 system-default scenarios, 27 existing installer failure stages and native Linux TCP/UDP integration."
    refs:
      - "CHANGELOG.md"
      - "scripts/CLASH-AGENT/documents/cloudflare-ws.md"
---

# Cloudflare WS installation

The new mode accepts a hostname and Cloudflare API Token, configures the Cloudflare/nginx/VLESS-WS chain and private HTTPS subscription, and checks ready state after maintenance and TCP/UDP probes. The default Reality installation remains available.

The reviewed artifact passed the full local suite, native Linux integration, official pinned acme.sh private-home tests and independent review. Five review findings were fixed and verified: explicit ACME home selection, unmanaged vendor-service refusal, failed-core retry ownership, credential-safe DNS transport and renewal metadata persistence.

The release contains only generic source, tests and documentation. No server records, production credentials or private deployment logs are included. Live Cloudflare DNS writes, external CA issuance and existing-server migration were not performed as part of this release.
