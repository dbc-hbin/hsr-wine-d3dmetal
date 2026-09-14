# zzz-wine-d3dmetal-dx12

**English** | [한국어 (Korean)](README.ko.md)

Optimized Wine 11.17 runtime source code and easy 1-click GUI installer for playing **Zenless Zone Zero (ZZZ)** with **Direct3D 12 (Apple GPTK 4.0b2)** on macOS (Apple Silicon) via **Yaagl ZZZ OS**.

The installer installs the included prebuilt Wine package and registers **`Wine 11.17 ZZZ DX12 (GPTK4.0b2)`** in Yaagl's Wine menu.

**Deployment target: macOS 26.0 or later on Apple Silicon, with Rosetta 2.** v1.0.2 rebuilds 45 Wine artifacts from fresh build directories; the seven rebuilt native modules target macOS 26.0 using SDK 26.5. The remaining Wine files are inherited from the pinned P3 package. Tuned patches, native PSO caching, and `D3DM_MTL4=1` are unchanged.

`libdxccontainer.dylib` is required by D3DMetal for DXIL container parsing and DXBC/HLSL conversion. Its original Apple binary is retained byte-for-byte, including its recorded minimum version of 26.4; no 26.4-only imported API was identified. The Wine configuration batch and DX12 graphics/compute/ray-tracing GPU readbacks passed on macOS 27. **Execution on macOS 26 hardware has not yet been verified.**

---

## ⚡ Quick Start (Easy 1-Click GUI Installer)

You do not need to build from source. An easy native macOS GUI installer is included to set up everything automatically.

