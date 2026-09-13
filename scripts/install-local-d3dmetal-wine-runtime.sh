#!/bin/sh
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 <runtime.tar.xz> [Yaagl support root]" >&2
  exit 2
fi

contains_text()
{
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
archive=$1
archive_sidecar=$archive.sha256
support_root=${2:-"$HOME/Library/Application Support/Yaagl ZZZ DX12"}
active="$support_root/wine"
timestamp=$(date '+%Y%m%d-%H%M%S')
recovery="$support_root/recovery/local-wine-before-rtx5060-dx12-$timestamp"

if [ ! -f "$archive" ] || [ ! -f "$archive_sidecar" ] || [ ! -d "$active" ]; then
  echo "archive, archive SHA-256 sidecar, or active Yaagl Wine runtime is missing" >&2
  exit 3
fi
if pgrep -f "$active/bin/(wine|wineserver)" >/dev/null 2>&1; then
  echo "Yaagl Wine is running; quit the game and launcher before installing" >&2
  exit 4
fi

expected_archive_sha=$(/usr/bin/python3 - "$archive_sidecar" "$archive" <<'PY'
import pathlib, re, sys
sidecar, archive = map(pathlib.Path, sys.argv[1:])
lines = [line for line in sidecar.read_text(encoding="utf-8").splitlines() if line]
if len(lines) != 1:
    raise SystemExit("archive SHA-256 sidecar must contain exactly one line")
match = re.fullmatch(r"([0-9a-f]{64})[ \t]+\*?(.*)", lines[0])
if not match or pathlib.Path(match.group(2)).name != archive.name:
    raise SystemExit("archive SHA-256 sidecar is malformed or names another archive")
print(match.group(1))
PY
)
actual_archive_sha=$(shasum -a 256 "$archive" | awk '{print $1}')
if [ "$actual_archive_sha" != "$expected_archive_sha" ]; then
  echo "archive SHA-256 mismatch: expected $expected_archive_sha, got $actual_archive_sha" >&2
  exit 5
fi

staging=$(mktemp -d "$support_root/.local-wine-install.XXXXXX")
cleanup_staging() { /bin/rm -rf "$staging"; }
trap cleanup_staging EXIT HUP INT TERM
tar -xJf "$archive" -C "$staging"
candidate="$staging/wine"
if [ ! -x "$candidate/bin/wine" ] || [ ! -x "$candidate/bin/wine.real" ] ||
   [ ! -x "$candidate/bin/wineserver" ]; then
  echo "archive does not contain the expected Yaagl wine/ layout" >&2
  exit 6
fi

framework="$candidate/lib/external/D3DMetal.framework"
d3dmetal="$framework/Versions/A/D3DMetal"
module="$framework/Versions/A/Resources/libYaaglNativePsoCache.dylib"
converter="$framework/Versions/A/Resources/libmetalirconverter.dylib"
manifest="$candidate/yaagl-wine-p3-graphics-artifacts.json"
provenance="$candidate/yaagl-wine-p3-provenance.json"

expected_version=wine-11.0
if [ -f "$provenance" ]; then
  if [ "$#" -ne 2 ]; then
    echo "P3 requires an explicit Yaagl support root; the pinned DX12 launcher still requires Wine 11.0" >&2
    exit 8
  fi
  expected_version=$(/usr/bin/python3 - "$provenance" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as source:
    provenance = json.load(source)
if provenance.get("upstreamCommit") != "913e31f201d344223bdf3d13a50a41af35893d12" or provenance.get("wineVersion") != "wine-11.17":
    raise SystemExit("unexpected P3 package provenance")
print(provenance["wineVersion"])
PY
  )
fi

# Select the contract from positive package evidence before enforcing its
# artifacts. In particular, deleting a composite package's manifest cannot
# make it pass as the older stage-only contract.
composite_inspection=$(node "$repo_dir/scripts/d3dmetal-pso-cache-patch.mjs" inspect "$d3dmetal")
dependency_count=$(otool -arch x86_64 -L "$d3dmetal" 2>/dev/null | awk '$1 == "@loader_path/Resources/libYaaglNativePsoCache.dylib" { count++ } END { print count + 0 }')
package_contract=legacy-11.0
case "$composite_inspection" in
  *'"mode": "patched"'*|*'"mode": "patched-signed"'*) package_contract=native-pso-11.17 ;;
