#!/usr/bin/env python3
import argparse
import hashlib
import os
import pathlib
import posixpath
import struct
import sys
import tarfile
import tempfile

MACHO_64_LE = 0xFEEDFACF
FAT_BE = 0xCAFEBABE
FAT64_BE = 0xCAFEBABF
MACHO_MAGICS = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf", b"\xbe\xba\xfe\xca", b"\xbf\xba\xfe\xca"}
LC_VERSION_MIN_MACOSX = 0x24
LC_BUILD_VERSION = 0x32
APPLE_METADATA_EXCEPTION = {
    "lib/external/D3DMetal.framework/Versions/A/Resources/libdxccontainer.dylib":
        "246bbb15150915b254058bf6930be070bffacd25d6a8e7a932657dcbfefb7e53",
}


def version(value):
    return (value >> 16, (value >> 8) & 0xFF, value & 0xFF)


def version_text(value):
    parts = version(value)
    return f"{parts[0]}.{parts[1]}.{parts[2]}"


def thin_slices(data):
    if len(data) < 4:
        return []
    magic_be = struct.unpack_from(">I", data)[0]
    if magic_be not in (FAT_BE, FAT64_BE):
        if struct.unpack_from("<I", data)[0] != MACHO_64_LE:
            raise ValueError("unsupported Mach-O encoding or architecture")
        return [data]
    if len(data) < 8:
        raise ValueError("truncated universal header")
    count = struct.unpack_from(">I", data, 4)[0]
    stride = 32 if magic_be == FAT64_BE else 20
    if count > (len(data) - 8) // stride:
        raise ValueError("truncated universal architecture table")
    slices = []
    view = memoryview(data)
    for index in range(count):
        offset = 8 + index * stride
        if magic_be == FAT64_BE:
            file_offset, size = struct.unpack_from(">QQ", data, offset + 8)
        else:
            file_offset, size = struct.unpack_from(">II", data, offset + 8)
        if file_offset + size > len(data):
            raise ValueError("invalid universal slice range")
        thin = view[file_offset:file_offset + size]
        if len(thin) < 4 or struct.unpack_from("<I", thin)[0] != MACHO_64_LE:
            raise ValueError("universal binary contains an unsupported or malformed Mach-O slice")
        slices.append(thin)
    if not slices:
        raise ValueError("universal binary contains no Mach-O slices")
    return slices


def minimum_versions(data):
    results = []
    for thin in thin_slices(data):
        if len(thin) < 32:
            raise ValueError("truncated Mach-O header")
        command_count, command_bytes = struct.unpack_from("<II", thin, 16)
        end = 32 + command_bytes
        if end > len(thin):
            raise ValueError("truncated Mach-O load commands")
        cursor = 32
        found = False
        for _ in range(command_count):
            if cursor + 8 > end:
                raise ValueError("truncated Mach-O load command")
            command, size = struct.unpack_from("<II", thin, cursor)
            if size < 8 or cursor + size > end:
                raise ValueError("invalid Mach-O load command size")
            if command == LC_BUILD_VERSION:
                if size < 24:
                    raise ValueError("truncated LC_BUILD_VERSION")
                platform, minimum = struct.unpack_from("<II", thin, cursor + 8)
                if platform == 1:
                    results.append(minimum)
                    found = True
            elif command == LC_VERSION_MIN_MACOSX:
                if size < 16:
                    raise ValueError("truncated LC_VERSION_MIN_MACOSX")
                results.append(struct.unpack_from("<I", thin, cursor + 8)[0])
                found = True
            cursor += size
        if not found:
            raise ValueError("Mach-O slice has no macOS deployment metadata")
    return results


def audit_tree(root, maximum):
    violations = []
    exceptions = []
    scanned = 0
    for directory, names, files in os.walk(root, followlinks=False):
        names.sort()
        files.sort()
        for name in files:
            path = pathlib.Path(directory) / name
            if path.is_symlink():
                continue
            with path.open("rb") as stream:
                magic = stream.read(4)
                if magic not in MACHO_MAGICS:
                    continue
                data = magic + stream.read()
            try:
                versions = minimum_versions(data)
            except ValueError as error:
                violations.append((path.relative_to(root).as_posix(), str(error)))
                continue
            if not versions:
                continue
            scanned += 1
            relative = path.relative_to(root).as_posix()
            highest = max(versions, key=version)
            if version(highest) > maximum:
                item = (relative, f"requires macOS {version_text(highest)}")
                expected_hash = APPLE_METADATA_EXCEPTION.get(relative)
                if expected_hash is not None and hashlib.sha256(data).hexdigest() == expected_hash:
                    exceptions.append(item)
                else:
                    violations.append(item)
    return scanned, violations, exceptions


