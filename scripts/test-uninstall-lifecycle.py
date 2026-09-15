#!/usr/bin/env python3
"""Behavioral regression coverage for managed-runtime uninstall using isolated Yaagl copies."""

import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import shutil
import stat
import subprocess
import tempfile


def load_fixture_helpers(repo):
    path = repo / "scripts/test-resource-lifecycle.py"
    spec = importlib.util.spec_from_file_location("resource_lifecycle", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree_evidence(root):
    evidence = {}
    if not root.exists():
        return evidence
    for path in sorted(root.rglob("*")):
        relative = str(path.relative_to(root))
        if path.is_symlink():
            evidence[relative] = ("link", os.readlink(path))
        elif path.is_file():
            evidence[relative] = ("file", digest(path), path.stat().st_mode & 0o777)
        elif path.is_dir():
            evidence[relative] = ("dir", path.stat().st_mode & 0o777)
    return evidence


def run_cli(binary, action, app, support, expect_success=True):
    result = subprocess.run(
        [str(binary), action, "--app-path", str(app), "--support-path", str(support)],
        capture_output=True, text=True, timeout=120,
    )
    if expect_success:
        assert result.returncode == 0, result.stdout + result.stderr
    else:
        assert result.returncode != 0, "Command unexpectedly succeeded"
    return result


def make_fixture(root, stock, version="3.0.0"):
    paths = root / "Yaagl's Test Paths"
    app = paths / "Yaagl HSR OS.app"
    support = paths / "Yaagl HSR OS"
    (app / "Contents/Resources").mkdir(parents=True)
    (support / ".storage").mkdir(parents=True)
    app_resource = app / "Contents/Resources/resources.neu"
    support_resource = support / "resources.neu"
    app_resource.write_bytes(stock.create_asar_fixture(stock.stock_bytes, "2.9.0"))
    support_resource.write_bytes(stock.create_asar_fixture(stock.stock_bytes, version))
    os.utime(app_resource, (1000, 1000))
    os.utime(support_resource, (2000, 2000))
    (support / "game/StarRail_Data").mkdir(parents=True)
    (support / "game/StarRail_Data/GAME_MARKER.bin").write_bytes(b"game-data-must-survive\0\xff")
    (support / "prefix/drive_c/users/test").mkdir(parents=True)
    (support / "prefix/drive_c/users/test/LOGIN_MARKER.bin").write_bytes(b"prefix-login-registry-must-survive\0\xfe")
    return app, support


def install(binary, app, support):
    run_cli(binary, "--install", app, support)
    manifest = support / "wine/yaagl-wine-runtime-files.json"
    assert manifest.is_file(), "Production runtime manifest was not installed"
    parsed = json.loads(manifest.read_text())
    assert parsed["runtimeId"] == "11.17-hsr-gptk4b2-stock"


def assert_user_data(support, before):
    assert tree_evidence(support / "game") == before["game"], "Game bytes changed"
    assert tree_evidence(support / "prefix") == before["prefix"], "Prefix/login/registry bytes changed"


def registration_backup(support):
    patched_hash = digest(support / "resources.neu")
    return support / ".hsr-wine-registration/backups" / f"{patched_hash}.neu"


def run_suite(stock_bytes, repo, installer_app=None):
    app_bundle = installer_app or (repo / "installer/HSR Wine D3DMetal Installer.app")
    binary = app_bundle / "Contents/MacOS/hsr-wine-installer"
    archive_name = "wine-11.17-hsr-gptk4b2-stock.tar.xz"
    assert binary.is_file(), f"Installer binary missing: {binary}"

    helpers = load_fixture_helpers(repo)
    helpers.stock_bytes = stock_bytes

    def isolated(name):
        temp = tempfile.TemporaryDirectory(prefix=f"hsr-uninstall-{name}-", dir="/tmp")
        root = pathlib.Path(temp.name)
        app, support = make_fixture(root, helpers)
        user_before = {"game": tree_evidence(support / "game"), "prefix": tree_evidence(support / "prefix")}
        return temp, app, support, user_before

    print("[UNINSTALL 1] Managed v1.0.0-compatible install restores prior Wine and selection")
    temp, app, support, user_before = isolated("previous")
    with temp:
        (support / "wine/bin").mkdir(parents=True)
        (support / "wine/bin/wine").write_bytes(b"actual-old-wine-binary")
        (support / "wine/OLD_RUNTIME_MARKER").write_bytes(b"old-runtime-evidence")
        (support / ".storage/wine_tag.neustorage").write_text("user-prior-wine")
        (support / ".storage/wine_state.neustorage").write_text("ready")
        old_wine = tree_evidence(support / "wine")
        install(binary, app, support)
        run_cli(binary, "--uninstall", app, support)
        assert tree_evidence(support / "wine") == old_wine
        assert (support / ".storage/wine_tag.neustorage").read_text() == "user-prior-wine"
        assert (support / ".storage/wine_state.neustorage").read_text() == "ready"
        assert not (support / "local-runtimes" / archive_name).exists()
        assert not (support / ".hsr-wine-registration").exists()
        assert_user_data(support, user_before)

    print("[UNINSTALL 2] First install removes managed runtime and restores valid empty selection")
    temp, app, support, user_before = isolated("first")
    with temp:
        install(binary, app, support)
        run_cli(binary, "--uninstall", app, support)
        assert not (support / "wine").exists()
        assert not (support / ".storage/wine_tag.neustorage").exists()
        assert not (support / ".storage/wine_state.neustorage").exists()
        assert_user_data(support, user_before)

    print("[UNINSTALL 3] Alternate active Wine and saved backup remain byte-for-byte unchanged")
    temp, app, support, user_before = isolated("alternate")
    with temp:
        (support / "wine/bin").mkdir(parents=True)
        (support / "wine/bin/wine").write_bytes(b"prior-backup-wine")
        (support / ".storage/wine_tag.neustorage").write_text("prior-selection")
        (support / ".storage/wine_state.neustorage").write_text("ready")
        install(binary, app, support)
        shutil.rmtree(support / "wine")
        (support / "wine/bin").mkdir(parents=True)
        (support / "wine/bin/wine").write_bytes(b"alternate-current-wine")
        (support / "wine/ALTERNATE_MARKER").write_bytes(b"preserve-active")
        (support / ".storage/wine_tag.neustorage").write_text("different-runtime")
        (support / ".storage/wine_state.neustorage").write_text("ready")
        active_before = tree_evidence(support / "wine")
        backup_before = tree_evidence(support / "wine.bak")
        selection_before = ((support / ".storage/wine_tag.neustorage").read_bytes(), (support / ".storage/wine_state.neustorage").read_bytes())
        run_cli(binary, "--uninstall", app, support)
        assert tree_evidence(support / "wine") == active_before
        assert tree_evidence(support / "wine.bak") == backup_before
        assert selection_before == ((support / ".storage/wine_tag.neustorage").read_bytes(), (support / ".storage/wine_state.neustorage").read_bytes())
        assert_user_data(support, user_before)

    print("[UNINSTALL 4] Repeated uninstall is idempotent")
    temp, app, support, user_before = isolated("repeat")
    with temp:
        install(binary, app, support)
        run_cli(binary, "--uninstall", app, support)
        first = tree_evidence(support)
        run_cli(binary, "--uninstall", app, support)
        assert tree_evidence(support) == first
        assert_user_data(support, user_before)

    for condition in ("missing", "mismatched"):
        print(f"[UNINSTALL 5:{condition}] Unsafe resource backup fails before runtime changes")
        temp, app, support, user_before = isolated(condition)
        with temp:
            install(binary, app, support)
            backup = registration_backup(support)
            assert backup.is_file()
            if condition == "missing":
                backup.unlink()
            else:
                backup.write_bytes(b"not-the-paired-pristine-resource")
            before = tree_evidence(support)
            if condition == "mismatched":
                run_cli(binary, "--restore", app, support, expect_success=False)
                assert tree_evidence(support) == before
            run_cli(binary, "--uninstall", app, support, expect_success=False)
            assert tree_evidence(support) == before
            assert_user_data(support, user_before)

    print("[UNINSTALL 6] Forced post-resource failure rolls runtime, registration, cache, and selection back")
    temp, app, support, user_before = isolated("rollback")
    with temp:
        (support / "wine/bin").mkdir(parents=True)
        (support / "wine/bin/wine").write_bytes(b"prior-runtime")
        (support / ".storage/wine_tag.neustorage").write_text("prior-tag")
        (support / ".storage/wine_state.neustorage").write_text("ready")
        install(binary, app, support)
        tag = support / ".storage/wine_tag.neustorage"
        before = tree_evidence(support)
        os.chflags(tag, stat.UF_IMMUTABLE)
        try:
            run_cli(binary, "--uninstall", app, support, expect_success=False)
        finally:
            os.chflags(tag, 0)
        assert tree_evidence(support) == before
        assert_user_data(support, user_before)

    print("ALL UNINSTALL LIFECYCLE SCENARIOS PASSED")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--stock-resource", required=True)
    parser.add_argument("--repo", default=str(pathlib.Path.cwd()))
    parser.add_argument("--installer-app", type=pathlib.Path)
    args = parser.parse_args()
    stock = pathlib.Path(args.stock_resource).resolve()
    assert stock.is_file(), f"Stock resource fixture missing: {stock}"
    installer_app = args.installer_app.resolve() if args.installer_app else None
    run_suite(stock.read_bytes(), pathlib.Path(args.repo).resolve(), installer_app)


if __name__ == "__main__":
    main()
