#!/usr/bin/env python3
import hashlib
import json
import os
import pathlib
import stat
import sys


def fail(message):
    raise SystemExit(message)


def write_manifest(root_arg, runtime_id, wine_version):
    root = pathlib.Path(root_arg)
    if not root.is_dir():
        fail(f"runtime root is not a directory: {root}")
    if not runtime_id or any(character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-" for character in runtime_id):
        fail("runtime ID is not catalog-safe")
    if not wine_version.startswith("wine-"):
        fail("wine version must use the catalog wine- prefix")

    manifest_name = "yaagl-wine-runtime-files.json"
    entries = []
    for directory, names, files in os.walk(root, topdown=True, followlinks=False):
        names.sort()
        files.sort()
        directory_path = pathlib.Path(directory)
        for name in names + files:
            path = directory_path / name
            relative_path = path.relative_to(root).as_posix()
            if relative_path == manifest_name:
                continue
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                entries.append({"path": relative_path, "type": "symlink", "target": os.readlink(path)})
            elif stat.S_ISREG(mode):
                data = path.read_bytes()
                entries.append({"path": relative_path, "type": "file", "size": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    entries.sort(key=lambda entry: entry["path"])
    required = {"bin/wine", "bin/wine.real", "bin/wineserver"}
    covered_files = {entry["path"] for entry in entries if entry["type"] == "file"}
    missing = sorted(required - covered_files)
    if missing:
        fail("trusted runtime manifest missing required regular files: " + ", ".join(missing))

    manifest = {"schemaVersion": 1, "runtimeId": runtime_id, "wineVersion": wine_version, "entries": entries}
    output = root / manifest_name
    with output.open("w", encoding="utf-8", newline="\n") as stream:
        json.dump(manifest, stream, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        stream.write("\n")
    return output


if __name__ == "__main__":
    if len(sys.argv) != 4:
        fail("usage: write-wine-runtime-manifest.py RUNTIME_ROOT RUNTIME_ID WINE_VERSION")
    print(write_manifest(*sys.argv[1:]))
