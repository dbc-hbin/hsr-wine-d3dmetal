#!/bin/sh
# Build the HSR runtime from a Wine 11.17 base and Apple's unmodified GPTK 4.0b2 redist.
# Usage: package-hsr-stock-runtime.sh WINE_BASE GPTK_DMG_OR_REDIST [OUTPUT_DIR]
# WINE_BASE is either a wine/ directory or a .tar.xz whose root is wine/.
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ "$#" -ge 2 ] && [ "$#" -le 3 ] || { echo "usage: $0 WINE_BASE GPTK_DMG_OR_REDIST [OUTPUT_DIR]" >&2; exit 2; }
base=$1
gptk_input=$2
output_dir=${3:-"$repo_dir/build/hsr-runtime"}
archive_name=wine-11.17-hsr-gptk4b2-stock.tar.xz
runtime_id=11.17-hsr-gptk4b2-stock
work=$(mktemp -d "${TMPDIR:-/tmp}/hsr-wine-package.XXXXXX")
mounted_outer=
mounted_inner=
cleanup() {
  [ -z "$mounted_inner" ] || hdiutil detach "$mounted_inner" >/dev/null 2>&1 || true
  [ -z "$mounted_outer" ] || hdiutil detach "$mounted_outer" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM
fail() { echo "package-hsr-stock-runtime: $*" >&2; exit 1; }
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
  if [ -d "$mounted_outer/redist" ]; then
    redist="$mounted_outer/redist"
  else
    nested="$mounted_outer/Evaluation environment for Windows games 4.0 beta 2.dmg"
    [ -f "$nested" ] || fail "official GPTK 4.0b2 evaluation image not found inside DMG"
    mounted_inner=$(mount_image "$nested")
    redist="$mounted_inner/redist"
  fi
fi
[ -d "$redist/lib/external/D3DMetal.framework" ] || fail "GPTK redist is missing D3DMetal.framework"
for arch in x86_64-windows x86_64-unix; do
  case "$arch" in
    x86_64-windows) expected="d3d10.dll d3d11.dll d3d12.dll dxgi.dll nvapi64.dll nvngx-on-metalfx.dll" ;;
    x86_64-unix) expected="d3d10.so d3d11.so d3d12.so dxgi.so nvapi64.so nvngx-on-metalfx.so" ;;
  esac
  actual=$(find "$redist/lib/wine/$arch" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
  [ "$actual" = "$expected" ] || fail "unexpected GPTK redist $arch inventory: $actual"
done

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$redist/lib/external/D3DMetal.framework/Versions/A/Resources/Info.plist" 2>/dev/null || true)
[ "$version" = 4.0b2 ] || fail "expected GPTK D3DMetal 4.0b2, found ${version:-unknown}"

# These hashes are from the official GPTK 4.0 beta 2 evaluation redist. They
# reject the inherited FP64 converter and D3DMetal/PSO bridge modifications.
while read -r expected relative; do
  [ -f "$redist/lib/$relative" ] || fail "missing stock GPTK file: $relative"
  [ "$(sha "$redist/lib/$relative")" = "$expected" ] || fail "stock GPTK hash mismatch: $relative"
done <<'HASHES'
f5b56df1b8fe8b364dd9530651a3769c8aed948bd343be3b4510604d503e2bad external/D3DMetal.framework/Versions/A/D3DMetal
75974d49ad4dd1bdf17ab3cd666ae7cac43e7f7a5760237699ab33ecd3d31daf external/D3DMetal.framework/Versions/A/Resources/libmetalirconverter.dylib
1582e7ceef7f495df4bebf7f06a49aef130233f8a2e9a8971e35affafeb76ec0 external/libd3dshared.dylib
14c84a364a1260497f0a5117ef8efd6e228764ab139a67af1127e8bd013c48c7 wine/x86_64-windows/d3d10.dll
303b2bb41efa30c890e2e93d39c3d3c565c8557e069eee832f2cb8a37bd4ec26 wine/x86_64-windows/d3d11.dll
1b7a02cb37ec6b484e2aaa76b5ec9cbb47e63aeec29dbe087d5d1589a3347cfb wine/x86_64-windows/d3d12.dll
522a8b37216afb09e614489d88a74118076f4d7e08d2b289df6a6eb6f3e817af wine/x86_64-windows/dxgi.dll
05eedf19e75c6b4c0dce918577aa6ca3fe5da79d04e42145cf66f498fad3556a wine/x86_64-windows/nvapi64.dll
f6bc9d77fd1e898fec8c6339d367bd8e0f338992c9c0c66d59b30c6e9e0743e4 wine/x86_64-windows/nvngx-on-metalfx.dll
1582e7ceef7f495df4bebf7f06a49aef130233f8a2e9a8971e35affafeb76ec0 wine/x86_64-unix/d3d10.so
1582e7ceef7f495df4bebf7f06a49aef130233f8a2e9a8971e35affafeb76ec0 wine/x86_64-unix/d3d11.so
1582e7ceef7f495df4bebf7f06a49aef130233f8a2e9a8971e35affafeb76ec0 wine/x86_64-unix/d3d12.so
1582e7ceef7f495df4bebf7f06a49aef130233f8a2e9a8971e35affafeb76ec0 wine/x86_64-unix/dxgi.so
1582e7ceef7f495df4bebf7f06a49aef130233f8a2e9a8971e35affafeb76ec0 wine/x86_64-unix/nvapi64.so
1582e7ceef7f495df4bebf7f06a49aef130233f8a2e9a8971e35affafeb76ec0 wine/x86_64-unix/nvngx-on-metalfx.so
HASHES
codesign --verify --deep --strict "$redist/lib/external/D3DMetal.framework"
codesign --verify --strict "$redist/lib/external/libd3dshared.dylib"

mkdir -p "$work/stage"
ditto "$wine_base" "$work/stage/wine"
rm -rf "$work/stage/wine/lib/external/D3DMetal.framework"
mkdir -p "$work/stage/wine/lib/external"
ditto "$redist/lib/external/D3DMetal.framework" "$work/stage/wine/lib/external/D3DMetal.framework"
ditto "$redist/lib/external/libd3dshared.dylib" "$work/stage/wine/lib/external/libd3dshared.dylib"
for name in d3d10.dll d3d11.dll d3d12.dll dxgi.dll nvapi64.dll nvngx-on-metalfx.dll; do
  ditto "$redist/lib/wine/x86_64-windows/$name" "$work/stage/wine/lib/wine/x86_64-windows/$name"
done
for name in d3d10.so d3d11.so d3d12.so dxgi.so nvapi64.so nvngx-on-metalfx.so; do
  relative="x86_64-unix/$name"
  [ -L "$redist/lib/wine/$relative" ] || fail "stock GPTK bridge is not a symlink: $relative"
  [ "$(readlink "$redist/lib/wine/$relative")" = ../../external/libd3dshared.dylib ] || fail "unexpected stock GPTK bridge target: $relative"
  rm -f "$work/stage/wine/lib/wine/$relative"
  ln -s ../../external/libd3dshared.dylib "$work/stage/wine/lib/wine/$relative"
done
rm -f "$work/stage/wine/lib/external/D3DMetal.framework/Versions/A/Resources/libYaaglNativePsoCache.dylib"
rm -f "$work/stage/wine/yaagl-wine-p3-graphics-artifacts.json" "$work/stage/wine/yaagl-wine-runtime-files.json"
rm -f "$work/stage/wine/yaagl-wine-p3-runtime.txt" "$work/stage/wine/yaagl-wine-split-core-files.json"
if [ -x "$work/stage/wine/bin/wine.real" ]; then
  install -m 755 "$repo_dir/scripts/wine-launch-wrapper.sh" "$work/stage/wine/bin/wine"
fi
/usr/bin/python3 "$repo_dir/scripts/write-wine-runtime-manifest.py" "$work/stage/wine" "$runtime_id" wine-11.17 >/dev/null
/usr/bin/python3 "$repo_dir/scripts/validate-runtime-deployment-target.py" "$work/stage/wine" --maximum 26.0
codesign --verify --deep --strict "$work/stage/wine/lib/external/D3DMetal.framework"
[ "$(sha "$work/stage/wine/lib/external/D3DMetal.framework/Versions/A/D3DMetal")" = f5b56df1b8fe8b364dd9530651a3769c8aed948bd343be3b4510604d503e2bad ] || fail "staged D3DMetal changed"
[ "$(sha "$work/stage/wine/lib/external/D3DMetal.framework/Versions/A/Resources/libmetalirconverter.dylib")" = 75974d49ad4dd1bdf17ab3cd666ae7cac43e7f7a5760237699ab33ecd3d31daf ] || fail "staged MetalIR converter changed"
mkdir -p "$output_dir"
COPYFILE_DISABLE=1 XZ_OPT='-T0 -3' tar -C "$work/stage" -cJf "$output_dir/$archive_name" wine
(cd "$output_dir" && shasum -a 256 "$archive_name" > "$archive_name.sha256")
printf 'Archive: %s\nSHA-256: %s\n' "$output_dir/$archive_name" "$(sha "$output_dir/$archive_name")"
