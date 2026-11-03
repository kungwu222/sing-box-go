import os
from pathlib import Path
import tempfile
import unittest

from shell_helpers import run_bash, shell_path


class ReportingTests(unittest.TestCase):
    def test_failed_firewall_rule_is_not_reported_as_open(self):
        result = run_bash('iptables() { return 1; }; fw_allow tcp 443')
        self.assertNotEqual(result.returncode, 0)

    def test_failed_sysctl_is_reported_without_claiming_bbr_enabled(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "sysctl.conf"
            config.write_bytes(b"# existing settings\n")
            result = run_bash('ENABLE_BBR=true; uname() { echo 6.1.0; }; sysctl() { return 1; }; enable_bbr',
                              replacements={"/etc/sysctl.conf": shell_path(config)})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("BBR enabled", result.stdout)
            self.assertIn("BBR", result.stderr)

    def test_existing_version_is_read_from_first_line(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            core = root / "core"
            core.write_bytes(b"#!/bin/bash\nprintf 'sing-box version 1.14.3\\nEnvironment: go1.26 linux/amd64\\n'\n")
            os.chmod(core, 0o755)
            result = run_bash(r'''
apply_defaults; SB_VERSION=v1.14.3; SB_BIN="$WORK/core"
dl() { printf 'unexpected download' > "$WORK/network"; return 1; }
download_binary
''', env={"WORK": shell_path(root)})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((root / "network").exists())
