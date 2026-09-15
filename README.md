# HSR Wine D3DMetal

Wine 11.17 source and installer for **Honkai: Star Rail** on Apple Silicon Macs through **Yaagl HSR OS**. This fork keeps the Wine base and its macOS cursor/input changes, while replacing the graphics layer with unmodified Apple GPTK 4.0 beta 2 D3DMetal and MetalIR files. The Yaagl display name is **`Wine 11.17 GPTK4.0b2`**; the internal runtime ID is `11.17-hsr-gptk4b2-stock`.

This HSR runtime uses the game's valid Direct3D 11 path. It does **not** add or force `-use-d3d12`, inject DXMT, apply the former FP64 MetalIR patch, or load the former native PSO bridge.

## Requirements

- Apple Silicon Mac
- macOS 26.4 or later based on packaged metadata: the new Wine/core binaries are audited for a macOS 26.0 deployment target, while a stock Apple library has an observed 26.4 minimum. Actual installer startup and D3D device operation have only been exercised on macOS 27, so macOS 26.x runtime compatibility is not yet empirically confirmed.
- Rosetta 2
- Yaagl HSR OS

## Install, restore, and uninstall

Do not use the v1.0.0 installer: its Wine core was accidentally built for macOS 27. Download the reviewed v1.0.1 release from [Releases](https://github.com/dbc-hbin/hsr-wine-d3dmetal/releases/tag/v1.0.1) or use the direct [HSRWineD3DMetalInstaller.zip](https://github.com/dbc-hbin/hsr-wine-d3dmetal/releases/download/v1.0.1/HSRWineD3DMetalInstaller.zip) link. It installs `wine-11.17-hsr-gptk4b2-stock.tar.xz`, registers **`Wine 11.17 GPTK4.0b2`**, and preserves the previous Yaagl resources and Wine selection. **Restore Backup** returns to that saved snapshot. **Uninstall Wine** is a separate, confirmed action: it removes only this installer's identifiable managed runtime, menu registration, and exact cached archive. It preserves the game, prefix, login, registry, and unrelated runtimes/cache entries; when safe, it restores the previous Wine and saved selection. If another runtime is currently selected, uninstall preserves that selection and reports the retained backup.

The app is not notarized or Developer ID signed. macOS may block its first launch; after verifying the downloaded file, use Finder's **Open** context-menu action or Privacy & Security settings to allow it. Do not disable Gatekeeper globally.

Command-line installation, restoration, and uninstall use `installer/hsr-wine-installer` and target `/Applications/Yaagl HSR OS.app` plus `$HOME/Library/Application Support/Yaagl HSR OS`. Destructive removal is never implicit: use `--uninstall` explicitly, and do not combine it with `--install` or `--restore`. The GUI and CLI refuse to proceed while Yaagl/Wine is running.

```sh
installer/hsr-wine-installer --install
installer/hsr-wine-installer --restore
installer/hsr-wine-installer --uninstall
```

Repository: <https://github.com/dbc-hbin/hsr-wine-d3dmetal>

## Reproduce the runtime archive

Apple's binaries are inputs, not rebuilt or patched by this repository. Download `Game_Porting_Toolkit_4.0_beta_2.dmg` from Apple and provide a verified Wine 11.17 base tree/archive built from this source:

```sh
scripts/package-hsr-stock-runtime.sh \
  /path/to/wine-11.17-base-or-archive \
  /path/to/Game_Porting_Toolkit_4.0_beta_2.dmg
```

The default output is `build/hsr-runtime/wine-11.17-hsr-gptk4b2-stock.tar.xz` with a SHA-256 sidecar. Before creating output, the packager rejects any Wine/core Mach-O payload requiring more than macOS 26.0. Stock Apple files remain byte-identical; their recorded deployment metadata is reported separately, including the observed macOS 26.4 minimum on `libdxccontainer.dylib`, and does not weaken the Wine/core check. The packager mounts the official evaluation image read-only, verifies its D3DMetal version, Apple signatures, and pinned stock hashes, overlays the complete redist, rejects modified D3DMetal/MetalIR bytes, writes a runtime inventory, and preserves symlinks and permissions. A directly extracted `redist` directory may be supplied instead of the DMG.

Apple's GPTK license permits distribution only for non-commercial purposes under its terms. The Apple software may run only on supported Apple-branded hardware, and it may not be rented, leased, lent, hosted, sold, modified, or used to create derivative works. The packaged framework retains Apple's license and notices; review the complete license in the official image before distribution.

## Build and verify

Build the supported Wine base (including this fork's cursor/input changes), package it with the user-provided GPTK image, then build the installer and ZIP:

```sh
scripts/build-wine-tuned.sh all
scripts/package-hsr-stock-runtime.sh build/wine-tuned/host /path/to/Game_Porting_Toolkit_4.0_beta_2.dmg
installer/build.sh
ditto -c -k --sequesterRsrc --keepParent "installer/HSR Wine D3DMetal Installer.app" HSRWineD3DMetalInstaller.zip
```

The base build requires the dependency trees and toolchains checked by `scripts/build-wine-tuned.sh preflight`. Verify the HSR resource transformation and isolated installer lifecycle without touching a live game or prefix:

```sh
node scripts/test-hsr-launch-regression.mjs
python3 scripts/test-resource-lifecycle.py
```

## Input-method caveat

The user observed intermittent text-input/IME trouble in the HSR login view; later retries allowed login, but the cause was not reproduced or fixed. This project makes no general HSR IME compatibility claim.

## License

Wine source is licensed under the GNU Lesser General Public License; see `COPYING.LIB`. Apple GPTK components remain subject to Apple's license.
