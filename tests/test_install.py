import json
import os
from pathlib import Path
import tempfile
import unittest

from shell_helpers import run_bash, shell_path


class ArgumentTests(unittest.TestCase):
    def wrapper(self, args, name="install.sh", invalid_checksum=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake = root / "fake-deploy.sh"
            fake.write_bytes(b'#!/bin/bash\nprintf "%s\\n" "$@" > "$ARG_FILE"\n')
            os.chmod(fake, 0o755)
            result = run_bash("", source=name, args=args,
                              env={"WORK": shell_path(root), "FAKE_DEPLOY": shell_path(fake),
                                   "ARG_FILE": shell_path(root / "args.txt"), "BAD_CHECKSUM": str(invalid_checksum).lower()},
                              replacements={'TARGET="/root/auto-deploy.sh"': 'TARGET="$WORK/auto-deploy.sh"'},
                              prelude=r'''
curl() {
    local out="" url=""
    while [[ $# -gt 0 ]]; do
        [[ "$1" == -o ]] && { out="$2"; shift 2; continue; }
        [[ "$1" != https://* ]] || url="$1"
        shift
    done
    if [[ "$url" == *.sha256* ]]; then
        local digest
        digest=$(sha256sum "$FAKE_DEPLOY" | awk '{print $1}')
        [[ "$BAD_CHECKSUM" != true ]] || digest=$(printf '%064d' 0)
        printf '%s  auto-deploy.sh\n' "$digest" > "$out"
    else cp "$FAKE_DEPLOY" "$out"; fi
}
''')
            captured = root / "args.txt"
            return result, captured.read_text().splitlines() if captured.exists() else []

    def test_wrapper_preserves_protocol_option_value(self):
        result, args = self.wrapper(["--protocols", "hy2"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(args[-2:], ["--protocols", "hy2"])

    def test_wrapper_preserves_protocol_named_option_values(self):
        result, args = self.wrapper(["anytls", "--name", "reality", "--password", "default"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(args[-4:], ["--name", "reality", "--password", "default"])
        self.assertEqual(args[:2], ["--protocols", "anytls"])

    def test_wrapper_does_not_echo_supplied_password(self):
        result, _ = self.wrapper(["--password", "private-test-value"])
        self.assertNotIn("private-test-value", result.stdout + result.stderr)

    def test_backup_wrapper_does_not_echo_supplied_password(self):
        result, _ = self.wrapper(["--password", "private-test-value"], name="installbak.sh")
        self.assertNotIn("private-test-value", result.stdout + result.stderr)

    def test_missing_string_option_value_is_rejected(self):
        result = run_bash('apply_defaults; parse_args --name; printf "%s" "$NODE_NAME"')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("value", result.stderr.lower())

    def test_boolean_shorthand_and_explicit_empty_values(self):
        result = run_bash(r'''apply_defaults; parse_args --dry-run --protocols= --force=false
printf '%s|%s|%s' "$DRY_RUN" "$PROTOCOLS" "$FORCE"''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "true||false")

    def test_corrupt_bootstrap_is_not_executed(self):
        result, args = self.wrapper([], invalid_checksum=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(args, [])

    def test_boolean_shorthand_does_not_consume_named_protocol(self):
        result, args = self.wrapper(["--dry-run", "hy2"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(args[:2], ["--protocols", "hy2"])
        self.assertEqual(args[-1], "--dry-run")

    def test_invalid_dry_run_value_is_rejected(self):
        result = run_bash('apply_defaults; parse_args --dry-run=hy2')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("boolean", result.stderr.lower())

    def test_invalid_dry_run_environment_is_rejected(self):
        result = run_bash('apply_defaults; parse_args', env={"DRY_RUN": "hy2"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("boolean", result.stderr.lower())

    def test_explicit_empty_string_argument_is_preserved(self):
        result = run_bash('apply_defaults; parse_args --protocols ""; printf "VALUE:%s" "$PROTOCOLS"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "VALUE:")


CORE = b'''#!/bin/bash
# CORE_MARKER
case "$1 $2" in
    "version "*) echo 'sing-box version 1.14.3' ;;
    "generate uuid") echo 11111111-2222-4333-8444-555555555555 ;;
    "generate rand") echo YWFhYWFhYWFhYWFhYWFhYQ== ;;
    "generate reality-keypair") printf 'PrivateKey: new-private\nPublicKey: new-public\n' ;;
    "check "*) [[ "$FAIL_VALIDATE" == true ]] && { echo 'invalid configuration' >&2; exit 1; } ;;
esac
exit 0
'''


FLOW = r'''
apply_defaults
SB_DIR="$WORK/installed"; SB_BIN="$SB_DIR/bin/sing-box"; CONF_DIR="$SB_DIR/conf"
SH_DIR="$SB_DIR/sh"; LOG_DIR="$WORK/logs"; SYSTEMD_DIR="$WORK/units"
INSTALL_MGMT=false; ENABLE_BBR=false; OPEN_FIREWALL=false
SERVER_IP=192.0.2.10; UUID=11111111-2222-4333-8444-555555555555
preflight() { PKG_MGR=apt-get; ARCH=amd64; }
install_deps() { :; }
dl_init() { :; }
resolve_version() { SB_VERSION=v1.14.3; }
download_binary() { STAGE_BIN="$WORK/new-core"; }
install_sbgo_shortcut() { :; }
timedatectl() { :; }
sleep() { :; }
ss() { :; }
systemctl() {
    printf '%s\n' "$*" >> "$WORK/service-commands"
    case "$1" in
        show) echo 333 ;;
        is-active) [[ $(cat "$WORK/active") == true ]] ;;
        is-enabled) [[ $(cat "$WORK/enabled") == true ]] ;;
        stop) echo false > "$WORK/active" ;;
        start|restart)
            if [[ "$FAIL_START" == true ]] && grep -q new-binary "$SB_BIN"; then
                echo false > "$WORK/active"; return 1
            fi
            echo true > "$WORK/active" ;;
        enable) echo true > "$WORK/enabled" ;;
        disable)
            [[ -f "$SYSTEMD_DIR/sing-box.service" ]] || return 1
            echo false > "$WORK/enabled" ;;
    esac
}
openssl() {
    local cert="" key=""
    while [[ $# -gt 0 ]]; do
        case "$1" in -keyout) key="$2"; shift ;; -out) cert="$2"; shift ;; esac
        shift
    done
    printf 'new-key' > "$key"; printf 'new-cert' > "$cert"
}
cp() {
    local arg
    if [[ "$FAIL_COPY" == true ]]; then
        for arg in "$@"; do [[ "$arg" == "$BUILD_BASE" ]] && return 1; done
    fi
    command cp "$@"
}
if [[ "$FAIL_HOP_CLEANUP" == true ]]; then cleanup_hopping() { return 1; }; fi
'''


class ReplacementTests(unittest.TestCase):
    def flow(self, *, fail_validate=False, fail_start=False, fail_copy=False,
             dry=False, existing=True, protocols="reality", fail_hopping_cleanup=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            units = root / "units"
            units.mkdir()
            (root / "active").write_text("true" if existing else "false")
            (root / "enabled").write_text("true" if existing else "false")
            (root / "new-core").write_bytes(CORE.replace(b"CORE_MARKER", b"new-binary"))
            os.chmod(root / "new-core", 0o755)
            installed = root / "installed"
            if existing:
                (installed / "bin").mkdir(parents=True)
                (installed / "conf").mkdir()
                (installed / "conf" / "old.json").write_text('{"inbounds":[{"tag":"old","type":"vless"}]}')
                (installed / "config.json").write_text('{"outbounds":[{"type":"direct"}]}')
                (installed / "bin" / "tls.cer").write_text("old-cert")
                (installed / "bin" / "tls.key").write_text("old-key")
                (installed / "bin" / "sing-box").write_bytes(CORE.replace(b"CORE_MARKER", b"old-binary"))
                os.chmod(installed / "bin" / "sing-box", 0o755)
                (units / "sing-box.service").write_text("old-unit")
            before = self.files(installed)
            result = run_bash(FLOW + '\ndeploy_flow ' + ('--dry-run' if dry else ''),
                              env={"WORK": shell_path(root), "TMPDIR": shell_path(root),
                                   "PROTOCOLS": protocols, "FAIL_VALIDATE": str(fail_validate).lower(),
                                   "FAIL_START": str(fail_start).lower(), "FAIL_COPY": str(fail_copy).lower(),
                                   "FAIL_HOP_CLEANUP": str(fail_hopping_cleanup).lower()},
                              replacements={"/lib/systemd/system": shell_path(units),
                                            "/tmp/sb-check.log": shell_path(root / "global-check.log")},
                              timeout=30)
            return {"result": result, "before": before, "after": self.files(installed),
                    "active": (root / "active").read_text().strip(),
                    "enabled": (root / "enabled").read_text().strip(),
                    "units": self.files(units), "installed_exists": installed.exists(),
                    "global_log": (root / "global-check.log").exists()}

    @staticmethod
    def files(root):
        return {p.relative_to(root).as_posix(): p.read_bytes()
                for p in root.rglob("*") if p.is_file()}

    def test_invalid_staged_config_does_not_modify_live_tls(self):
        outcome = self.flow(fail_validate=True)
        self.assertNotEqual(outcome["result"].returncode, 0)
        self.assertEqual(outcome["after"], outcome["before"])
        self.assertEqual(outcome["active"], "true")

    def test_failed_start_restores_installation_and_service(self):
        outcome = self.flow(fail_start=True)
        self.assertNotEqual(outcome["result"].returncode, 0)
        self.assertEqual(outcome["after"], outcome["before"])
        self.assertEqual(outcome["units"]["sing-box.service"], b"old-unit")
        self.assertEqual(outcome["active"], "true")
        self.assertEqual(outcome["enabled"], "true")

    def test_failed_copy_aborts_and_restores_installation(self):
        outcome = self.flow(fail_copy=True)
        self.assertNotEqual(outcome["result"].returncode, 0)
        self.assertEqual(outcome["after"], outcome["before"])

    def test_first_install_failure_removes_incomplete_files(self):
        outcome = self.flow(fail_start=True, existing=False)
        self.assertNotEqual(outcome["result"].returncode, 0)
        self.assertFalse(outcome["installed_exists"])
        self.assertNotIn("sing-box.service", outcome["units"])
        self.assertEqual(outcome["active"], "false")
        self.assertEqual(outcome["enabled"], "false")

    def test_successful_redeployment_removes_old_nodes(self):
        outcome = self.flow()
        self.assertEqual(outcome["result"].returncode, 0, outcome["result"].stderr)
        self.assertNotIn("conf/old.json", outcome["after"])
        self.assertIn("conf/default-reality-443.json", outcome["after"])

    def test_dry_run_uses_no_global_check_log(self):
        outcome = self.flow(dry=True)
        self.assertEqual(outcome["result"].returncode, 0, outcome["result"].stderr)
        self.assertEqual(outcome["after"], outcome["before"])
        self.assertFalse(outcome["global_log"])

    def test_core_only_replacement_handles_empty_conf_directory(self):
        outcome = self.flow(protocols="")
        self.assertEqual(outcome["result"].returncode, 0, outcome["result"].stderr)
        self.assertNotIn("conf/old.json", outcome["after"])
        self.assertNotIn("cannot stat", outcome["result"].stderr)

    def test_hopping_cleanup_failure_does_not_prevent_core_recovery(self):
        outcome = self.flow(fail_hopping_cleanup=True)
        self.assertNotEqual(outcome["result"].returncode, 0)
        self.assertEqual(outcome["after"], outcome["before"])
        self.assertEqual(outcome["active"], "true")
        self.assertEqual(outcome["enabled"], "true")


class DryRunDependencyTests(unittest.TestCase):
    def test_missing_dependency_does_not_install_packages_in_dry_run(self):
        with tempfile.TemporaryDirectory() as directory:
            result = run_bash(r'''
