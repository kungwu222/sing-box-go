import json
import base64
import os
from pathlib import Path
import subprocess
import re
import tempfile
import unittest

from shell_helpers import ROOT, run_bash, shell_path, script_functions


SETUP = r'''
is_core=sing-box; is_core_name=sing-box; is_core_ver=1.14.3
is_core_dir="$WORK/installed"; is_core_bin="$WORK/core"
is_conf_dir="$is_core_dir/conf"; is_config_json="$is_core_dir/config.json"
is_log_dir="$WORK/logs"; is_tls_cer="$is_core_dir/bin/tls.cer"; is_tls_key="$is_core_dir/bin/tls.key"
ip=192.0.2.10; is_node_name=default
err() { printf '[ERR] %s\n' "$*" >&2; exit 1; }
warn() { printf '%s\n' "$*" >&2; }
_green() { printf '%s\n' "$*"; }
_yellow() { printf '%s\n' "$*"; }
_red() { printf '%s\n' "$*"; }
_red_bg() { printf '%s\n' "$*"; }
get_uuid() { tmp_uuid=11111111-2222-4333-8444-555555555555; }
is_port_used() { return 1; }
systemctl() {
    case "$1" in
        is-active) return 0 ;;
        restart)
            if [[ "$FAIL_START" == true ]] && grep -q new-password "$is_conf_dir/"*.json; then return 1; fi ;;
    esac
    return 0
}
load() { source "$SOURCE/src/$1"; }
sleep() { :; }
'''


CORE = b'''#!/bin/bash
if [[ "$1" == check ]]; then
    [[ "$CHECK_INVALID" == true ]] && exit 1
    if [[ "$CHECK_BAD_KEY" == true ]]; then
        for file in "$@"; do [[ -f "$file" ]] && grep -q bad-key "$file" && exit 1; done
    fi
else
    printf 'ARG:%s\n' "$@"
fi
exit 0
'''


