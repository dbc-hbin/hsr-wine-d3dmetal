# HSR Wine D3DMetal

Wine 11.17 source and the v1.0.2 installer for **Honkai: Star Rail** on Apple Silicon Macs through **Yaagl HSR OS**. The actual graphics profile is `zzz-cache-no-fp64`: GPTK 4.0b2 D3DMetal receives the stage-lock, pipeline/function/stage in-memory caches, and NGX/MetalFX exposure hooks (activated by `YAAGL_METALFX_EXPOSURE_SCALE_FIX=1`), while the official MetalIR converter remains byte-identical and receives no FP64 patch. Disk cache warmup only advises existing cache files; it creates no persistent cache store.

The public Yaagl display name stays **`Wine 11.17 GPTK4.0b2`**. The deployed runtime ID `11.17-hsr-gptk4b2-stock` and archive filename `wine-11.17-hsr-gptk4b2-stock.tar.xz` are immutable compatibility identifiers; the legacy `stock` word no longer describes the graphics profile. HSR keeps its supported Direct3D 11 route (`d3d11,dxgi=b`) and never adds or forces `-use-d3d12`.

## Requirements

- Apple Silicon Mac
- macOS 26.4 or later based on packaged metadata: the new Wine/core binaries are audited for a macOS 26.0 deployment target, while a stock Apple library has an observed 26.4 minimum. Actual installer startup and D3D device operation have only been exercised on macOS 27, so macOS 26.x runtime compatibility is not yet empirically confirmed.
- Rosetta 2
- Yaagl HSR OS

## Install, restore, and uninstall

Do not use the v1.0.0 installer: its Wine core was accidentally built for macOS 27. Download the reviewed v1.0.2 release from [Releases](https://github.com/dbc-hbin/hsr-wine-d3dmetal/releases/tag/v1.0.2) or use the direct [HSRWineD3DMetalInstaller.zip](https://github.com/dbc-hbin/hsr-wine-d3dmetal/releases/download/v1.0.2/HSRWineD3DMetalInstaller.zip) link. It installs `wine-11.17-hsr-gptk4b2-stock.tar.xz`, registers **`Wine 11.17 GPTK4.0b2`**, and preserves the previous Yaagl resources and Wine selection. **Restore Backup** returns to that saved snapshot. **Uninstall Wine** is a separate, confirmed action: it removes only this installer's identifiable managed runtime, menu registration, and exact cached archive. It preserves the game, prefix, login, registry, and unrelated runtimes/cache entries; when safe, it restores the previous Wine and saved selection. If another runtime is currently selected, uninstall preserves that selection and reports the retained backup.

The app is not notarized or Developer ID signed. macOS may block its first launch; after verifying the downloaded file, use Finder's **Open** context-menu action or Privacy & Security settings to allow it. Do not disable Gatekeeper globally.

Command-line installation, restoration, and uninstall use `installer/hsr-wine-installer` and target `/Applications/Yaagl HSR OS.app` plus `$HOME/Library/Application Support/Yaagl HSR OS`. Destructive removal is never implicit: use `--uninstall` explicitly, and do not combine it with `--install` or `--restore`. The GUI and CLI refuse to proceed while Yaagl/Wine is running.

```sh
installer/hsr-wine-installer --install
installer/hsr-wine-installer --restore
installer/hsr-wine-installer --uninstall
```

Repository: <https://github.com/dbc-hbin/hsr-wine-d3dmetal>

## Reproduce the runtime archive

Apple's official redist is the trusted input; only D3DMetal is patched and re-signed, while MetalIR remains unmodified. Download `Game_Porting_Toolkit_4.0_beta_2.dmg` from Apple and provide a verified Wine 11.17 base tree/archive built from this source:

```sh
scripts/package-hsr-runtime.sh \
  /path/to/wine-11.17-base-or-archive \
  /path/to/Game_Porting_Toolkit_4.0_beta_2.dmg
```

The default output keeps the compatibility filename `build/hsr-runtime/wine-11.17-hsr-gptk4b2-stock.tar.xz` and adds a SHA-256 sidecar. The packager rejects Wine/core Mach-O payloads above the macOS 26.0 target, verifies the official redist, copies exactly six PE graphics modules and six Unix bridge symlinks, builds the production native cache module, patches and re-signs D3DMetal, and emits profile provenance plus a complete runtime inventory. It never invokes the FP64 patcher and requires the final MetalIR SHA-256 to remain `75974d49ad4dd1bdf17ab3cd666ae7cac43e7f7a5760237699ab33ecd3d31daf`. A directly extracted official `redist` directory may be supplied instead of the DMG.

Apple's GPTK license permits distribution only for non-commercial purposes under its terms. The Apple software may run only on supported Apple-branded hardware, and it may not be rented, leased, lent, hosted, sold, modified, or used to create derivative works. The packaged framework retains Apple's license and notices; review the complete license in the official image before distribution.

## Build and verify

Build the supported Wine base (including this fork's cursor/input changes), package it with the user-provided GPTK image, then build the installer and ZIP:

```sh
scripts/build-wine-tuned.sh all
scripts/package-hsr-runtime.sh build/wine-tuned/host /path/to/Game_Porting_Toolkit_4.0_beta_2.dmg
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