apply_defaults; DRY_RUN=true; PKG_MGR=apt-get
command() { [[ "$*" == '-v curl' ]] && return 1; builtin command "$@"; }
apt-get() { printf 'package installation' > "$WORK/package-side-effect"; }
install_deps
''', env={"WORK": shell_path(directory)})
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((Path(directory) / "package-side-effect").exists())
            self.assertIn("curl", result.stderr)


class HoppingLifecycleTests(unittest.TestCase):
    def test_cleanup_removes_custom_target_rule_and_preserves_unrelated_rule(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            owned = "-A PREROUTING -p udp --dport 60000:64000 -j REDIRECT --to-ports 12345"
            unrelated = "-A PREROUTING -p tcp --dport 60000:64000 -j REDIRECT --to-ports 12345"
            (root / "rules").write_bytes((owned + "\n" + unrelated + "\n").encode())
            (root / "hy2-hopping.sh").write_bytes(b"START=60000; END=64000; TO=12345\n")
            (root / "units").mkdir()
            (root / "units" / "sb-porthopping.service").write_text("old unit")
            result = run_bash(r'''
apply_defaults; SB_DIR="$WORK"; SYSTEMD_DIR="$WORK/units"
systemctl() { :; }
iptables() {
    if [[ "$*" == '-t nat -S PREROUTING' ]]; then cat "$WORK/rules"
    elif [[ "$*" == '-t nat -D PREROUTING -p udp --dport 60000:64000 -j REDIRECT --to-ports 12345' ]]; then
        grep -Fv -- '-p udp' "$WORK/rules" > "$WORK/rules.new" || true
        mv "$WORK/rules.new" "$WORK/rules"
    fi
    return 0
}
if declare -F cleanup_hopping >/dev/null; then cleanup_hopping; fi
''', env={"WORK": shell_path(root)})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root / "rules").read_text(), unrelated + "\n")
            self.assertFalse((root / "units" / "sb-porthopping.service").exists())

    def test_new_hopping_rules_use_managed_chain(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "units").mkdir()
            result = run_bash(r'''
