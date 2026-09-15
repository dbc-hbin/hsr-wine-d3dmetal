#!/bin/sh
# Build the HSR runtime from a Wine 11.17 base and the official GPTK 4.0b2 redist.
# The deployed runtime ID/archive retain their legacy "stock" compatibility names;
# the actual graphics profile is zzz-cache-no-fp64.
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ "$#" -ge 2 ] && [ "$#" -le 3 ] || { echo "usage: $0 WINE_BASE GPTK_DMG_OR_REDIST [OUTPUT_DIR]" >&2; exit 2; }
base=$1
gptk_input=$2
output_dir=${3:-"$repo_dir/build/hsr-runtime"}
archive_name=wine-11.17-hsr-gptk4b2-stock.tar.xz
runtime_id=11.17-hsr-gptk4b2-stock
profile=zzz-cache-no-fp64
stock_d3dmetal_sha=f5b56df1b8fe8b364dd9530651a3769c8aed948bd343be3b4510604d503e2bad
stock_converter_sha=75974d49ad4dd1bdf17ab3cd666ae7cac43e7f7a5760237699ab33ecd3d31daf
stock_shared_sha=1582e7ceef7f495df4bebf7f06a49aef130233f8a2e9a8971e35affafeb76ec0
work=$(mktemp -d "${TMPDIR:-/tmp}/hsr-wine-package.XXXXXX")
mounted_outer=
mounted_inner=
cleanup() {
  [ -z "$mounted_inner" ] || hdiutil detach "$mounted_inner" >/dev/null 2>&1 || true
  [ -z "$mounted_outer" ] || hdiutil detach "$mounted_outer" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM
fail() { echo "package-hsr-runtime: $*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
mount_image() {
  plist=$(hdiutil attach -readonly -nobrowse -plist "$1")
  printf '%s' "$plist" | plutil -extract system-entities xml1 -o - - | /usr/bin/python3 -c 'import plistlib,sys; print(next(x["mount-point"] for x in plistlib.load(sys.stdin.buffer) if "mount-point" in x))'
}

case "$base" in
  *.tar.xz) mkdir -p "$work/base"; tar -xJf "$base" -C "$work/base"; wine_base="$work/base/wine" ;;
  *) wine_base=$base ;;
esac
[ -x "$wine_base/bin/wine" ] || fail "Wine base does not contain executable bin/wine: $wine_base"
[ -x "$wine_base/bin/wineserver" ] || fail "Wine base does not contain executable bin/wineserver: $wine_base"
/usr/bin/python3 "$repo_dir/scripts/validate-runtime-deployment-target.py" "$wine_base" --maximum 26.0

if [ -d "$gptk_input" ]; then
  redist=$gptk_input
else
  [ -f "$gptk_input" ] || fail "GPTK input not found: $gptk_input"
  mounted_outer=$(mount_image "$gptk_input")
  if [ -d "$mounted_outer/redist" ]; then redist="$mounted_outer/redist"; else
    nested="$mounted_outer/Evaluation environment for Windows games 4.0 beta 2.dmg"
    [ -f "$nested" ] || fail "official GPTK 4.0b2 evaluation image not found inside DMG"
    mounted_inner=$(mount_image "$nested")
    redist="$mounted_inner/redist"
  fi
fi
framework="$redist/lib/external/D3DMetal.framework"
d3dmetal="$framework/Versions/A/D3DMetal"
converter="$framework/Versions/A/Resources/libmetalirconverter.dylib"
shared="$redist/lib/external/libd3dshared.dylib"
[ -d "$framework" ] || fail "GPTK redist is missing D3DMetal.framework"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$framework/Versions/A/Resources/Info.plist" 2>/dev/null || true)" = 4.0b2 ] || fail "expected GPTK D3DMetal 4.0b2"
[ "$(sha "$d3dmetal")" = "$stock_d3dmetal_sha" ] || fail "official D3DMetal hash mismatch"
[ "$(sha "$converter")" = "$stock_converter_sha" ] || fail "MetalIR must be the unmodified official converter (FP64 patch is forbidden)"
[ "$(sha "$shared")" = "$stock_shared_sha" ] || fail "official libd3dshared hash mismatch"
codesign --verify --deep --strict "$framework"
codesign --verify --strict "$shared"

windows='d3d10.dll d3d11.dll d3d12.dll dxgi.dll nvapi64.dll nvngx-on-metalfx.dll'
unix='d3d10.so d3d11.so d3d12.so dxgi.so nvapi64.so nvngx-on-metalfx.so'
for name in $windows; do [ -f "$redist/lib/wine/x86_64-windows/$name" ] || fail "missing official PE: $name"; done
for name in $unix; do
  path="$redist/lib/wine/x86_64-unix/$name"
  [ -L "$path" ] || fail "official bridge is not a symlink: $name"
  [ "$(readlink "$path")" = ../../external/libd3dshared.dylib ] || fail "unexpected bridge target: $name"
done