def main():
    parser = argparse.ArgumentParser(description="Reject Wine runtime Mach-O core files above the supported macOS target")
    parser.add_argument("runtime", help="wine directory or .tar.xz archive rooted at wine/")
    parser.add_argument("--maximum", default="26.0")
    args = parser.parse_args()
    maximum_parts = tuple(int(piece) for piece in args.maximum.split("."))
    maximum = (maximum_parts + (0, 0, 0))[:3]
    source = pathlib.Path(args.runtime)
    with tempfile.TemporaryDirectory(prefix="wine-deployment-audit.") as temporary:
        if source.is_dir():
            root = source
        else:
            with tarfile.open(source, "r:xz") as archive:
                members = archive.getmembers()
                seen = set()
                symlink_paths = set()
                for member in members:
                    path = pathlib.PurePosixPath(member.name)
                    normalized = posixpath.normpath(member.name)
                    if path.is_absolute() or ".." in path.parts or normalized != member.name.rstrip("/") or (normalized != "wine" and not normalized.startswith("wine/")):
                        raise SystemExit(f"unsafe archive member: {member.name}")
                    if normalized in seen:
                        raise SystemExit(f"duplicate archive member: {member.name}")
                    seen.add(normalized)
                    if member.islnk():
                        raise SystemExit(f"archive hard links are not permitted: {member.name}")
                    if member.issym():
                        target = pathlib.PurePosixPath(member.linkname)
                        resolved = posixpath.normpath(posixpath.join(posixpath.dirname(normalized), member.linkname))
                        if target.is_absolute() or not resolved.startswith("wine/"):
                            raise SystemExit(f"unsafe archive link: {member.name} -> {member.linkname}")
                        symlink_paths.add(normalized)
                    elif member.isdev() or member.isfifo():
                        raise SystemExit(f"unsafe archive member: {member.name}")
                for member in members:
                    normalized = posixpath.normpath(member.name)
                    ancestors = pathlib.PurePosixPath(normalized).parents
                    if any(str(ancestor) in symlink_paths for ancestor in ancestors):
                        raise SystemExit(f"archive member is beneath a symbolic link: {member.name}")
                for member in members:
                    path = pathlib.PurePosixPath(member.name)
                    destination = pathlib.Path(temporary).joinpath(*path.parts)
                    if member.isdir():
                        destination.mkdir(parents=True, exist_ok=True)
                    elif member.isfile():
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        source_file = archive.extractfile(member)
                        if source_file is None:
                            raise SystemExit(f"cannot read archive member: {member.name}")
                        with source_file, destination.open("wb") as output:
                            while chunk := source_file.read(1024 * 1024):
                                output.write(chunk)
                    elif not (member.issym() or member.islnk()):
                        raise SystemExit(f"unsupported archive member: {member.name}")
            root = pathlib.Path(temporary) / "wine"
        if not root.is_dir():
            raise SystemExit(f"runtime does not contain a wine directory: {source}")
        for required in ("bin/wine", "bin/wineserver"):
            if not (root / required).is_file():
                raise SystemExit(f"runtime is missing required file: {required}")
        scanned, violations, exceptions = audit_tree(root, maximum)
        if scanned == 0:
            raise SystemExit("runtime contains no auditable Mach-O files")
    for relative, detail in exceptions:
        print(f"APPLE-METADATA-EXCEPTION: {relative}: {detail}")
    if violations:
        for relative, detail in violations:
            print(f"INCOMPATIBLE: {relative}: {detail}", file=sys.stderr)
        raise SystemExit(f"runtime rejected: {len(violations)} Wine/core Mach-O file(s) exceed macOS {args.maximum} or lack valid deployment metadata")
    print(f"Deployment target audit passed: {scanned} Mach-O file(s), Wine/core <= macOS {args.maximum}, {len(exceptions)} stock Apple metadata exception(s)")


if __name__ == "__main__":
    main()