esac
if [ -e "$manifest" ] || [ -e "$module" ] || [ "$dependency_count" -ne 0 ]; then
  package_contract=native-pso-11.17
elif [ -f "$provenance" ]; then
  package_contract=stage-only-11.17
fi

if [ "$package_contract" = native-pso-11.17 ]; then
  if [ ! -f "$provenance" ]; then
    echo "native PSO cache package is missing P3 source provenance" >&2
    exit 8
  fi
/usr/bin/python3 - "$manifest" "$candidate" <<'PY'
import hashlib, json, pathlib, re, sys
manifest_path, runtime_root = map(pathlib.Path, sys.argv[1:])
try:
    with manifest_path.open(encoding="utf-8") as stream:
        payload = json.load(stream)
except (OSError, ValueError) as error:
    raise SystemExit(f"graphics artifact manifest is missing or invalid: {error}")
expected = {
    "framework": "lib/external/D3DMetal.framework/Versions/A/D3DMetal",
    "module": "lib/external/D3DMetal.framework/Versions/A/Resources/libYaaglNativePsoCache.dylib",
    "converter": "lib/external/D3DMetal.framework/Versions/A/Resources/libmetalirconverter.dylib",
}
manifest_schema = payload.get("schemaVersion")
if manifest_schema not in (1, 2, 3):
    raise SystemExit("graphics artifact manifest schema mismatch")
legacy_cache_contract = {"scope": "per-native-device", "readyEntryLimit": 1024}
legacy_function_cache_contract = {"scope": "per-native-device", "readyEntryLimit": 256}
device_lifetime_contract = {"scope": "per-native-device", "retention": "device-lifetime"}
if manifest_schema in (1, 2):
    if payload.get("cache") != legacy_cache_contract:
        raise SystemExit("graphics cache contract mismatch")
    if manifest_schema == 1:
        if "functionCache" in payload:
            raise SystemExit("graphics schema 1 must not declare a function cache")
    elif payload.get("functionCache") != legacy_function_cache_contract:
        raise SystemExit("graphics function cache contract mismatch")
elif payload.get("cache") != device_lifetime_contract:
    raise SystemExit("graphics cache contract mismatch")
elif payload.get("functionCache") != device_lifetime_contract:
    raise SystemExit("graphics function cache contract mismatch")
if payload.get("frameworkDependency") != "@loader_path/Resources/libYaaglNativePsoCache.dylib":
    raise SystemExit("graphics framework dependency mismatch")
artifacts = payload.get("artifacts")
if not isinstance(artifacts, dict) or set(artifacts) != set(expected):
    raise SystemExit("graphics artifact inventory mismatch")
hex_digest = re.compile(r"[0-9a-f]{64}").fullmatch
for name, path in expected.items():
    item = artifacts[name]
    if not isinstance(item, dict) or item.get("path") != path \
            or item.get("architecture") != "x86_64" or item.get("format") != "macho" \
            or item.get("signature") != "adhoc":
        raise SystemExit(f"graphics artifact identity mismatch: {name}")
    try:
        digest = hashlib.sha256((runtime_root / path).read_bytes()).hexdigest()
    except OSError as error:
        raise SystemExit(f"graphics artifact missing: {name}: {error}")
    if item.get("sha256") != digest:
        raise SystemExit(f"graphics artifact hash mismatch: {name}")
    source_field = "sourceFingerprintSha256" if name == "module" else "sourceSha256"
    required = (source_field, "preSignSha256") if name != "converter" else (source_field,)
    if any(not isinstance(item.get(field), str) or not hex_digest(item[field]) for field in required):
        raise SystemExit(f"graphics artifact source/pre-sign identity is incomplete: {name}")
