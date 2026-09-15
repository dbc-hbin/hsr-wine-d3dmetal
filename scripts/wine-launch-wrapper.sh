#!/bin/sh
set -eu

wrapper_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
real_wine="$wrapper_dir/wine.real"
[ -x "$real_wine" ] || { echo "HSR Wine runtime: missing $real_wine" >&2; exit 126; }
wine_root=$(CDPATH= cd -- "$wrapper_dir/.." && pwd)

# Fixed HSR profile: patched D3DMetal stage/PSO cache with official, unmodified
# MetalIR. HSR remains on its supported D3D11 path; do not add DX12 arguments.
export CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal
export WINEMSYNC=1
export D3DM_MTL4=1
export D3DM_ENABLE_METALFX=1
export YAAGL_METALFX_EXPOSURE_SCALE_FIX=1
export D3DM_SUPPORT_DXR=1
export D3DM_VENDOR_ID=0x10de
export D3DM_DEVICE_ID=0x2d05
export D3DM_DEVICE_DESCRIPTION="NVIDIA GeForce RTX 5060"
export YAAGL_D3DMETAL_CACHE_WARMUP=1
export CX_APPLEGPTK_LIBD3DSHARED_PATH="$wine_root/lib/external/libd3dshared.dylib"
export D3DMETAL_FRAMEWORK_PATH="$wine_root/lib/external/D3DMetal.framework/Versions/A/D3DMetal"
export WINEDLLOVERRIDES=d3d11,dxgi=b
unset WINEDLLPATH_PREPEND DXMT_CONFIG DXMT_CONFIG_FILE
unset DXVK_CONFIG_FILE DXVK_STATE_CACHE_PATH VK_ICD_FILENAMES VK_DRIVER_FILES DYLD_INSERT_LIBRARIES

wine_lib="$wine_root/lib"
gst_root="$wine_lib/GStreamer.framework/Versions/1.0"
dyld_fallback="$wine_lib"
[ ! -d "$gst_root/lib" ] || dyld_fallback="$gst_root/lib:$dyld_fallback"
if [ -n "${DYLD_FALLBACK_LIBRARY_PATH:-}" ]; then
  export DYLD_FALLBACK_LIBRARY_PATH="$dyld_fallback:$DYLD_FALLBACK_LIBRARY_PATH"
else
  export DYLD_FALLBACK_LIBRARY_PATH="$dyld_fallback"
fi
[ ! -d "$gst_root/lib/gstreamer-1.0" ] || export GST_PLUGIN_SYSTEM_PATH_1_0="$gst_root/lib/gstreamer-1.0"
[ ! -x "$gst_root/libexec/gstreamer-1.0/gst-plugin-scanner" ] || export GST_PLUGIN_SCANNER="$gst_root/libexec/gstreamer-1.0/gst-plugin-scanner"

exec "$real_wine" "$@"
