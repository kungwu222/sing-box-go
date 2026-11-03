import hashlib
from pathlib import Path
import tarfile
import unittest

from shell_helpers import ROOT


class ShippedArtifactTests(unittest.TestCase):
    def test_shipped_management_code_matches_reviewable_source(self):
        with tarfile.open(ROOT / "mgmt-code.tar.gz") as archive:
            packaged = {member.name.removeprefix("./"): archive.extractfile(member).read()
                        for member in archive.getmembers() if member.isfile()}
        source = {path.relative_to(ROOT / "mgmt").as_posix(): path.read_bytes()
                  for path in (ROOT / "mgmt").rglob("*") if path.is_file()}
        self.assertEqual(set(packaged), set(source))
        for name, data in source.items():
            self.assertEqual(hashlib.sha256(packaged[name]).hexdigest(), hashlib.sha256(data).hexdigest(), name)

    def test_deployment_manifests_match_shipped_bytes(self):
        for name in ("auto-deploy.sh", "mgmt-code.tar.gz"):
            with self.subTest(name=name):
                manifest = ROOT / (name + ".sha256")
                self.assertTrue(manifest.is_file(), f"missing manifest: {name}")
                digest, filename = manifest.read_text().split()
                self.assertEqual(filename, name)
                self.assertEqual(digest, hashlib.sha256((ROOT / name).read_bytes()).hexdigest())
