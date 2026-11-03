"""Build/check the reproducible vendored archive and deployment SHA256 manifests."""

import argparse
import gzip
import hashlib
import io
from pathlib import Path
import tarfile


ROOT = Path(__file__).resolve().parents[1]


def management_archive(root=ROOT):
    source = root / "mgmt"
    output = io.BytesIO()
    with gzip.GzipFile(fileobj=output, mode="wb", filename="", mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.GNU_FORMAT) as archive:
            for path in sorted(source.rglob("*")):
                if path.is_symlink():
                    raise ValueError(f"symlink in vendored source: {path}")
                relative = path.relative_to(source).as_posix()
                member = tarfile.TarInfo("./" + relative)
                member.uid = member.gid = member.mtime = 0
                member.uname = member.gname = ""
                if path.is_dir():
                    member.type = tarfile.DIRTYPE
                    member.mode = 0o755
                    archive.addfile(member)
                else:
                    data = path.read_bytes()
                    member.mode = 0o755 if path.suffix == ".sh" else 0o644
                    member.size = len(data)
                    archive.addfile(member, io.BytesIO(data))
    return output.getvalue()


def artifacts(root=ROOT):
    bundle = management_archive(root)
    files = {"mgmt-code.tar.gz": bundle}
    for name, data in (("auto-deploy.sh", (root / "auto-deploy.sh").read_bytes()), ("mgmt-code.tar.gz", bundle)):
        files[name + ".sha256"] = (hashlib.sha256(data).hexdigest() + "  " + name + "\n").encode()
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="check without writing")
    args = parser.parse_args()
    for name, data in artifacts().items():
        path = ROOT / name
        if args.check:
            if not path.exists() or path.read_bytes() != data:
                raise SystemExit(f"Outdated artifact: {name}; run python scripts/build-artifacts.py")
        else:
            path.write_bytes(data)
        print(("Checked " if args.check else "Built ") + name)


if __name__ == "__main__":
    main()