if artifacts["framework"]["sourceSha256"] != "f8640e6b0974277068821d44bd398dcc0f42cbb730d07f3afad97843e72a6ea3":
    raise SystemExit("unexpected pristine GPTK D3DMetal source identity")
if artifacts["converter"]["sourceSha256"] != "5c5619ef17a7d62e84db0a7f5181d746623b47364379271fd5827e6bd961ba34":
    raise SystemExit("unexpected GPTK Metal IR converter source identity")
native_build = payload.get("nativePsoCacheBuild")
if not isinstance(native_build, dict) or native_build.get("schemaVersion") != 1 \
        or native_build.get("architecture") != "x86_64" \
        or native_build.get("deploymentTarget") != "14.0" \
        or not isinstance(native_build.get("sources"), list) or not native_build["sources"]:
    raise SystemExit("native PSO cache build provenance is missing or invalid")
source_fingerprint = hashlib.sha256()
seen_sources = set()
for source in native_build["sources"]:
    if not isinstance(source, dict) or not isinstance(source.get("path"), str) \
            or not isinstance(source.get("sha256"), str) or not hex_digest(source["sha256"]):
        raise SystemExit("native PSO cache source provenance is invalid")
    relative = pathlib.PurePosixPath(source["path"])
    if relative.is_absolute() or ".." in relative.parts or source["path"] in seen_sources:
        raise SystemExit("native PSO cache source provenance has an unsafe or duplicate path")
    seen_sources.add(source["path"])
    source_fingerprint.update(source["path"].encode("utf-8") + b"\0" + source["sha256"].encode("ascii") + b"\n")
if source_fingerprint.hexdigest() != artifacts["module"]["sourceFingerprintSha256"]:
    raise SystemExit("native PSO cache source fingerprint mismatch")
module_dependencies = artifacts["module"].get("systemDependencies")
if not isinstance(module_dependencies, list) or not module_dependencies \
        or any(not isinstance(dep, str) or not (dep.startswith("/System/") or dep.startswith("/usr/lib/"))
               for dep in module_dependencies):
    raise SystemExit("native PSO cache system dependency manifest is invalid")
compiler = native_build.get("compiler")
if not isinstance(compiler, dict) or not isinstance(compiler.get("path"), str) \
        or not isinstance(compiler.get("version"), str) or not compiler["version"] \
        or not isinstance(native_build.get("compileArgs"), list):
    raise SystemExit("native PSO cache compiler provenance is incomplete")
module = native_build.get("module")
if not isinstance(module, dict) or module.get("file") != "libYaaglNativePsoCache.dylib" \
        or module.get("sha256") != artifacts["module"]["preSignSha256"]:
    raise SystemExit("native PSO cache build module identity mismatch")
PY

fi

for artifact in "$d3dmetal" "$converter"; do
  /usr/bin/lipo -verify_arch x86_64 "$artifact" >/dev/null 2>&1 || {
    echo "graphics artifact lacks required x86_64 slice: $artifact" >&2
    exit 7
  }
  codesign --verify --strict "$artifact"
  codesign -d --verbose=4 "$artifact" 2>&1 | grep -q '^Signature=adhoc$' || {
    echo "graphics artifact does not have the expected ad hoc signature: $artifact" >&2
    exit 7
  }
done
if [ "$package_contract" = native-pso-11.17 ]; then
  /usr/bin/lipo -verify_arch x86_64 "$module" >/dev/null 2>&1 || {
    echo "graphics artifact lacks required x86_64 slice: $module" >&2
    exit 7
  }
  codesign --verify --strict "$module"
  codesign -d --verbose=4 "$module" 2>&1 | grep -q '^Signature=adhoc$' || {
    echo "graphics artifact does not have the expected ad hoc signature: $module" >&2
    exit 7
  }