### Option 1: Native GUI Installer (Recommended)
1. Download [ZZZWineDX12Installer.zip](https://github.com/dbc-hbin/zzz-wine-d3dmetal-dx12/releases/latest/download/ZZZWineDX12Installer.zip).
2. Extract the zip and open **`ZZZ Wine DX12 Installer.app`**.
3. The app automatically detects your Yaagl ZZZ OS app and data folders.
4. Quit Yaagl ZZZ OS, then click **`Install Wine 11.17 ZZZ DX12`**.
   - Installs the included prebuilt Wine runtime archive for Yaagl.
   - Registers **`Wine 11.17 ZZZ DX12 (GPTK4.0b2)`** in Yaagl's Wine menu.
   - Backs up Yaagl's resources, Wine selection, and Wine directory so the prior configuration can be restored.
5. Launch Yaagl ZZZ OS and select the installed Wine runtime from its Wine menu!

The included archive remains in Yaagl's local runtime storage, so you can select this Wine runtime or switch back to another Wine runtime from Yaagl's Wine menu while offline. The installer does not require Node.js.

### v1.0.4: DX12 launch argument delivery

- Preserve the selected distribution identity in the actual Wine runner and add `-use-d3d12` **only for `Wine 11.17 ZZZ DX12 (GPTK4.0b2)`**. Earlier installers checked an absent runner `id`, so a successfully applied patch could still omit the argument.
- Forward game arguments through both normal and Steam-patch launches. Other D3DMetal Wine distributions are not forced to DX12.
- Replace the old ID guard and the legacy local backend-wide guard with the scoped condition; repeated installation does not duplicate the argument.

**Existing users: quit Yaagl, reinstall with the v1.0.4 installer, and select this Wine.** Replacing the Wine archive alone does not fix the launcher. The installer and update helper were rebuilt; the bundled Wine archive is unchanged from v1.0.2/v1.0.3. DX12 execution on physical Tahoe hardware remains unverified.

### v1.0.3: launcher updates and restore

v1.0.3 changes the installer only. The bundled macOS 26 Wine archive and tuning are unchanged from v1.0.2.

- Registration patches the active `resources.neu` in Yaagl’s data folder, not the app bundle. App resources and legacy app backups remain untouched; startup synchronization cannot copy the older app resource over the registered frontend.
- A native helper in `.zzz-wine-registration` registers Wine in downloaded in-app updates before they replace the active frontend. It runs only during installation or an in-app update; there is no background service and Node.js is not required. Unsupported frontend layouts or helper failures stop the update before replacement.
- Restore uses the pristine resource for the currently registered generation, never an older whole-resource backup. Preparing another update does not change the active generation’s restore point.

If an earlier installer already downgraded Yaagl, update Yaagl to the desired version first, quit it, then use the latest installer. Full app replacements or externally replaced resources can bypass the in-app hook; run the installer again after those changes.

### Option 2: Terminal CLI
```bash
./installer/zzz-wine-installer --install \
  --app-path "/Applications/Yaagl ZZZ OS.app" \
  --support-path "$HOME/Library/Application Support/Yaagl ZZZ OS"

# Restore the previous Wine directory
./installer/zzz-wine-installer --restore \
  --app-path "/Applications/Yaagl ZZZ OS.app" \
  --support-path "$HOME/Library/Application Support/Yaagl ZZZ OS"
```

---

## 🚀 Key Optimizations & Patches

This build integrates several targeted patches into upstream Wine 11.17 to ensure maximum performance and stability for ZZZ on Apple Silicon.

### 1. Direct3D 12 & Apple GPTK 4.0b2 Integration
- Integrated with Apple's Game Porting Toolkit 4.0b2 D3DMetal and Metal IR translation layer.
- Fast, high-accuracy translation of DirectX 12 rendering pipelines into native Metal APIs.

### 2. Apple Silicon Native ARM64 Wineserver (`0002-native-x86-server.patch`)
- Upstream x86_64 Wine runs `wineserver` through Rosetta 2 translation, which introduces significant system-call and IPC latency.
- This build runs `wineserver` natively on Apple Silicon (ARM64), drastically reducing thread synchronization and inter-process communication overhead.

### 3. High-Performance MSync Fast Paths (`0001`, `0003`, `0007`, `0012`)
- Maps Windows synchronization primitives (Mutexes, Events, Semaphores) directly onto low-overhead macOS Mach semaphores and shared memory.
- Minimizes thread wait times and kernel context-switch penalties during heavy multi-threaded rendering.

### 4. Metal PSO Cache & Cache Warmup (`libYaaglNativePsoCache`)
- Dedicated native cache layer to eliminate in-game **micro-stutters** caused by runtime pipeline state object (PSO) and shader compilation.
- Dedupes shader compilation and retains compiled PSOs across the device lifetime.
- Cache warmup ensures smooth combat and scene transitions from the very first run.

### 5. Cursor Ownership & RawInput Separation (`0004-macdrv-reset-rawinput-baseline.patch`)
- Preserves native cursor display and window routing while making ownership synchronization independent of cursor position.
- Sends warp-corrected mouse deltas separately from pointer coordinates, preserving fractional motion and event coalescing without dropping the first real movement.
- The updated source uses server protocol **966**; rebuild matching Wine client/server modules together. The bundled installer/runtime has not been rebuilt with this change.
- Run `node scripts/wine-mac-cursor-input-regression.mjs` for extracted-production input checks. These do not replace native cursor-pixel or in-game camera verification.

### 6. Media, Audio, Window & System Resource Tuning (`0005`, `0006`, `0008` ~ `0014`)
- **Media Playback**: GStreamer and Media Foundation optimizations prevent cutscene stutters.
- **Low-Latency Audio**: Refined CoreAudio buffering reduces audio delay.
- **Window & Network**: Tuned window message queue and socket handling for faster response.

---

## 📂 Repository Structure

```
zzz-wine-d3dmetal-dx12/
├── external/               # Original Apple GPTK 4.0b2 D3DMetal.framework
│   └── D3DMetal.framework  # D3DMetal binary and libmetalirconverter.dylib
├── dlls/                   # Wine 11.17 modified DLL sources
├── server/                 # ARM64 native wineserver & msync implementation
├── include/                # Additional headers (msync.h, server_protocol.h)
├── d3dmetal-pso-cache/     # libYaaglNativePsoCache Objective-C++ source
├── patches/                # Full patch series (0001 ~ 0014)
│   ├── wine-tuned/         # 14 tuned performance and bugfix patches
│   └── wine-p3/            # Baseline host msync & D3DMetal bridge patches
├── scripts/                # Wine build and packaging scripts
└── installer/              # SwiftUI native installer source & build artifacts
    ├── ZZZ Wine DX12 Installer.app  # Pre-built native macOS app bundle
    ├── zzz-wine-installer           # CLI binary
    ├── RuntimePackage.swift         # Prebuilt Wine package metadata
    ├── AsarPatcher.swift            # Yaagl Wine menu registration patcher
    ├── InstallerEngine.swift        # Auto-detect, install, register & restore engine
    ├── ContentView.swift            # SwiftUI interface
    └── resources/typescript.js      # Bundled JavaScript compiler for menu patching
```

---

## 🛠️ Building From Source

### Prerequisites
- macOS 26.0 or later (Apple Silicon M-series), Rosetta 2, and a macOS 26 SDK
- Xcode Command Line Tools (`xcode-select --install`)
- LLVM MinGW toolchain (`/opt/llvm-mingw-...`)
- Bison, Pkg-config, GStreamer dependencies
- Prepared P3 source, host, dependency tree and provenance; a local GPTK overlay and Steam helper payload. These external build inputs are not downloaded by this repository.

### Build Commands
```bash
# Set these to your existing, verified local input directories.
export WINE_P3_ROOT="/absolute/path/to/prepared/wine-p3"
export YAAGL_STEAM_HELPER_DIR="/absolute/path/to/protonextras"
export GPTK_SOURCE="/absolute/path/to/gptk-overlay/wine"
export MACOSX_DEPLOYMENT_TARGET=26.0
export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
export WINE_PACKAGE_NAME=wine-11.17-zzz-dx12-gptk4b2-macos26
export WINE_RUNTIME_ID=11.17-zzz-dx12-tuned-stage-parallel-cache-warmup-cursor-rollback-gptk4b2-arm64server

# 1. Build the Wine overlay in fresh build/wine-tuned directories.
./scripts/build-wine-tuned.sh all

# 2. Build the native PSO module and package all runtime dependencies.
./scripts/package-wine-p3-runtime.sh build/wine-tuned/host "$GPTK_SOURCE" \
  build/wine-tuned/provenance.json build/wine-tuned/package

# 3. Build GUI Installer
./installer/build.sh
```

The installer build requires the new `build/wine-tuned/package/wine-11.17-zzz-dx12-gptk4b2-macos26.tar.xz` archive (or an explicit `RUNTIME_ARCHIVE_SOURCE`). It does not silently bundle an older installed runtime.

---

## 📄 License

- Wine source code is licensed under the **GNU Lesser General Public License (LGPL v2.1+)**.
- D3DMetal wrapper components and installer tools are licensed under the terms included in this repository.
