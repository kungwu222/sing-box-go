import json
from pathlib import Path
import tempfile
import unittest

from shell_helpers import run_bash, shell_path


def tcp(port, owner='users:(("nginx",pid=999,fd=7))', address="0.0.0.0"):
    return f"LISTEN 0 4096 {address}:{port} 0.0.0.0:* {owner}\n"


def udp(port, owner='users:(("other",pid=999,fd=7))', address="0.0.0.0"):
    return f"UNCONN 0 0 {address}:{port} 0.0.0.0:* {owner}\n"


SETUP = r'''
apply_defaults
SB_DIR="$WORK/installed"; SB_BIN="$SB_DIR/bin/sing-box"; CONF_DIR="$SB_DIR/conf"
STAGE_DIR="$WORK/stage"; BUILD_CONF="$STAGE_DIR/conf"; BUILD_BASE="$STAGE_DIR/config.json"
CLIENT_OUT="$STAGE_DIR/clients"; FINAL_CLIENT_DIR="$CLIENT_OUT"
CER_PATH="$STAGE_DIR/tls.cer"; KEY_PATH="$STAGE_DIR/tls.key"
mkdir -p "$BUILD_CONF" "$CLIENT_OUT" "$CONF_DIR"
printf 'old node' > "$CONF_DIR/old.json"
SERVER_IP=192.0.2.10; UUID=11111111-2222-4333-8444-555555555555
PASSWORD=testpass; HY2_PASSWORD=testpass; ANYTLS_PASSWORD=testpass
TUIC_PASSWORD=testpass; TROJAN_PASSWORD=testpass; SOCKS_USER=test; SOCKS_PASS=testpass
SS_PASSWORD=YWFhYWFhYWFhYWFhYWFhYQ==
REALITY_PRI=private; REALITY_PUB=public
DIRECT_PORT=18888; DIRECT_ADDR=192.0.2.20; DIRECT_RPORT=80
ss() {
    [[ "$FAIL_INSPECTION" == true ]] && return 1
    if [[ "$*" == *t* ]]; then printf '%s' "$TCP_FIXTURE";
    else printf '%s' "$UDP_FIXTURE"; fi
}
systemctl() { [[ "$1" == show ]] && printf '%s\n' 333; return 0; }
readlink() {
    if [[ "$*" == */proc/333/exe* ]]; then
        [[ "$OWN_EXECUTABLE" == true ]] && printf '%s\n' "$SB_BIN" || printf '/usr/bin/other\n'
    else command readlink "$@"; fi
}
if [[ "$NETSTAT_ONLY" == true ]]; then
    command() {
        [[ "$*" == '-v ss' ]] && return 1
        [[ "$*" == '-v fuser' && "$FUSER_AVAILABLE" == false ]] && return 1
        builtin command "$@"
    }
    netstat() {
        printf '%s' "$TCP_FIXTURE"
        if [[ "$*" == *a* ]]; then printf '%s' "$UDP_FIXTURE"
        else printf '%s' "$UDP_FIXTURE" | awk '!/ESTABLISHED/'; fi
    }
    fuser() { printf '%s\n' "$FUSER_PIDS"; }
    id() { printf '0\n'; }
fi
'''