fi
codesign --verify --deep --strict "$framework"
converter_inspection=$(node "$repo_dir/scripts/metalir-fp64-codec-patch.mjs" inspect "$converter")
contains_text "$converter_inspection" '"sha256": "5c5619ef17a7d62e84db0a7f5181d746623b47364379271fd5827e6bd961ba34"' || {
  echo "Metal IR converter is not the pinned GPTK 4.0 beta 2 FP64 artifact" >&2
  printf '%s\n' "$converter_inspection" >&2
  exit 7
}
contains_text "$converter_inspection" '"mode": "patched"' || {
  echo "Metal IR converter patch verification failed" >&2
  printf '%s\n' "$converter_inspection" >&2
  exit 7
}

case "$package_contract" in
  native-pso-11.17)
    contains_text "$composite_inspection" '"mode": "patched-signed"' || {
      echo "D3DMetal composite patch verification failed" >&2
      printf '%s\n' "$composite_inspection" >&2
      exit 7
    }
    [ "$dependency_count" -eq 1 ] || {
      echo "D3DMetal does not have exactly one explicit native PSO cache dependency" >&2
      exit 7
    }
    actual_module_dependencies=$(otool -arch x86_64 -l "$module" 2>/dev/null | awk '
      $1 == "cmd" { load = ($2 == "LC_LOAD_DYLIB"); next }
      load && $1 == "name" { print $2; load = 0 }
    ')
    [ -n "$actual_module_dependencies" ] || {
      echo "native PSO cache has no recorded system dependencies" >&2
      exit 7
    }
    printf '%s\n' "$actual_module_dependencies" | awk '
      !/^\/System\// && !/^\/usr\/lib\// {
        print "native PSO cache has non-system dependency: " $0 > "/dev/stderr"
        bad = 1
      }
      END { if (bad) exit 1 }
    '
    expected_module_dependencies=$(/usr/bin/python3 - "$manifest" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    print("\n".join(json.load(stream)["artifacts"]["module"]["systemDependencies"]))
PY
    )
    [ "$actual_module_dependencies" = "$expected_module_dependencies" ] || {
      echo "native PSO cache system dependency inventory mismatch" >&2
      exit 7
    }
    ;;
  stage-only-11.17)
    contains_text "$composite_inspection" '"mode": "stage-patched-signed"' || {
      echo "D3DMetal stage-only patch verification failed" >&2
      printf '%s\n' "$composite_inspection" >&2
      exit 7
    }
    ;;
  legacy-11.0)
    # Legacy builders predate the stage/composite patch layout. Their exact
    # D3DMetal state remains guarded by its framework signature and builder
    # contract rather than being misclassified as a pristine modern binary.
    ;;
esac
if [ "$("$candidate/bin/wine" --version)" != "$expected_version" ]; then
  echo "unexpected Wine version" >&2
  exit 8
fi
expected_d3dmetal_sha=$(shasum -a 256 "$d3dmetal" | awk '{print $1}')
expected_converter_sha=$(shasum -a 256 "$converter" | awk '{print $1}')
expected_module_sha=
expected_manifest_sha=
expected_provenance_sha=
if [ "$package_contract" != legacy-11.0 ]; then
  expected_provenance_sha=$(shasum -a 256 "$provenance" | awk '{print $1}')
fi
if [ "$package_contract" = native-pso-11.17 ]; then
  expected_module_sha=$(shasum -a 256 "$module" | awk '{print $1}')
  expected_manifest_sha=$(shasum -a 256 "$manifest" | awk '{print $1}')
fi

# Recheck exact active-runtime binaries immediately before the flip. Wine-hosted
# processes may have arbitrary Windows command names and evade the pgrep gate.
active_holders=$(lsof \
  "$active/bin/wine" \
  "$active/bin/wine.real" \
  "$active/bin/wineserver" \
  "$active/lib/wine/x86_64-unix/ntdll.so" \
  "$active/lib/wine/x86_64-unix/winemac.so" 2>/dev/null || true)
if [ -n "$active_holders" ]; then
  echo "Yaagl Wine runtime files are still in use; quit the game and launcher before installing" >&2
  printf '%s\n' "$active_holders" >&2
  exit 4
