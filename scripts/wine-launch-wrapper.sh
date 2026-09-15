#!/bin/sh
set -eu

wrapper_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
real_wine="$wrapper_dir/wine.real"
[ -x "$real_wine" ] || { echo "HSR Wine runtime: missing $real_wine" >&2; exit 126; }
wine_root=$(CDPATH= cd -- "$wrapper_dir/.." && pwd)

# HSR uses Apple's stock D3DMetal through Direct3D 11. Do not inject DXMT,
# patched MetalIR/PSO helpers, or a Direct3D 12 launch argument here.
export CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal
export WINEMSYNC=1
export CX_APPLEGPTK_LIBD3DSHARED_PATH="$wine_root/lib/external/libd3dshared.dylib"
export D3DMETAL_FRAMEWORK_PATH="$wine_root/lib/external/D3DMetal.framework/Versions/A/D3DMetal"
unset D3DM_MTL4 D3DM_ENABLE_METALFX D3DM_SUPPORT_DXR D3DM_VENDOR_ID D3DM_DEVICE_ID D3DM_DEVICE_DESCRIPTION
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