class PortSelectionTests(unittest.TestCase):
    def deploy(self, protocols, tcp_rows="", udp_rows="", extra="", own=True, fail=False,
               netstat=False, fuser_pids="333", fuser_available=True):
        with tempfile.TemporaryDirectory() as directory:
            body = SETUP + '\n' + extra + r'''
deploy_protocols || exit $?
write_outputs "$STAGE_DIR" || exit $?
'''
            result = run_bash(body, env={"WORK": shell_path(directory), "PROTOCOLS": protocols,
                                        "TCP_FIXTURE": tcp_rows, "UDP_FIXTURE": udp_rows,
                                        "OWN_EXECUTABLE": "true" if own else "false",
                                        "FAIL_INSPECTION": "true" if fail else "false",
                                        "NETSTAT_ONLY": str(netstat).lower(), "FUSER_PIDS": fuser_pids,
                                        "FUSER_AVAILABLE": str(fuser_available).lower()})
            output = Path(directory) / "stage" / "deploy-result.json"
            data = json.loads(output.read_text()) if output.exists() else None
            old_node = (Path(directory) / "installed" / "conf" / "old.json").read_text()
            return result, data, old_node

    # Missing TCP conflict checks would generate the foreign service's inbound.
    def test_foreign_tcp_port_skips_only_affected_protocol(self):
        result, data, _ = self.deploy("reality,anytls", tcp_rows=tcp(443))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(data["protocols"], ["anytls"])
        self.assertEqual(data["skipped"][0]["protocol"], "reality")
        self.assertIn("tcp 443", result.stderr)
        self.assertIn("nginx", result.stderr)

    def test_ipv6_tcp_listener_is_occupied(self):
        _, data, _ = self.deploy("reality,anytls", tcp_rows=tcp(443, address="[::]"))
        self.assertEqual(data["protocols"], ["anytls"])

    def test_foreign_udp_port_skips_hy2(self):
        _, data, _ = self.deploy("hy2,anytls", udp_rows=udp(8443))
        self.assertEqual(data["protocols"], ["anytls"])

    def test_unknown_socket_owner_is_not_assumed_available(self):
        _, data, _ = self.deploy("reality,anytls", tcp_rows=tcp(443, owner=""))
        self.assertEqual(data["protocols"], ["anytls"])

    def test_current_managed_sing_box_port_can_be_replaced(self):
        result, data, _ = self.deploy("reality", tcp_rows=tcp(443, 'users:(("sing-box",pid=333,fd=7))'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(data["protocols"], ["reality"])

    def test_sing_box_named_foreign_process_is_not_exempt(self):
        _, data, _ = self.deploy("reality,anytls", tcp_rows=tcp(443, 'users:(("sing-box",pid=999,fd=7))'))
        self.assertEqual(data["protocols"], ["anytls"])

    def test_pid_with_wrong_executable_is_not_exempt(self):
        _, data, _ = self.deploy("reality,anytls", tcp_rows=tcp(443, 'users:(("sing-box",pid=333,fd=7))'), own=False)
        self.assertEqual(data["protocols"], ["anytls"])

    def test_mixed_socket_owners_are_occupied(self):
        rows = tcp(443, 'users:(("sing-box",pid=333,fd=7),("other",pid=999,fd=8))')
        _, data, _ = self.deploy("reality,anytls", tcp_rows=rows)
        self.assertEqual(data["protocols"], ["anytls"])

    def test_same_port_number_on_different_transports_is_available(self):
        result, data, _ = self.deploy("reality,hy2", extra="HY2_PORT=443; HY2_HOPPING=false")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(data["protocols"], ["reality", "hy2"])

    def test_selected_protocol_collision_uses_first_selection(self):
        _, data, _ = self.deploy("reality,anytls", extra="ANYTLS_PORT=443")
        self.assertEqual(data["protocols"], ["reality"])
        self.assertEqual(data["skipped"][0]["protocol"], "anytls")

    def test_repeated_aliases_create_one_node(self):
        _, data, _ = self.deploy("hy2,hysteria2,HY2")
        self.assertEqual(data["protocols"], ["hy2"])

    def test_udp_hopping_range_conflict_skips_hy2(self):
        _, data, _ = self.deploy("hysteria2,anytls", udp_rows=udp(61001, address="[::]"))
        self.assertEqual(data["protocols"], ["anytls"])
        self.assertIn("60000-64000", data["skipped"][0]["reason"])

    def test_shadowsocks_checks_both_transports(self):
        _, data, _ = self.deploy("ss,anytls", udp_rows=udp(8388))
        self.assertEqual(data["protocols"], ["anytls"])

    def test_direct_forwarding_checks_udp(self):
        _, data, _ = self.deploy("direct,anytls", udp_rows=udp(18888))
        self.assertEqual(data["protocols"], ["anytls"])

    def test_skipped_protocol_leaves_no_port_reservation(self):
        _, data, _ = self.deploy("ss,reality", udp_rows=udp(8388), extra="REALITY_PORT=8388")
        self.assertEqual(data["protocols"], ["reality"])

    def test_all_skipped_fails_and_preserves_old_node(self):
        result, data, old_node = self.deploy("reality", tcp_rows=tcp(443))
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(data)
        self.assertEqual(old_node, "old node")
        self.assertIn("no nodes", result.stderr.lower())

    def test_inspection_failure_does_not_assume_free_ports(self):
        result, data, _ = self.deploy("reality", fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(data)
        self.assertIn("inspect", result.stderr.lower())

    def test_empty_selection_still_allows_core_only(self):
        result, data, _ = self.deploy("")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(data["protocols"], [])

    def test_invalid_port_is_rejected_before_generation(self):
        result, data, _ = self.deploy("reality", extra="REALITY_PORT=65536")
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(data)

    def test_netstat_checks_connected_bound_udp_ports(self):
        rows = "udp 0 0 0.0.0.0:61001 198.51.100.1:53 ESTABLISHED 999/other\n"
        _, data, _ = self.deploy("hy2,anytls", udp_rows=rows, netstat=True)
        self.assertEqual(data["protocols"], ["anytls"])

    def test_netstat_managed_exemption_checks_all_owners(self):
        rows = "tcp 0 0 0.0.0.0:443 0.0.0.0:* LISTEN 333/sing-box\n"
        _, data, _ = self.deploy("reality,anytls", tcp_rows=rows, netstat=True, fuser_pids="333 999")
        self.assertEqual(data["protocols"], ["anytls"])

    def test_netstat_can_confirm_sole_managed_owner(self):
        rows = "tcp 0 0 0.0.0.0:443 0.0.0.0:* LISTEN 333/sing-box\n"
        _, data, _ = self.deploy("reality", tcp_rows=rows, netstat=True)
        self.assertEqual(data["protocols"], ["reality"])

    def test_netstat_without_all_owner_inventory_is_conservative(self):
        rows = "tcp 0 0 0.0.0.0:443 0.0.0.0:* LISTEN 333/sing-box\n"
        _, data, _ = self.deploy("reality,anytls", tcp_rows=rows, netstat=True, fuser_available=False)
        self.assertEqual(data["protocols"], ["anytls"])


if __name__ == "__main__":
    unittest.main()
