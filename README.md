# zzz-wine-d3dmetal-dx12

**English** | [한국어 (Korean)](README.ko.md)

Optimized Wine 11.17 runtime source code and easy 1-click GUI installer for playing **Zenless Zone Zero (ZZZ)** with **Direct3D 12 (Apple GPTK 4.0b2)** on macOS (Apple Silicon) via **Yaagl ZZZ OS**.

Registered in the Yaagl Wine dropdown menu as:
**`Wine 11.17 ZZZ DX12 (GPTK4.0b2)`**

---

## ⚡ Quick Start (Easy 1-Click GUI Installer)

You do not need to build from source. An easy native macOS GUI installer is included to set up everything automatically in seconds.

### Option 1: Native GUI Installer (Recommended)
1. Go to [Releases](https://github.com/dbc-hbin/zzz-wine-d3dmetal-dx12/releases) and download `ZZZWineDX12Installer.zip`.
2. Extract the zip and open **`ZZZ Wine DX12 Installer.app`**.
3. The app automatically detects your Yaagl ZZZ OS app and data folders.
4. Click **`Install Wine 11.17 ZZZ DX12`**.
   - Verifies runtime package integrity (SHA-256).
   - Backs up `resources.neu` and registers `Wine 11.17 ZZZ DX12 (GPTK4.0b2)`.
   - Extracts and configures the optimized Wine runtime.
5. Launch Yaagl ZZZ OS and enjoy smooth DX12 gameplay!

### Option 2: Terminal CLI
```bash
./installer/zzz-wine-installer --cli
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

### 5. Cursor Rollback & RawInput Fix (`0004-macdrv-reset-rawinput-baseline.patch`)
- Fixes the bug where the mouse cursor fails to switch to the in-game cursor or mouse input freezes upon launching the game.
- Reverts macdrv rawinput regressions to a stable baseline for smooth camera rotation and window focus handling.

### 6. Media, Audio, Window & System Resource Tuning (`0005`, `0006`, `0008` ~ `0014`)
- **Media Playback**: GStreamer and Media Foundation optimizations prevent cutscene stutters.
- **Low-Latency Audio**: Refined CoreAudio buffering reduces audio delay.
- **Window & Network**: Tuned window message queue and socket handling for faster response.

---

## 📂 Repository Structure

```
zzz-wine-d3dmetal-dx12/
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
    ├── AsarPatcher.swift            # Pure Swift ASAR parser & patcher
    ├── InstallerEngine.swift        # Auto-detect, download, extract & setup engine
    └── ContentView.swift            # SwiftUI interface
```

---

## 🛠️ Building From Source

### Prerequisites
- macOS Sonoma (14.0) or later (Apple Silicon M-series)
- Xcode Command Line Tools (`xcode-select --install`)
- LLVM MinGW toolchain (`/opt/llvm-mingw-...`)
- Bison, Pkg-config, GStreamer dependencies

### Build Commands
```bash
# 1. Compile native PSO cache dylib
node scripts/build-d3dmetal-pso-cache.mjs build/native-pso-cache

# 2. Build Wine 11.17 (x86_64 WoW64 + ARM64 native wineserver)
./scripts/build-wine-tuned.sh all

# 3. Build GUI Installer
./installer/build.sh
```

---

## 📄 License

- Wine source code is licensed under the **GNU Lesser General Public License (LGPL v2.1+)**.
- D3DMetal wrapper components and installer tools are licensed under the terms included in this repository.