mkdir -p "$work/stage/wine"
ditto "$wine_base" "$work/stage/wine"
rm -rf "$work/stage/wine/lib/external/D3DMetal.framework"
mkdir -p "$work/stage/wine/lib/external" "$work/stage/wine/lib/wine/x86_64-windows" "$work/stage/wine/lib/wine/x86_64-unix"
ditto "$framework" "$work/stage/wine/lib/external/D3DMetal.framework"
ditto "$shared" "$work/stage/wine/lib/external/libd3dshared.dylib"
for name in $windows; do ditto "$redist/lib/wine/x86_64-windows/$name" "$work/stage/wine/lib/wine/x86_64-windows/$name"; done
for name in $unix; do rm -f "$work/stage/wine/lib/wine/x86_64-unix/$name"; ln -s ../../external/libd3dshared.dylib "$work/stage/wine/lib/wine/x86_64-unix/$name"; done

pso_dir="$work/native-pso-cache"
node "$repo_dir/scripts/build-d3dmetal-pso-cache.mjs" "$pso_dir"
pso_module="$pso_dir/libYaaglNativePsoCache.dylib"
[ -f "$pso_module" ] || fail "native production cache module was not produced"
staged_framework="$work/stage/wine/lib/external/D3DMetal.framework"
staged_d3dmetal="$staged_framework/Versions/A/D3DMetal"
staged_converter="$staged_framework/Versions/A/Resources/libmetalirconverter.dylib"
staged_module="$staged_framework/Versions/A/Resources/libYaaglNativePsoCache.dylib"
ditto "$pso_module" "$staged_module"
patched_d3dmetal="$work/D3DMetal.patched"
node "$repo_dir/scripts/d3dmetal-pso-cache-patch.mjs" patch "$staged_d3dmetal" "$patched_d3dmetal" >/dev/null
mv "$patched_d3dmetal" "$staged_d3dmetal"
node "$repo_dir/scripts/d3dmetal-pso-cache-patch.mjs" inspect "$staged_d3dmetal" | grep -q '"mode": "patched"' || fail "D3DMetal stage/PSO patch validation failed"
[ "$(sha "$staged_converter")" = "$stock_converter_sha" ] || fail "MetalIR bytes changed before signing"
codesign --remove-signature "$staged_d3dmetal"
codesign --force --sign - "$staged_module"
codesign --force --sign - "$staged_d3dmetal"
codesign --force --sign - "$staged_framework"
codesign --verify --deep --strict "$staged_framework"
node "$repo_dir/scripts/d3dmetal-pso-cache-patch.mjs" inspect "$staged_d3dmetal" | grep -q '"mode": "patched-signed"' || fail "signed D3DMetal patch validation failed"
[ "$(sha "$staged_converter")" = "$stock_converter_sha" ] || fail "framework signing changed official MetalIR bytes"

if [ ! -x "$work/stage/wine/bin/wine.real" ]; then
  mv "$work/stage/wine/bin/wine" "$work/stage/wine/bin/wine.real"
fi
install -m 755 "$repo_dir/scripts/wine-launch-wrapper.sh" "$work/stage/wine/bin/wine"
rm -f "$work/stage/wine/yaagl-wine-p3-"*.json "$work/stage/wine/yaagl-wine-p3-"*.txt "$work/stage/wine/yaagl-wine-runtime-files.json"
cat > "$work/stage/wine/yaagl-hsr-graphics-profile.json" <<EOF
{"schemaVersion":1,"profile":"$profile","d3dMetal":"4.0b2-stage-pso-cache-ngx-metalfx-hooks","metalIR":"official-unmodified-no-fp64","cache":{"inMemoryObjects":true,"functions":true,"stages":true,"diskWarmup":"advisory-existing-files-only","persistentStore":false},"runtimeId":"$runtime_id","legacyCompatibilityName":true}
EOF
/usr/bin/python3 "$repo_dir/scripts/write-wine-runtime-manifest.py" "$work/stage/wine" "$runtime_id" wine-11.17 >/dev/null
/usr/bin/python3 "$repo_dir/scripts/validate-runtime-deployment-target.py" "$work/stage/wine" --maximum 26.0
[ "$(sha "$staged_converter")" = "$stock_converter_sha" ] || fail "final MetalIR FP64-exclusion assertion failed"
for name in $unix; do [ "$(readlink "$work/stage/wine/lib/wine/x86_64-unix/$name")" = ../../external/libd3dshared.dylib ] || fail "final bridge mismatch: $name"; done
mkdir -p "$output_dir"
rm -rf "$output_dir/stage"
ditto "$work/stage" "$output_dir/stage"
archive="$output_dir/$archive_name"
COPYFILE_DISABLE=1 XZ_OPT='-T0 -3' tar -C "$work/stage" -cJf "$archive" wine
(cd "$output_dir" && shasum -a 256 "$archive_name" > "$archive_name.sha256")
printf 'Profile: %s\nArchive: %s\nSHA-256: %s\nMetalIR SHA-256: %s (official, unmodified, no FP64 patch)\n' "$profile" "$archive" "$(sha "$archive")" "$(sha "$staged_converter")"
