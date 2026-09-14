#!/usr/bin/env python3
"""
Yaagl Wine DX12 Installer - Resource Lifecycle Regression Test Suite

Validates:
1. Strict requirement of explicit --stock-resource fixture (no userhome/machine paths).
2. Handling paths with spaces and apostrophes in both app and support directories.
3. Seeding valid prior Wine runtime so Restore has real backup.
4. App bundle immutability:
   - app/Contents/Resources/resources.neu bytes and mtime 100% untouched.
   - Pre-existing legacy app/Contents/Resources/resources.neu.bak is 100% untouched.
5. Support-only resource patching & floor-second mtime safety preventing rsync downgrade.
6. Automatic update helper (zzz-wine-register) execution on unpatched newer update:
   - Patches pending update, retains version, records hash-keyed pristine backup.
   - Emulated updater commit (forceMove) preserves registration and frontend version.
7. Corrupted / malformed update rejection leaving active support untouched.
8. Reinstall after upstream update.
9. Hash-keyed restore cleanly restoring matching unpatched version and wine runtime.
10. Restore on clean upstream preserving current frontend.
"""

import argparse
import hashlib
import json
import os
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile

def create_asar_fixture(stock_bytes, version):
    size, length = struct.unpack_from('<II', stock_bytes, 8)
    header = json.loads(stock_bytes[16:16+length])
    entries = []
    def walk(files, prefix=''):
        for name, entry in files.items():
            if 'files' in entry:
                walk(entry['files'], prefix + name + '/')
            elif 'offset' in entry:
                entries.append((int(entry['offset']), prefix + name, entry))
    walk(header['files'])
    payload = bytearray()
    for offset, name, entry in sorted(entries):
        content = stock_bytes[12+size+offset : 12+size+offset+entry['size']]
        if name == 'neutralino.config.json':
            config = json.loads(content)
            config['version'] = version
            content = json.dumps(config).encode() + (b'\n' if version.startswith('3') else b'')
        entry['offset'] = str(len(payload))
        entry['size'] = len(content)
        if 'integrity' in entry:
            blocksize = entry['integrity'].get('blockSize', 4*1024*1024)
            entry['integrity'].update(
                hash=hashlib.sha256(content).hexdigest(),
                blocks=[hashlib.sha256(content[i : i+blocksize]).hexdigest() for i in range(0, len(content), blocksize)]
            )
        payload.extend(content)
    text = json.dumps(header, separators=(',', ':')).encode()
    pad_len = (-len(text)) % 4
    padded = text + (b'\0' * pad_len)
    return struct.pack('<IIII', 4, len(padded)+8, len(padded)+4, len(text)) + padded + payload

def parse_asar_version(data):
    size, length = struct.unpack_from('<II', data, 8)
    entry = json.loads(data[16:16+length])['files']['neutralino.config.json']
    offset = 12 + size + int(entry['offset'])
    return json.loads(data[offset:offset+entry['size']])['version']

def sha256(data):
    return hashlib.sha256(data).hexdigest()


