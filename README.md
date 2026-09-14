# HSR Wine D3DMetal

Wine 11.17 source and installer for **Honkai: Star Rail** on Apple Silicon Macs through **Yaagl HSR OS**. This fork keeps the Wine base and its macOS cursor/input changes, while replacing the graphics layer with unmodified Apple GPTK 4.0 beta 2 D3DMetal and MetalIR files. The Yaagl display name is **`Wine 11.17 GPTK4.0b2`**; the internal runtime ID is `11.17-hsr-gptk4b2-stock`.

This HSR runtime uses the game's valid Direct3D 11 path. It does **not** add or force `-use-d3d12`, inject DXMT, apply the former FP64 MetalIR patch, or load the former native PSO bridge.

## Requirements

- Apple Silicon Mac
- macOS 26 or later
- Rosetta 2
- Yaagl HSR OS

## Install and restore

Download the [`v1.0.0` release](https://github.com/dbc-hbin/hsr-wine-d3dmetal/releases/tag/v1.0.0) [installer ZIP](https://github.com/dbc-hbin/hsr-wine-d3dmetal/releases/download/v1.0.0/HSRWineD3DMetalInstaller.zip), extract `HSRWineD3DMetalInstaller.zip`, quit Yaagl HSR OS, and open **HSR Wine D3DMetal Installer.app**. The app installs the bundled `wine-11.17-hsr-gptk4b2-stock.tar.xz`, registers **`Wine 11.17 GPTK4.0b2`**, and preserves the previous Yaagl resources and Wine selection for restoration. Use the installer's Restore action to return to that saved state.

The app is not notarized or Developer ID signed. macOS may block its first launch; after verifying the downloaded file, use Finder's **Open** context-menu action or Privacy & Security settings to allow it. Do not disable Gatekeeper globally.

Command-line installation and restoration use `installer/hsr-wine-installer` and target `/Applications/Yaagl HSR OS.app` plus `$HOME/Library/Application Support/Yaagl HSR OS`.

Repository: <https://github.com/dbc-hbin/hsr-wine-d3dmetal>

## Reproduce the runtime archive

Apple's binaries are inputs, not rebuilt or patched by this repository. Download `Game_Porting_Toolkit_4.0_beta_2.dmg` from Apple and provide a verified Wine 11.17 base tree/archive built from this source:

```sh
scripts/package-hsr-stock-runtime.sh \
  /path/to/wine-11.17-base-or-archive \
  /path/to/Game_Porting_Toolkit_4.0_beta_2.dmg
```

The default output is `build/hsr-runtime/wine-11.17-hsr-gptk4b2-stock.tar.xz` with a SHA-256 sidecar. The packager mounts the official evaluation image read-only, verifies its D3DMetal version, Apple signatures, and pinned stock hashes, overlays the complete redist, rejects modified D3DMetal/MetalIR bytes, writes a runtime inventory, and preserves symlinks and permissions. A directly extracted `redist` directory may be supplied instead of the DMG.

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
