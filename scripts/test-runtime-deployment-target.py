#!/usr/bin/env python3
import pathlib
import struct
import subprocess
import sys
import tarfile
from io import BytesIO
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name("validate-runtime-deployment-target.py")


def macho(minimum):
    encoded = (minimum[0] << 16) | (minimum[1] << 8) | minimum[2]
    command = struct.pack("<IIIIII", 0x32, 24, 1, encoded, encoded, 0)
    return struct.pack("<IiiIIIII", 0xFEEDFACF, 0x01000007, 3, 6, 1, len(command), 0, 0) + command


class RuntimeDeploymentTargetTest(unittest.TestCase):
    def add_required_core(self, wine):
        (wine / "bin").mkdir(parents=True, exist_ok=True)
        (wine / "bin/wine").write_bytes(macho((26, 0, 0)))
        (wine / "bin/wineserver").write_bytes(macho((26, 0, 0)))

    def run_validator(self, runtime):
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(runtime), "--maximum", "26.0"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_archive_rejects_any_incompatible_core_macho(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            wine = root / "source" / "wine"
            (wine / "lib/wine/x86_64-unix/arbitrary").mkdir(parents=True)
            (wine / "lib/wine/x86_64-unix/arbitrary/core-helper.so").write_bytes(macho((27, 0, 0)))
            self.add_required_core(wine)
            archive = root / "bad.tar.xz"
            with tarfile.open(archive, "w:xz") as output:
                output.add(wine, arcname="wine")
            result = self.run_validator(archive)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("core-helper.so: requires macOS 27.0.0", result.stderr)
            self.assertIn("runtime rejected", result.stderr)

    def test_unpinned_external_binary_does_not_bypass_core_check(self):
        with tempfile.TemporaryDirectory() as temporary:
            wine = pathlib.Path(temporary) / "wine"
            apple = wine / "lib/external/D3DMetal.framework/Versions/A/Resources"
            core = wine / "lib/wine/x86_64-unix"
            apple.mkdir(parents=True)
            core.mkdir(parents=True)
            (apple / "libdxccontainer.dylib").write_bytes(macho((26, 4, 0)))
            (core / "ntdll.so").write_bytes(macho((26, 0, 0)))
            self.add_required_core(wine)
            rejected = self.run_validator(wine)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("libdxccontainer.dylib: requires macOS 26.4.0", rejected.stderr)
            (core / "ntdll.so").write_bytes(macho((27, 0, 0)))
            rejected_core = self.run_validator(wine)
            self.assertNotEqual(rejected_core.returncode, 0)
            self.assertIn("ntdll.so: requires macOS 27.0.0", rejected_core.stderr)

    def test_archive_links_are_never_materialized(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            archive = root / "links.tar.xz"
            escaped = root / "escaped"
            with tarfile.open(archive, "w:xz") as output:
                first = tarfile.TarInfo("wine/a")
                first.type = tarfile.SYMTYPE
                first.linkname = "../.."
                output.addfile(first)
                second = tarfile.TarInfo("wine/b")
                second.type = tarfile.SYMTYPE
                second.linkname = "a/../escaped"
                output.addfile(second)
                payload = b"escape"
                victim = tarfile.TarInfo("wine/b/victim")
                victim.size = len(payload)
                output.addfile(victim, BytesIO(payload))
            result = self.run_validator(archive)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((escaped / "victim").exists())


if __name__ == "__main__":
    unittest.main()