apply_defaults; SB_DIR="$WORK"; SYSTEMD_DIR="$WORK/units"; DEPLOY_PROTOCOLS=(hy2)
iptables() { printf '%s\n' "$*" >> "$WORK/commands"; }
ip6tables() { :; }
systemctl() { :; }
export -f iptables ip6tables
setup_hopping
''', env={"WORK": shell_path(root)},
                              replacements={"/lib/systemd/system": shell_path(root / "units")})
            self.assertEqual(result.returncode, 0, result.stderr)
            commands = (root / "commands").read_text()
            self.assertIn("-N SB_HY2_HOP", commands)
            self.assertIn("-A SB_HY2_HOP -p udp --dport 60000:64000", commands)

    def test_nft_backend_creates_its_own_nat_table(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "units").mkdir()
            result = run_bash(r'''
apply_defaults; SB_DIR="$WORK"; SYSTEMD_DIR="$WORK/units"; DEPLOY_PROTOCOLS=(hy2)
command() {
    case "$*" in '-v iptables'|'-v ip6tables') return 1 ;; esac
    builtin command "$@"
}
nft() { [[ "$*" == '-f -' ]] && cat > "$WORK/nft-rules"; return 0; }
systemctl() { :; }
export -f command nft
setup_hopping
''', env={"WORK": shell_path(root)},
                              replacements={"/lib/systemd/system": shell_path(root / "units")})
            self.assertEqual(result.returncode, 0, result.stderr)
            rules = (root / "nft-rules").read_text() if (root / "nft-rules").exists() else ""
            self.assertIn("table inet sb_hy2_hop", rules)
            self.assertIn("udp dport 60000-64000 redirect to :8443", rules)


if __name__ == "__main__":
    unittest.main()