class ManagementTests(unittest.TestCase):
    def run_manager(self, command, node=None, *, invalid=False, fail_start=False, bad_key=False, timeout=15):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            installed = root / "installed"
            (installed / "conf").mkdir(parents=True)
            (installed / "bin").mkdir()
            (root / "logs").mkdir()
            (root / "logs" / "access.log").write_bytes(b"old log")
            (installed / "config.json").write_bytes(b'{"log":{"level":"info"},"dns":{},"outbounds":[{"type":"direct"}]}')
            if node:
                (installed / "conf" / "node.json").write_bytes(json.dumps({"inbounds": [node]}).encode())
            (installed / "bin" / "tls.cer").write_bytes(b"certificate")
            (installed / "bin" / "tls.key").write_bytes(b"key")
            (root / "core").write_bytes(CORE)
            os.chmod(root / "core", 0o755)
            before = {p.relative_to(installed).as_posix(): p.read_bytes()
                      for p in installed.rglob("*") if p.is_file()}
            result = run_bash(SETUP + "\n" + command, source="mgmt/src/core.sh",
                              env={"WORK": shell_path(root), "SOURCE": shell_path(ROOT / "mgmt"),
                                   "CHECK_INVALID": str(invalid).lower(), "FAIL_START": str(fail_start).lower(),
                                   "CHECK_BAD_KEY": str(bad_key).lower()}, timeout=timeout)
            files = {p.relative_to(installed).as_posix(): p.read_bytes()
                     for p in installed.rglob("*") if p.is_file()}
            nodes = [json.loads(data)["inbounds"][0] for name, data in files.items()
                     if name.startswith("conf/") and name.endswith(".json") and data.strip()]
            return result, nodes, files, before

    @staticmethod
    def node(protocol="anytls", password="old-password"):
        user = {"uuid": "11111111-2222-4333-8444-555555555555"} if protocol in {"vless", "vmess"} else {"password": password}
        return {"tag": "existing-node", "type": protocol, "listen": "::", "listen_port": 22222, "users": [user]}

    def test_anytls_creation_encodes_password_and_has_tls(self):
        result, nodes, _, _ = self.run_manager("main add anytls 23456 'a password with \"quotes\"'")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(nodes[0]["type"], "anytls")
        self.assertEqual(nodes[0]["users"][0]["password"], 'a password with "quotes"')
        self.assertTrue(nodes[0]["tls"]["enabled"])

    def test_plain_vless_creation(self):
        result, nodes, _, _ = self.run_manager("main add vlesstcp 23456 11111111-2222-4333-8444-555555555555")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(nodes[0]["type"], "vless")
        self.assertNotIn("tls", nodes[0])
        self.assertNotIn("transport", nodes[0])

    def test_vless_port_change_preserves_protocol_and_tag(self):
        result, nodes, _, _ = self.run_manager('main change node.json port 23456', node=self.node("vless"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(nodes), 1)
        self.assertEqual(nodes[0]["type"], "vless")
        self.assertEqual(nodes[0]["listen_port"], 23456)
        self.assertEqual(nodes[0]["tag"], "existing-node")

    def test_anytls_password_change_preserves_protocol(self):
        result, nodes, _, _ = self.run_manager("main change node.json password 'new-password with spaces'", node=self.node())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(nodes[0]["type"], "anytls")
        self.assertEqual(nodes[0]["users"][0]["password"], "new-password with spaces")

    def test_reader_preserves_double_slashes(self):
        result, _, _, _ = self.run_manager('get info node.json; printf "VALUE:%s" "$password"', node=self.node(password="a//b"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("VALUE:a//b", result.stdout)

    def test_reader_preserves_spaces(self):
        result, _, _, _ = self.run_manager('get info node.json; printf "VALUE:%s" "$password"', node=self.node(password="a b c"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("VALUE:a b c", result.stdout)

    def test_invalid_candidate_preserves_existing_node(self):
        result, _, files, before = self.run_manager('main change node.json port 23456', node=self.node("vless"), invalid=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(files, before)

    def test_activation_failure_restores_existing_node(self):
        result, _, files, before = self.run_manager('main change node.json password new-password', node=self.node("trojan"), fail_start=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(files, before)

    def test_invalid_log_setting_update_preserves_base(self):
        result, _, files, before = self.run_manager('main log debug', invalid=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(files["config.json"], before["config.json"])

    def test_invalid_dns_setting_update_preserves_base(self):
        result, _, files, before = self.run_manager('main dns set 1.1.1.1', invalid=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(files["config.json"], before["config.json"])

    def test_password_quotes_do_not_destroy_old_trojan_node(self):
        node = self.node("anytls")
        node["type"] = "trojan"
        result, nodes, _, _ = self.run_manager("main change node.json password 'a \"quoted\" password'", node=node)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(nodes), 1, result.stderr)
        self.assertEqual(nodes[0]["users"][0]["password"], 'a "quoted" password')

    def test_missing_name_value_is_rejected_promptly(self):
        try:
            result, _, _, _ = self.run_manager('main add hy2 23456 --name', timeout=1)
        except subprocess.TimeoutExpired:
            self.fail("missing --name must fail promptly instead of looping")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("name", result.stderr.lower())

    def test_failed_service_operation_is_not_reported_as_success(self):
        result, _, _, _ = self.run_manager('systemctl() { return 1; }; main stop')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("完成", result.stdout)

    def test_native_binary_forwarding_preserves_argument_boundaries(self):
        result, _, _, _ = self.run_manager('main bin generate rand "value with spaces"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ARG:value with spaces\n", result.stdout)

    def test_failed_generation_propagates_when_import_errors_return(self):
        result, _, _, _ = self.run_manager('err() { echo "$*" >&2; return 1; }; main add vlesstcp 23456', invalid=True)
        self.assertNotEqual(result.returncode, 0)

    def import_node(self, *, invalid=False, name="source.json"):
        source = script_functions(ROOT / "mgmt" / "src" / "import.sh")
        command = source + r'''
is_change=1; is_dont_auto_exit=1
err() { echo "$*" >&2; return 1; }
printf '{"inbounds":[{"tag":"imported node","protocol":"vless","port":23456,"settings":{"clients":[{"id":"11111111-2222-4333-8444-555555555555"}]},"streamSettings":{"network":"tcp","security":"none"}}]}' > "$WORK/SOURCE_NAME"
in_conf "$WORK/SOURCE_NAME"
status=$?
[[ ! -f "$WORK/SOURCE_NAME" ]] || echo SOURCE_RETAINED
exit "$status"
'''
        return self.run_manager(command.replace("SOURCE_NAME", name), invalid=invalid)

    def test_failed_import_preserves_source_configuration(self):
        result, nodes, _, _ = self.import_node(invalid=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SOURCE_RETAINED", result.stdout)
        self.assertEqual(nodes, [])

    def test_successful_import_preserves_protocol_and_space_named_source(self):
        result, nodes, _, _ = self.import_node(name="source with spaces.json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("SOURCE_RETAINED", result.stdout)
        self.assertEqual(len(nodes), 1)
        self.assertEqual(nodes[0]["type"], "vless")

    def test_password_alias_preserves_spaces(self):
        result, nodes, _, _ = self.run_manager('main passwd node.json "a b"', node=self.node())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(nodes[0]["users"][0]["password"], "a b")

    def test_vmess_link_encodes_quoted_tag_as_valid_json(self):
        node = self.node("vmess")
        node["tag"] = 'a "quoted" node'
        result, _, _, _ = self.run_manager('main url node.json', node=node)
        self.assertEqual(result.returncode, 0, result.stderr)
        match = re.search(r"vmess://([A-Za-z0-9+/=]+)", result.stdout)
        self.assertIsNotNone(match, result.stderr)
        data = json.loads(base64.b64decode(match.group(1)))
        self.assertEqual(data["ps"], 'a "quoted" node')

    def test_reinstall_uses_verified_bundle_without_uninstalling_nodes(self):
        result, _, files, before = self.run_manager(r'''
is_sh_dir="$WORK/legacy"; mkdir -p "$is_sh_dir"
printf 'echo LEGACY_INSTALL\n' > "$is_sh_dir/install.sh"
uninstall() { rm -f "$is_conf_dir/node.json"; }
sbgo() { printf 'VENDORED_REINSTALL:%s\n' "$*"; }
main reinstall
''', node=self.node())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(files, before)
        self.assertIn("VENDORED_REINSTALL:install-mgmt", result.stdout)

    def test_delayed_startup_failure_restores_node(self):
        result, _, files, before = self.run_manager(r'''
sleep() { printf 'tick\n' >> "$WORK/time"; }
systemctl() {
    local ticks=0
    [[ ! -f "$WORK/time" ]] || ticks=$(wc -l < "$WORK/time")
    if [[ "$1" == is-active ]] && grep -q new-password "$is_conf_dir/"*.json && (( ticks >= 2 )); then return 1; fi
    return 0
}
main change node.json password new-password
''', node=self.node())
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(files, before)

    def test_hy2_port_change_reconciles_hopping_target(self):
        result, nodes, files, _ = self.run_manager(r'''
printf 'START=60000; END=64000; TO=22222\n' > "$is_core_dir/hy2-hopping.sh"
sbgo() { printf 'START=60000; END=64000; TO=%s\n' "$3" > "$is_core_dir/hy2-hopping.sh"; }
main change node.json port 23456
''', node=self.node("hysteria2"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(nodes[0]["listen_port"], 23456)
        self.assertIn(b"TO=23456", files["hy2-hopping.sh"])

    def test_hy2_deletion_removes_its_hopping_state(self):
        result, nodes, files, _ = self.run_manager(r'''
printf 'START=60000; END=64000; TO=22222\n' > "$is_core_dir/hy2-hopping.sh"
sbgo() { rm -f "$is_core_dir/hy2-hopping.sh"; }
main del node.json
''', node=self.node("hysteria2"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(nodes, [])
        self.assertNotIn("hy2-hopping.sh", files)

    def test_hopping_reconcile_failure_restores_hy2_node(self):
        result, _, files, before = self.run_manager(r'''
printf 'START=60000; END=64000; TO=22222\n' > "$is_core_dir/hy2-hopping.sh"
sbgo() { return 1; }
main change node.json port 23456
''', node=self.node("hysteria2"))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(files["conf/node.json"], before["conf/node.json"])


if __name__ == "__main__":
    unittest.main()
