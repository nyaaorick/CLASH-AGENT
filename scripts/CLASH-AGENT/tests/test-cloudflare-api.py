#!/usr/bin/env python3
"""Exercise real Bash/curl/jq API behavior against an HTTP Cloudflare fixture."""
import http.server
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from urllib.parse import parse_qs, urlsplit

ENTRY = Path(__file__).resolve().parents[1] / "install.sh"
TOKEN = "fixture_token_must_never_be_logged_123456789"


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.dispatch()

    def do_POST(self):
        self.dispatch()

    def do_PATCH(self):
        self.dispatch()

    def do_DELETE(self):
        self.dispatch()

    def dispatch(self):
        s = self.server
        parsed = urlsplit(self.path)
        query = parse_qs(parsed.query)
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        data = json.loads(body) if body else None
        s.calls.append((self.command, parsed.path, data))
        if self.headers.get("Authorization") != "Bearer " + TOKEN:
            result = {"success": False, "errors": [{"code": 9109, "message": TOKEN}]}
        elif s.deny:
            result = {"success": False, "errors": [{"code": 10000, "message": TOKEN}]}
        elif parsed.path == "/zones":
            name = query.get("name", [""])[0]
            result = {"success": True, "result": [{"id": "a" * 32, "name": "example.com", "status": "active", "account": {"id": "b" * 32}}] if name == "example.com" else []}
        elif "/settings/" in parsed.path:
            setting = parsed.path.rsplit("/", 1)[-1]
            result = {"success": True, "result": {"id": setting, "value": s.ssl if setting == "ssl" else "on"}}
        elif parsed.path.endswith("/dns_records") and self.command == "GET":
            records = [r for r in s.records if all(r.get(k) == query[k][0] for k in ("name", "type") if k in query)]
            result = {"success": True, "result": records, "result_info": {"total_pages": 1}}
        elif parsed.path.endswith("/dns_records") and self.command == "POST":
            record = dict(data, id=f"{len(s.records)+10:032x}")
            s.records.append(record)
            result = {"success": True, "result": record}
        elif "/dns_records/" in parsed.path and self.command == "PATCH":
            record_id = parsed.path.rsplit("/", 1)[-1]
            s.records = [dict(r, **data) if r["id"] == record_id else r for r in s.records]
            result = {"success": True, "result": next(r for r in s.records if r["id"] == record_id)}
        elif "/dns_records/" in parsed.path and self.command == "DELETE":
            record_id = parsed.path.rsplit("/", 1)[-1]
            s.records = [r for r in s.records if r["id"] != record_id]
            result = {"success": True, "result": {"id": record_id}}
        else:
            result = {"success": False, "errors": [{"code": 1001}]}
        if self.command in ("POST", "PATCH") and s.fail_write_after_mutate:
            s.fail_write_after_mutate = False
            result = {"success": False, "errors": [{"code": 1002, "message": TOKEN}]}
        payload = json.dumps(result).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


class CloudflareTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), API)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        self.server.calls, self.server.records = [], []
        self.server.deny, self.server.ssl = False, "strict"
        self.server.fail_write_after_mutate = False
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def shell(self, script, **extra):
        env = dict(os.environ, CF_API_TOKEN=TOKEN,
                   CLASH_AGENT_CF_API_BASE=f"http://127.0.0.1:{self.server.server_port}",
                   CLASH_AGENT_STATE_DIR=self.tmp.name)
        env.update(extra)
        return subprocess.run(["bash", "-c", 'source "$1"; ' + script, "test", str(ENTRY)],
                              env=env, capture_output=True, text=True)

    def test_domain_normalization_and_injection_rejection(self):
        r = self.shell("clash_agent_cf_domain 'Node.Example.COM.'")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "node.example.com")
        for name in ["example.com;touch /tmp/injected", "*.example.com", "-bad.example.com", "x..com", "https://example.com", "a" * 64 + ".com"]:
            r = self.shell('clash_agent_cf_domain "$BAD_DOMAIN"', BAD_DOMAIN=name)
            self.assertNotEqual(r.returncode, 0, name)
            self.assertEqual(r.stdout, "")

    def test_zone_lookup_settings_and_dns_create(self):
        r = self.shell("CA_CF_DOMAIN=node.example.com; CA_SERVER=203.0.113.7; clash_agent_cf_load_token && clash_agent_cf_discover && clash_agent_cf_ensure_dns")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.server.records), 1)
        record = self.server.records[0]
        self.assertEqual((record["name"], record["type"], record["content"], record["proxied"]),
                         ("node.example.com", "A", "203.0.113.7", True))
        self.assertFalse(any("/settings/" in path and method != "GET" for method, path, _ in self.server.calls))
        self.assertNotIn(TOKEN, r.stdout + r.stderr)

    def test_foreign_a_aaaa_and_cname_are_not_overwritten(self):
        for kind, content in [("A", "203.0.113.99"), ("AAAA", "2001:db8::1"), ("CNAME", "other.example.com")]:
            self.server.calls = []
            self.server.records = [{"id": "c" * 32, "name": "node.example.com", "type": kind, "content": content, "proxied": True, "ttl": 1}]
            r = self.shell("CA_CF_DOMAIN=node.example.com; CA_SERVER=203.0.113.7; clash_agent_cf_load_token && clash_agent_cf_discover && clash_agent_cf_ensure_dns")
            self.assertNotEqual(r.returncode, 0, kind)
            self.assertFalse(any(method != "GET" for method, _, _ in self.server.calls))

    def test_existing_matching_record_is_idempotent(self):
        self.server.records = [{"id": "c" * 32, "name": "node.example.com", "type": "A", "content": "203.0.113.7", "proxied": True, "ttl": 1}]
        r = self.shell("CA_CF_DOMAIN=node.example.com; CA_SERVER=203.0.113.7; clash_agent_cf_load_token && clash_agent_cf_discover && clash_agent_cf_ensure_dns")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(any(method != "GET" for method, _, _ in self.server.calls))

    def test_created_record_can_be_rolled_back(self):
        r = self.shell("CA_CF_DOMAIN=node.example.com; CA_SERVER=203.0.113.7; clash_agent_cf_load_token && clash_agent_cf_discover && clash_agent_cf_ensure_dns && clash_agent_cf_rollback_dns")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.server.records, [])

    def test_api_error_does_not_echo_token_or_mutate_dns(self):
        self.server.deny = True
        r = self.shell("CA_CF_DOMAIN=node.example.com; clash_agent_cf_load_token && clash_agent_cf_discover")
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn(TOKEN, r.stdout + r.stderr)
        self.assertFalse(any(method != "GET" for method, _, _ in self.server.calls))

    def test_flexible_ssl_is_rejected_without_changing_zone(self):
        self.server.ssl = "flexible"
        r = self.shell("CA_CF_DOMAIN=node.example.com; clash_agent_cf_load_token && clash_agent_cf_discover")
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(any(method != "GET" for method, _, _ in self.server.calls))

    def test_failed_create_response_is_reconciled_and_rolled_back(self):
        self.server.fail_write_after_mutate = True
        r = self.shell("CA_CF_DOMAIN=node.example.com; CA_SERVER=203.0.113.7; clash_agent_cf_load_token && clash_agent_cf_discover || exit; if clash_agent_cf_ensure_dns; then exit 90; fi; clash_agent_cf_rollback_dns")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.server.records, [])
        self.assertNotIn(TOKEN, r.stdout + r.stderr)

    def test_failed_patch_response_restores_original_record(self):
        self.server.records = [{"id": "c" * 32, "name": "node.example.com", "type": "A", "content": "203.0.113.7", "proxied": False, "ttl": 300}]
        self.server.fail_write_after_mutate = True
        r = self.shell("CA_CF_DOMAIN=node.example.com; CA_SERVER=203.0.113.7; clash_agent_cf_load_token && clash_agent_cf_discover || exit; if clash_agent_cf_ensure_dns; then exit 90; fi; clash_agent_cf_rollback_dns")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.server.records[0]["proxied"])
        self.assertEqual(self.server.records[0]["ttl"], 300)

    def test_token_file_permissions_and_symlinks(self):
        p = Path(self.tmp.name) / "token"
        p.write_text(TOKEN + "\n")
        p.chmod(0o600)
        r = self.shell('CA_CF_TOKEN_FILE="$TOKEN_PATH"; clash_agent_cf_load_token', TOKEN_PATH=str(p), CF_API_TOKEN="")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn(TOKEN, r.stdout + r.stderr)
        p.chmod(0o644)
        self.assertNotEqual(self.shell('CA_CF_TOKEN_FILE="$TOKEN_PATH"; clash_agent_cf_load_token', TOKEN_PATH=str(p)).returncode, 0)
        link = p.with_name("link")
        link.symlink_to(p)
        self.assertNotEqual(self.shell('CA_CF_TOKEN_FILE="$TOKEN_PATH"; clash_agent_cf_load_token', TOKEN_PATH=str(link)).returncode, 0)

    def dns_state(self):
        root = Path(self.tmp.name)
        (root / "state.json").write_text(json.dumps(dict(product="CLASH-AGENT", schema=2, mode="cloudflare-ws", status="installing",
            domain="node.example.com", server="203.0.113.7", uuid="123e4567-e89b-42d3-a456-426614174000", token="0" * 64,
            ws_path="/samplews", ws_port=10443, node_name="Fixture", nginx_site="/etc/nginx/conf.d/sub.conf", adopted=False, zone_id="a" * 32)))
        p = root / "cloudflare-token"
        p.write_text(TOKEN + "\n")
        p.chmod(0o600)
        return root

    def test_dns01_preserves_other_txt_and_rejects_other_hostnames(self):
        self.dns_state()
        self.server.records = [{"id": "e" * 32, "name": "_acme-challenge.node.example.com", "type": "TXT", "content": "Q" * 43}]
        script = "clash_agent_main dns-challenge add _acme-challenge.node.example.com " + "P" * 43
        r = self.shell(script)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.server.records), 2)
        r = self.shell("clash_agent_main dns-challenge remove _acme-challenge.node.example.com " + "P" * 43)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual([r["content"] for r in self.server.records], ["Q" * 43])
        self.server.calls = []
        r = self.shell("clash_agent_main dns-challenge add _acme-challenge.other.example.com " + "P" * 43)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.server.calls, [])

    def test_dns01_provider_renewal_uses_saved_paths_and_no_token_in_argv(self):
        root = self.dns_state()
        hook = self.shell("clash_agent_cf_render_dns_hook")
        self.assertEqual(hook.returncode, 0, hook.stderr)
        (root / "hook.sh").write_text(hook.stdout)
        runtime = root / "runtime-installer.sh"
        build = subprocess.run(["bash", str(ENTRY.parent / "build.sh"), str(runtime)], capture_output=True, text=True)
        self.assertEqual(build.returncode, 0, build.stderr)
        (root / "bin").mkdir()
        real_curl = shutil.which("curl")
        wrapper = root / "bin/curl"
        wrapper.write_text("#!/usr/bin/env python3\nimport os,json,sys\nwith open(os.environ['CURL_ARGV_LOG'],'a') as f:f.write(json.dumps(sys.argv[1:])+'\\n')\nos.execv(os.environ['REAL_CURL'],[os.environ['REAL_CURL']]+sys.argv[1:])\n")
        wrapper.chmod(0o700)
        env = dict(os.environ, CLASH_AGENT_CF_API_BASE=f"http://127.0.0.1:{self.server.server_port}",
                   PATH=str(root / "bin") + os.pathsep + os.environ["PATH"], REAL_CURL=real_curl,
                   CURL_ARGV_LOG=str(root / "argv.log"), HOOK_ROOT=str(root))
        script = '''. "$HOOK_ROOT/hook.sh"
_readaccountconf_mutable() { if [ -f "$HOOK_ROOT/$1" ]; then cat "$HOOK_ROOT/$1"; fi; }
_saveaccountconf_mutable() { printf '%s' "$2" >"$HOOK_ROOT/$1"; }
'''
        first = script + f'CLASH_CF_INSTALLER="{runtime}" CLASH_CF_STATE_DIR="$HOOK_ROOT" dns_clash_agent_cf_add _acme-challenge.node.example.com {"P" * 43}'
        r = subprocess.run(["sh", "-c", first], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        # A new process, like a systemd renewal, has no caller-provided paths.
        second = script + f'dns_clash_agent_cf_rm _acme-challenge.node.example.com {"P" * 43}'
        r = subprocess.run(["sh", "-c", second], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.server.records, [])
        self.assertNotIn(TOKEN, (root / "argv.log").read_text())
        self.assertNotIn(TOKEN, r.stdout + r.stderr)
        self.server.calls = []
        broken = script.replace("printf '%s' \"$2\" >\"$HOOK_ROOT/$1\";", "return 1;")
        r = subprocess.run(["sh", "-c", broken + f'dns_clash_agent_cf_add _acme-challenge.node.example.com {"R" * 43}'], env=env, capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.server.calls, [])
        # Official acme.sh can mask _save_conf failure with successful old-key
        # cleanup. A success return alone does not prove paths were persisted.
        (root / "CLASH_CF_INSTALLER").unlink()
        (root / "CLASH_CF_STATE_DIR").unlink()
        masked = script.replace("printf '%s' \"$2\" >\"$HOOK_ROOT/$1\";", "return 0;")
        command = f'CLASH_CF_INSTALLER="{runtime}" CLASH_CF_STATE_DIR="$HOOK_ROOT" dns_clash_agent_cf_add _acme-challenge.node.example.com {"S" * 43}'
        r = subprocess.run(["sh", "-c", masked + command], env=env, capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.server.calls, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