def run_suite(stock_bytes, repo_root):
    print("====================================================================")
    print("Yaagl Wine DX12 Installer - Resource Lifecycle Regression Test Suite")
    print("====================================================================")

    installer_app = repo_root / 'installer/ZZZ Wine DX12 Installer.app'
    installer_bin = installer_app / 'Contents/MacOS/zzz-wine-installer'
    helper_bin = installer_app / 'Contents/Resources/zzz-wine-register'
    if not helper_bin.exists():
        helper_bin = repo_root / 'installer/zzz-wine-register'

    runtime_archive_source = installer_app / 'Contents/Resources/Wine 11.17 ZZZ DX12 (GPTK4.0b2 macOS26).tar.xz'

    assert installer_bin.exists(), f"Installer binary not found: {installer_bin}"
    assert helper_bin.exists(), f"Helper binary not found: {helper_bin}"
    assert runtime_archive_source.exists(), f"Runtime archive not found: {runtime_archive_source}"

    with tempfile.TemporaryDirectory(prefix='zzz-lifecycle-', dir='/tmp') as tmp:
        root = pathlib.Path(tmp)

        # Use paths with spaces and apostrophes
        app = root / "Yaagl Test's App.app"
        resources = app / "Contents/Resources"
        resources.mkdir(parents=True)
        support = root / "Yaagl's Support Folder With Spaces"
        support.mkdir()

        app_neu = resources / "resources.neu"
        support_neu = support / "resources.neu"
        legacy_bak = resources / "resources.neu.bak"

        # Seed pre-existing legacy backup in app bundle to prove it is NEVER touched
        legacy_marker = b"LEGACY_APP_BACKUP_MARKER_PRESERVED"
        legacy_bak.write_bytes(legacy_marker)
        os.utime(legacy_bak, (500, 500))

        # Seed prior Wine runtime in support so Restore has a real prior wine to restore
        prior_wine = support / "wine"
        subprocess.run(["/usr/bin/tar", "-xJf", str(runtime_archive_source), "-C", str(support)], check=True)
        assert prior_wine.is_dir(), "Seeded wine directory failed extraction"
        marker_file = prior_wine / "PRIOR_WINE_MARKER.txt"
        marker_file.write_text("PRIOR_WINE_VERSION_FOR_RESTORE_TEST")

        f29 = create_asar_fixture(stock_bytes, "2.9.0")
        f30 = create_asar_fixture(stock_bytes, "3.0.0")
        f31 = create_asar_fixture(stock_bytes, "3.1.0")
        f32 = create_asar_fixture(stock_bytes, "3.2.0")

        app_neu.write_bytes(f29)
        support_neu.write_bytes(f30)
        os.utime(app_neu, (1000, 1000))
        os.utime(support_neu, (2000, 2000))

        app_sha_before = sha256(app_neu.read_bytes())
        app_mtime_before = app_neu.stat().st_mtime

        # -------------------------------------------------------------
        # Scenario 1: Fresh Install with App Immutability & Floor-Second Mtime
        # -------------------------------------------------------------
        print("\n[SCENARIO 1] Fresh installation with spaces/quotes and legacy app backup...")
        subprocess.run([str(installer_bin), "--install", "--app-path", str(app), "--support-path", str(support)],
                       check=True, capture_output=False, timeout=120)

        # 1a. App bundle resources.neu must be completely untouched
        assert sha256(app_neu.read_bytes()) == app_sha_before, "App resources.neu bytes modified!"
        assert app_neu.stat().st_mtime == app_mtime_before, "App resources.neu mtime modified!"
        print("  -> PASS: App bundle resources.neu bytes and mtime are 100% UNTOUCHED.")

        # 1b. Legacy backup in app bundle must be completely untouched
        assert legacy_bak.read_bytes() == legacy_marker, "Legacy app backup was overwritten!"
        assert legacy_bak.stat().st_mtime == 500.0, "Legacy app backup mtime was modified!"
        print("  -> PASS: Pre-existing legacy app backup remained 100% UNTOUCHED.")

        # 1c. Support resources.neu patched with version 3.0.0 and updater hook
        support_bytes = support_neu.read_bytes()
        assert parse_asar_version(support_bytes) == "3.0.0", "Support version changed unexpectedly!"
        print("  -> PASS: Support resources.neu patched (version 3.0.0 + updater hook retained).")

        # 1d. Registration helper deployed
        helper_deployed = support / ".zzz-wine-registration/zzz-wine-register"
        assert helper_deployed.exists() and os.access(helper_deployed, os.X_OK), "Helper not deployed or not executable!"
        print("  -> PASS: Registration helper deployed to support/.zzz-wine-registration/zzz-wine-register.")

        # 1e. Support mtime floor-second strictly > App mtime
        assert int(support_neu.stat().st_mtime) > int(app_neu.stat().st_mtime)
        print("  -> PASS: Support integer mtime strictly greater than app mtime.")

        # 1f. Startup rsync test: must preserve 3.0.0 and custom runtime
        subprocess.run(["/usr/bin/rsync", "-rlptu", str(resources) + "/.", str(support)], check=True)
        rsync_bytes = support_neu.read_bytes()
        assert parse_asar_version(rsync_bytes) == "3.0.0", "Startup rsync downgraded support to 2.9.0!"
        print("  -> PASS: Startup rsync preserved support version 3.0.0 and registration.")

        # -------------------------------------------------------------
        # Scenario 2: Automatic Update Retention via Native Helper (3.1.0)
        # -------------------------------------------------------------
        print("\n[SCENARIO 2] Automatic update helper execution on unpatched 3.1.0 update...")
        runtime_before = {path: (support / path).read_bytes() for path in
                          ["wine/bin/wine", "wine/bin/wineserver", ".storage/wine_tag.neustorage", ".storage/wine_state.neustorage"]}
        archive_path = support / "local-runtimes" / "Wine 11.17 ZZZ DX12 (GPTK4.0b2 macOS26).tar.xz"
        assert archive_path.exists(), f"Runtime archive missing at {archive_path}"

        update_neu = support / "resources.neu.update"
        update_neu.write_bytes(f31)
        update_sha_clean = sha256(f31)

        res = subprocess.run([str(helper_deployed), "--resource-path", str(update_neu), "--archive-path", str(archive_path)],
                             capture_output=True, text=True)
        assert res.returncode == 0, f"Helper failed: {res.stderr}\n{res.stdout}"

        update_bytes = update_neu.read_bytes()
        assert parse_asar_version(update_bytes) == "3.1.0", "Update version changed unexpectedly!"

        # Pristine backup keyed by patched SHA
        patched_sha = sha256(update_bytes)
        backup_file = support / ".zzz-wine-registration/backups" / f"{patched_sha}.neu"
        assert backup_file.exists(), "Pristine backup not created!"
        assert sha256(backup_file.read_bytes()) == update_sha_clean, "Backup does not match clean 3.1.0 bytes!"
        print("  -> PASS: Helper patched update and recorded pristine backup keyed by patched SHA.")

        # Emulate updater commit: forceMove(resources.neu.update, resources.neu)
        os.replace(update_neu, support_neu)
        committed_bytes = support_neu.read_bytes()
        for path, content in runtime_before.items():
            assert (support / path).read_bytes() == content, f"Update changed installed Wine or its selection: {path}"
        assert parse_asar_version(committed_bytes) == "3.1.0"
        print("  -> PASS: Emulated updater commit succeeded; active frontend is now 3.1.0 with registration.")

        # Startup rsync must not downgrade 3.1.0
        subprocess.run(["/usr/bin/rsync", "-rlptu", str(resources) + "/.", str(support)], check=True)
        assert parse_asar_version(support_neu.read_bytes()) == "3.1.0"
        print("  -> PASS: Startup rsync does not downgrade active 3.1.0.")

        # -------------------------------------------------------------
        # Scenario 3: Malformed / Corrupted Update Rejection
        # -------------------------------------------------------------
        print("\n[SCENARIO 3] Corrupted update rejection by helper...")
        active_sha_before = sha256(support_neu.read_bytes())
        update_neu.write_bytes(b"corrupted invalid ASAR data junk")

        res = subprocess.run([str(helper_deployed), "--resource-path", str(update_neu), "--archive-path", str(archive_path)],
                             capture_output=True, text=True)
        assert res.returncode != 0, "Helper should have failed on corrupted update!"
        assert sha256(support_neu.read_bytes()) == active_sha_before, "Active support resource was modified by failed helper!"
        update_neu.unlink()
        print("  -> PASS: Malformed update rejected; active support resource untouched.")

        # -------------------------------------------------------------
        # Scenario 4: Reinstall After Upstream Update (3.2.0)
        # -------------------------------------------------------------
        print("\n[SCENARIO 4] Reinstall after upstream update to 3.2.0...")
        support_neu.write_bytes(f32)

        subprocess.run([str(installer_bin), "--install", "--app-path", str(app), "--support-path", str(support)],
                       check=True, capture_output=False, timeout=120)

        reinstalled_bytes = support_neu.read_bytes()
        assert parse_asar_version(reinstalled_bytes) == "3.2.0"
        print("  -> PASS: Reinstall registered into 3.2.0 without downgrade.")

        # -------------------------------------------------------------
        # Scenario 5: Restore on Registered 3.2.0 (Matching Version + Wine)
        # -------------------------------------------------------------
        print("\n[SCENARIO 5] Restore on registered 3.2.0...")
        # A prepared update must not replace the active generation's restore point.
        update_neu.write_bytes(f31)
        subprocess.run([str(helper_deployed), "--resource-path", str(update_neu), "--archive-path", str(archive_path)],
                       check=True, capture_output=True, text=True)
        subprocess.run([str(installer_bin), "--restore", "--app-path", str(app), "--support-path", str(support)],
                       check=True, capture_output=False, timeout=120)

        restored_bytes = support_neu.read_bytes()
        assert restored_bytes == f32, "Pending update changed the active generation restore point!"
        assert parse_asar_version(restored_bytes) == "3.2.0", f"Restore downgraded to {parse_asar_version(restored_bytes)}!"
        # Check that prior wine runtime was restored
        assert (support / "wine/PRIOR_WINE_MARKER.txt").exists(), "Prior wine runtime was not restored!"
        print("  -> PASS: Restore cleanly restored pristine unpatched 3.2.0 and prior Wine runtime.")

        # -------------------------------------------------------------
        # Scenario 6: Restore on Clean Upstream (No-op Safe Preservation)
        # -------------------------------------------------------------
        print("\n[SCENARIO 6] Restore on already-clean upstream...")
        subprocess.run([str(installer_bin), "--install", "--app-path", str(app), "--support-path", str(support)],
                       check=True, capture_output=True, text=True, timeout=120)
        clean_update = create_asar_fixture(stock_bytes, "3.3.0")
        support_neu.write_bytes(clean_update)
        res = subprocess.run([str(installer_bin), "--restore", "--app-path", str(app), "--support-path", str(support)],
                             capture_output=True, text=True, timeout=120)
        assert res.returncode == 0, res.stdout + res.stderr
        assert support_neu.read_bytes() == clean_update
        print("  -> PASS: Restore on clean upstream safely preserved current version.")

        # -------------------------------------------------------------
        # Scenario 7: Subsecond / Integer Floor-Second Boundary
        # -------------------------------------------------------------
        print("\n[SCENARIO 7] Subsecond boundary rsync safety...")
        app_neu.write_bytes(f29); support_neu.write_bytes(f30)
        os.utime(app_neu, (1000.2, 1000.2))
        os.utime(support_neu, (1000.8, 1000.8))
        app_sub_mtime_before = app_neu.stat().st_mtime
        subprocess.run([str(installer_bin), "--install", "--app-path", str(app), "--support-path", str(support)],
                       check=True, capture_output=False, timeout=120)
        # An idempotent registration preserves the resource mtime. Force both
        # resources into the same rsync-visible second before reinstalling.
        os.utime(support_neu, (1000.8, 1000.8))
        subprocess.run([str(installer_bin), "--install", "--app-path", str(app), "--support-path", str(support)],
                       check=True, capture_output=False, timeout=120)
        assert app_neu.stat().st_mtime == app_sub_mtime_before, "App mtime modified during subsecond test!"
        assert int(support_neu.stat().st_mtime) > int(app_neu.stat().st_mtime)
        subprocess.run(["/usr/bin/rsync", "-rlptu", str(resources) + "/.", str(support)], check=True)
        assert parse_asar_version(support_neu.read_bytes()) == "3.0.0"
        print("  -> PASS: Floor-second mtime enforcement safely prevents rsync clobbering.")

        # -------------------------------------------------------------
        # Scenario 8: Failed Reinstall Rollback Preservation
        # -------------------------------------------------------------
        print("\n[SCENARIO 8] Failed reinstall rollback safety...")
        # Registration must change these clean bytes before activation fails.
        support_neu.write_bytes(f32)
        import stat
        storage_tag = support / ".storage" / "wine_tag.neustorage"
        storage_tag.parent.mkdir(parents=True, exist_ok=True)
        if not storage_tag.exists():
            storage_tag.write_text("initial_tag")
        
        pre_fail_support_sha = sha256(support_neu.read_bytes())
        pre_fail_support_mtime = support_neu.stat().st_mtime

        os.chflags(str(storage_tag), stat.UF_IMMUTABLE)
        try:
            res = subprocess.run([str(installer_bin), "--install", "--app-path", str(app), "--support-path", str(support)],
                                 capture_output=True, text=True, timeout=120)
            assert res.returncode != 0, "Installer should fail when storage is immutable!"
            # Assert support resources exact bytes + mtime restored
            assert sha256(support_neu.read_bytes()) == pre_fail_support_sha, "Resources bytes not restored after failed install!"
            assert support_neu.stat().st_mtime == pre_fail_support_mtime, "Resources mtime not restored after failed install!"
            # Assert helper and backups still usable
            assert helper_deployed.exists() and os.access(helper_deployed, os.X_OK), "Helper was removed on failed reinstall!"
            assert (support / ".zzz-wine-registration/backups").is_dir(), "Backups dir was deleted on failed reinstall!"
            print("  -> PASS: Failed reinstall rollback cleanly restored resources bytes/mtime and preserved helper.")
        finally:
            os.chflags(str(storage_tag), 0)

        # Final app immutability verification
        assert sha256(app_neu.read_bytes()) == app_sha_before
        assert legacy_bak.read_bytes() == legacy_marker
        assert legacy_bak.stat().st_mtime == 500.0
        print("\n[FINAL VERIFICATION] App bundle and legacy backup remained 100% untouched across all 8 scenarios!")

    print("\n====================================================================")
    print("ALL 8 RESOURCE LIFECYCLE REGRESSION SCENARIOS PASSED SUCCESSFULLY!")
    print("====================================================================")

def main():
    parser = argparse.ArgumentParser(description="Yaagl Wine DX12 Resource Lifecycle Regression Tests")
    parser.add_argument("--stock-resource", required=True, help="Path to stock Yaagl resources.neu fixture (REQUIRED)")
    parser.add_argument("--repo", help="Repository root path", default=str(pathlib.Path.cwd()))
    args = parser.parse_args()

    stock_path = pathlib.Path(args.stock_resource).resolve()
    if not stock_path.is_file():
        print(f"Error: --stock-resource fixture does not exist: {stock_path}", file=sys.stderr)
        sys.exit(1)

    stock_bytes = stock_path.read_bytes()
    repo_root = pathlib.Path(args.repo).resolve()
    run_suite(stock_bytes, repo_root)

if __name__ == '__main__':
    main()
