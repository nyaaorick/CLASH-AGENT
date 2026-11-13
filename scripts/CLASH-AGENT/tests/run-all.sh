#!/usr/bin/env bash
set -euo pipefail
test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
for test in "$test_dir"/test-*.sh; do
    printf '\nRUN %s\n' "${test##*/}"
    bash "$test"
done
python3 "$test_dir/test-cloudflare-api.py"
build=$(mktemp /tmp/clash-agent-built-test.XXXXXX)
trap 'rm -f "$build"' EXIT
bash "$test_dir/../build.sh" "$build"
bash "$build" --version
bash "$build" --help >/dev/null
# Source with --help to avoid invoking installation; compare the real generated
# artifact's renderer output to the modular entry point, not source substrings.
out=$(mktemp -d /tmp/clash-agent-parity.XXXXXX)
trap 'rm -f "$build"; rm -rf "$out"' EXIT
for item in "$test_dir/../install.sh" "$build"; do
    bash -c 'source "$1" --help >/dev/null; clash_agent_cf_render_core node.example.com 10443 123e4567-e89b-42d3-a456-426614174000 /samplews Example' test "$item" >"$out/$(basename "$item").json"
done
cmp "$out/install.sh.json" "$out/$(basename "$build").json"
printf 'PASS: complete suite and standalone/modular renderer parity.\n'
