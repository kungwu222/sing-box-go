import json
from pathlib import Path
import tempfile
import unittest

from shell_helpers import run_bash, shell_path


class HoppingSyncTests(unittest.TestCase):
    def sync(self, new_port, fail=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "conf").mkdir()
            (root / "units").mkdir()
            script = b"#!/bin/bash\nSTART=60000; END=64000; TO=8443\niptables -t nat -A PREROUTING -p udp --dport $START:$END -j REDIRECT --to-ports $TO\n"
            (root / "hy2-hopping.sh").write_bytes(script)
            (root / "units" / "sb-porthopping.service").write_bytes(b"old unit")
            (root / "nodes.txt").write_bytes(b"old nodes")
            client = root / "hy2-client.json"
            client.write_bytes(json.dumps({"outbounds": [{"type": "hysteria2", "password": "old", "server_ports": ["60000:64000"]}]}).encode())
            metadata = {"server_ip": "192.0.2.10", "nodes": [{"protocol": "hy2", "port": 8443, "password": "old", "client_config": shell_path(client), "hopping": {"enabled": True, "range": "60000-64000"}}], "protocols": ["hy2"]}
            (root / "deploy-result.json").write_bytes(json.dumps(metadata).encode())
            if new_port:
                (root / "conf" / "hy2.json").write_bytes(json.dumps({"inbounds": [{"type": "hysteria2", "tag": "hy2 node", "listen_port": new_port, "users": [{"password": "new-password"}]}]}).encode())
            before = {p.relative_to(root).as_posix(): p.read_bytes() for p in root.rglob("*") if p.is_file()}
            result = run_bash(r'''
apply_defaults; SB_DIR="$WORK"; CONF_DIR="$WORK/conf"; SYSTEMD_DIR="$WORK/units"
OPEN_FIREWALL=false
systemctl() { :; }
iptables() { [[ "$FAIL_SYNC" == true && "$*" == *'--to-ports 23456'* ]] && return 1; return 0; }
ip6tables() { :; }
export -f iptables ip6tables
if declare -F cmd_sync_hopping >/dev/null; then cmd_sync_hopping 8443 "$NEW_PORT"; else exit 0; fi
''', env={"WORK": shell_path(root), "NEW_PORT": str(new_port), "FAIL_SYNC": str(fail).lower(), "TMPDIR": shell_path(root)})
            after = {p.relative_to(root).as_posix(): p.read_bytes() for p in root.rglob("*") if p.is_file()}
            return result, before, after

    def test_sync_updates_target_metadata_and_client_credentials(self):
        result, _, files = self.sync(23456)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"TO=23456", files["hy2-hopping.sh"])
        metadata = json.loads(files["deploy-result.json"])
        self.assertEqual(metadata["nodes"][0]["port"], 23456)
        self.assertEqual(metadata["nodes"][0]["password"], "new-password")
        self.assertEqual(json.loads(files["hy2-client.json"])["outbounds"][0]["password"], "new-password")

    def test_sync_deletion_removes_rules_artifacts_and_metadata(self):
        result, _, files = self.sync(0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("hy2-hopping.sh", files)
        self.assertNotIn("units/sb-porthopping.service", files)
        self.assertNotIn("hy2-client.json", files)
        self.assertEqual(json.loads(files["deploy-result.json"])["nodes"], [])

    def test_failed_sync_restores_original_hopping_files(self):
        result, before, after = self.sync(23456, fail=True)
        self.assertNotEqual(result.returncode, 0)
        for name in ("hy2-hopping.sh", "units/sb-porthopping.service", "deploy-result.json", "hy2-client.json", "nodes.txt"):
            self.assertEqual(after[name], before[name], name)