fi

mkdir -p "$(dirname -- "$recovery")"
mv "$active" "$recovery"
if ! mv "$candidate" "$active"; then
  if ! mv "$recovery" "$active"; then
    echo "installation failed and the prior runtime could not be restored; recovery remains at $recovery" >&2
    exit 9
  fi
  echo "installation failed before activation; the prior runtime was restored" >&2
  exit 9
fi
if ! (
  [ "$("$active/bin/wine" --version)" = "$expected_version" ] &&
  [ "$(shasum -a 256 "$active/lib/external/D3DMetal.framework/Versions/A/D3DMetal" | awk '{print $1}')" = "$expected_d3dmetal_sha" ] &&
  [ "$(shasum -a 256 "$active/lib/external/D3DMetal.framework/Versions/A/Resources/libmetalirconverter.dylib" | awk '{print $1}')" = "$expected_converter_sha" ] &&
  case "$package_contract" in
    native-pso-11.17)
      [ "$(shasum -a 256 "$active/yaagl-wine-p3-provenance.json" | awk '{print $1}')" = "$expected_provenance_sha" ] &&
      [ "$(shasum -a 256 "$active/lib/external/D3DMetal.framework/Versions/A/Resources/libYaaglNativePsoCache.dylib" | awk '{print $1}')" = "$expected_module_sha" ] &&
      [ "$(shasum -a 256 "$active/yaagl-wine-p3-graphics-artifacts.json" | awk '{print $1}')" = "$expected_manifest_sha" ] &&
      /usr/bin/python3 - "$active/yaagl-wine-p3-graphics-artifacts.json" "$active" <<'PY'
import hashlib, json, pathlib, sys
manifest_path, runtime_root = map(pathlib.Path, sys.argv[1:])
with manifest_path.open(encoding="utf-8") as stream:
    artifacts = json.load(stream)["artifacts"]
expected = {
    "framework": "lib/external/D3DMetal.framework/Versions/A/D3DMetal",
    "module": "lib/external/D3DMetal.framework/Versions/A/Resources/libYaaglNativePsoCache.dylib",
    "converter": "lib/external/D3DMetal.framework/Versions/A/Resources/libmetalirconverter.dylib",
}
for name, relative in expected.items():
    if artifacts[name]["path"] != relative:
        raise SystemExit(f"activated graphics artifact path mismatch: {name}")
    digest = hashlib.sha256((runtime_root / relative).read_bytes()).hexdigest()
    if artifacts[name]["sha256"] != digest:
        raise SystemExit(f"activated graphics artifact hash mismatch: {name}")
PY
      ;;
    stage-only-11.17)
      [ "$(shasum -a 256 "$active/yaagl-wine-p3-provenance.json" | awk '{print $1}')" = "$expected_provenance_sha" ] &&
      active_composite_inspection=$(node "$repo_dir/scripts/d3dmetal-pso-cache-patch.mjs" inspect \
        "$active/lib/external/D3DMetal.framework/Versions/A/D3DMetal") &&
      contains_text "$active_composite_inspection" '"mode": "stage-patched-signed"'
      ;;
    legacy-11.0)
      [ ! -e "$active/yaagl-wine-p3-provenance.json" ]
      ;;
  esac
)
then
  if ! mv "$active" "$candidate"; then
    echo "post-activation verification failed and the rejected runtime could not be moved aside; recovery remains at $recovery" >&2
    exit 9
  fi
  if ! mv "$recovery" "$active"; then
    echo "post-activation verification failed and the prior runtime could not be restored; recovery remains at $recovery" >&2
    exit 9
  fi
  echo "post-activation graphics verification failed; the prior runtime was restored" >&2
  exit 9
fi
rmdir "$staging"
trap - EXIT HUP INT TERM
printf 'Installed: %s\nRecovery: %s\nArchive SHA-256: %s\n' "$active" "$recovery" "$actual_archive_sha"
