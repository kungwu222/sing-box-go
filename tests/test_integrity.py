import hashlib
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest

from shell_helpers import ROOT, run_bash, shell_path


def make_tar(path, files, link=False):
    with tarfile.open(path, "w:gz") as archive:
        for name, data in files.items():
            info = tarfile.TarInfo(name)
            info.mode = 0o755
            if link:
                info.type = tarfile.SYMTYPE
                info.linkname = "/etc/profile"
                archive.addfile(info)
            else:
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))


class DownloadIntegrityTests(unittest.TestCase):
    def core_download(self, bad=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            make_tar(root / "fixture.tar.gz", {"sing-box-1.14.3-linux-amd64/sing-box": b"#!/bin/bash\nexit 0\n"})
            digest = hashlib.sha256((root / "fixture.tar.gz").read_bytes()).hexdigest()
            metadata = {"assets": [{"name": "sing-box-1.14.3-linux-amd64.tar.gz", "digest": "sha256:" + ("0" * 64 if bad else digest)}]}
            (root / "release.json").write_bytes(json.dumps(metadata).encode())
            result = run_bash(r'''
apply_defaults; SB_VERSION=v1.14.3; ARCH=amd64; STAGE_DIR="$WORK/stage"; SB_BIN="$WORK/not-installed"
mkdir -p "$STAGE_DIR"
dl() { [[ "$1" == *api.github.com* ]] && cp "$WORK/release.json" "$2" || cp "$WORK/fixture.tar.gz" "$2"; }
download_binary
''', env={"WORK": shell_path(root)})
            return result, (root / "stage" / "pkg" / "sing-box").exists()

    def test_release_digest_mismatch_is_rejected_before_extraction(self):
        result, binary = self.core_download(bad=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(binary)
        self.assertIn("checksum", result.stderr.lower())

    def test_matching_published_digest_allows_core_staging(self):
        result, binary = self.core_download()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(binary)

    def test_archive_traversal_and_links_are_rejected(self):
        for link in (False, True):
            with self.subTest(link=link), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "unsafe.tar.gz"
                make_tar(path, {"../escape.sh" if not link else "./src/core.sh": b"x"}, link=link)
                result = run_bash(r'''
if declare -F validate_archive >/dev/null; then validate_archive "$ARCHIVE"; else exit 0; fi
''', env={"ARCHIVE": shell_path(path)})
                self.assertNotEqual(result.returncode, 0)

    def test_bundle_digest_mismatch_preserves_installed_manager(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            make_tar(root / "fixture.tar.gz", {"./sing-box.sh": b"#!/bin/bash\nexit 0\n", "./src/core.sh": b"#!/bin/bash\n"})
            (root / "sh").mkdir()
            (root / "bin").mkdir()
            (root / "sh" / "sing-box.sh").write_bytes(b"old manager")
            result = run_bash(r'''
apply_defaults; INSTALL_MGMT=true; STAGE_DIR="$WORK"; SH_DIR="$WORK/sh"; SB_DIR="$WORK"
qrencode() { :; }
dl() {
    if [[ "$1" == *.sha256* ]]; then printf '%064d  mgmt-code.tar.gz\n' 0 > "$2"
    else cp "$WORK/fixture.tar.gz" "$2"; fi
}
install_mgmt_script
''', env={"WORK": shell_path(root)}, replacements={"/usr/local/bin": shell_path(root / "bin"), "/root/.bashrc": shell_path(root / "bashrc")})
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((root / "sh" / "sing-box.sh").read_bytes(), b"old manager")

    def test_static_jq_fallback_is_verified_before_global_install(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "stage").mkdir()
            (root / "bin").mkdir()
            result = run_bash(r'''
apply_defaults; PKG_MGR=apt-get; ARCH=amd64; STAGE_DIR="$WORK/stage"
command() { [[ "$*" == '-v jq' ]] && return 1; builtin command "$@"; }
apt-get() { return 1; }
dl() { printf 'corrupt executable' > "$2"; }
install_deps
''', env={"WORK": shell_path(root)}, replacements={"/usr/local/bin/jq": shell_path(root / "bin" / "jq")})
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / "bin" / "jq").exists())

    def test_http_proxy_hostname_is_not_misclassified_as_mirror(self):
        result = run_bash(r'''
unset https_proxy http_proxy
DOWNLOAD_PROXY=http://proxy.example:8080
dl_init
printf 'RESULT:%s|%s' "$DL_PREFIX" "${https_proxy:-}"
''')
        self.assertIn("RESULT:|http://proxy.example:8080", result.stdout)


class ClientValidationTests(unittest.TestCase):
    def test_generated_client_is_checked_in_addition_to_server(self):
        with tempfile.TemporaryDirectory() as directory:
            result = run_bash(r'''
STAGE_DIR="$WORK"; BUILD_BASE="$WORK/base.json"; BUILD_CONF="$WORK/conf"; CLIENT_OUT="$WORK/clients"
mkdir -p "$BUILD_CONF" "$CLIENT_OUT"
printf '{}' > "$BUILD_BASE"; printf '{}' > "$CLIENT_OUT/hy2.json"
fake_core() { [[ "$*" == *clients* ]] && { echo 'invalid client' >&2; return 1; }; return 0; }
STAGE_BIN=fake_core
validate_config
''', env={"WORK": shell_path(directory)})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("client", result.stderr.lower())

    def test_inverted_hopping_bounds_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            result = run_bash(r'''
STAGE_DIR="$WORK"; BUILD_BASE="$WORK/base.json"; BUILD_CONF="$WORK/conf"; CLIENT_OUT="$WORK/clients"
mkdir -p "$BUILD_CONF" "$CLIENT_OUT"
printf '{}' > "$BUILD_BASE"
printf '{"outbounds":[{"type":"hysteria2","hop_interval":"30s","hop_interval_max":"4s"}]}' > "$CLIENT_OUT/hy2.json"
fake_core() { return 0; }; STAGE_BIN=fake_core
validate_config
''', env={"WORK": shell_path(directory)})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("interval", result.stderr.lower())


class VendoredUpdateTests(unittest.TestCase):
    def test_script_update_uses_vendored_installer(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "sh").mkdir()
            result = run_bash(r'''
is_core=sing-box; is_core_name=sing-box; is_core_ver=1.14.3; is_sh_ver=v1.13
is_sh_dir="$WORK/sh"; is_sh_bin="$WORK/bin"; is_sh_repo=ooplastone22/sing-box
load() { source "$SOURCE/src/$1"; }
msg() { printf '%s\n' "$*"; }; _green() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; exit 1; }
_wget() { printf 'NETWORK\n' >> "$WORK/network"; echo '{"tag_name":"v1.99"}'; }
sbgo() { printf 'VENDORED_UPDATE:%s\n' "$*"; }
main update sh
''', source="mgmt/src/core.sh", env={"WORK": shell_path(root), "TMPDIR": shell_path(root), "SOURCE": shell_path(ROOT / "mgmt")})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("VENDORED_UPDATE:install-mgmt", result.stdout)
            self.assertFalse((root / "network").exists())


class StandaloneUpdateTests(unittest.TestCase):
    def update(self, bad=False, fail_start=False, fail_late=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "installed" / "bin").mkdir(parents=True)
            (root / "installed" / "conf").mkdir()
            target = root / "installed" / "bin" / "sing-box"
            target.write_bytes(b"old binary")
            (root / "installed" / "config.json").write_bytes(b"{}")
            make_tar(root / "fixture.tar.gz", {"pkg/sing-box": b"#!/bin/bash\n# new binary\nexit 0\n"})
            digest = hashlib.sha256((root / "fixture.tar.gz").read_bytes()).hexdigest()
            (root / "metadata.json").write_bytes(json.dumps({"assets": [{"name": "sing-box-1.14.3-linux-amd64.tar.gz", "digest": "sha256:" + ("0" * 64 if bad else digest)}]}).encode())
            result = run_bash(r'''
is_core=sing-box; is_core_name=sing-box; is_arch=amd64; is_core_repo=SagerNet/sing-box
is_core_dir="$WORK/installed"; is_core_bin="$is_core_dir/bin/sing-box"
is_config_json="$is_core_dir/config.json"; is_conf_dir="$is_core_dir/conf"
load() { source "$SOURCE/src/$1"; }
sleep() { printf 'tick\n' >> "$WORK/time"; }
err() { echo "$*" >&2; exit 1; }
_wget() {
    if [[ "$*" == *api.github.com* ]]; then cat "$WORK/metadata.json"; return 0; fi
    while [[ $# -gt 0 ]]; do [[ "$1" == -O ]] && { cp "$WORK/fixture.tar.gz" "$2"; return $?; }; shift; done
    return 1
}
systemctl() {
    if [[ "$1" == restart && "$FAIL_START" == true ]] && grep -q 'new binary' "$is_core_bin"; then return 1; fi
    local ticks=0
    [[ ! -f "$WORK/time" ]] || ticks=$(wc -l < "$WORK/time")
    if [[ "$1" == is-active && "$FAIL_LATE" == true ]] && grep -q 'new binary' "$is_core_bin" && (( ticks >= 2 )); then return 1; fi
    return 0
}
download core v1.14.3
''', source="mgmt/src/download.sh", env={"WORK": shell_path(root), "TMPDIR": shell_path(root), "FAIL_START": str(fail_start).lower(),
                                         "FAIL_LATE": str(fail_late).lower(), "SOURCE": shell_path(ROOT / "mgmt")})
            return result, target.read_bytes()

    def test_update_checksum_mismatch_preserves_previous_binary(self):
        result, binary = self.update(bad=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(binary, b"old binary")

    def test_update_activation_failure_restores_previous_binary(self):
        result, binary = self.update(fail_start=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(binary, b"old binary")

    def test_delayed_update_startup_failure_restores_binary(self):
        result, binary = self.update(fail_late=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(binary, b"old binary")
