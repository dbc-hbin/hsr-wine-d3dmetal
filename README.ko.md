# HSR Wine D3DMetal

Apple Silicon Mac의 **Yaagl HSR OS**에서 **붕괴: 스타레일**을 실행하기 위한 Wine 11.17 소스와 v1.0.2 설치 프로그램입니다. 실제 그래픽 프로필은 `zzz-cache-no-fp64`입니다. GPTK 4.0b2 D3DMetal에는 stage-lock, 파이프라인·함수·스테이지 인메모리 캐시 및 `YAAGL_METALFX_EXPOSURE_SCALE_FIX=1`로 활성화하는 NGX/MetalFX 노출 훅을 적용하지만 Apple 순정 MetalIR 변환기는 바이트 단위로 그대로 유지하고 FP64 패치를 적용하지 않습니다. 디스크 캐시 워밍업은 기존 캐시 파일에 advisory만 수행하며 새 영구 캐시 저장소를 만들지 않습니다.

Yaagl 표시 이름은 **`Wine 11.17 GPTK4.0b2`**로 유지합니다. 배포된 런타임 ID `11.17-hsr-gptk4b2-stock`과 아카이브 이름 `wine-11.17-hsr-gptk4b2-stock.tar.xz`는 변경할 수 없는 호환성 식별자이며, 레거시 이름의 `stock`은 더 이상 실제 그래픽 프로필을 설명하지 않습니다. HSR은 지원되는 Direct3D 11 경로(`d3d11,dxgi=b`)를 유지하며 `-use-d3d12`를 추가하거나 강제하지 않습니다.

## 요구 사항

- Apple Silicon Mac
- 패키지 메타데이터 기준 macOS 26.4 이상: 새 Wine·핵심 바이너리의 배포 대상은 macOS 26.0으로 감사되었지만 Apple 순정 라이브러리 하나에서 26.4 최소 버전이 관찰되었습니다. 실제 설치 프로그램 시작과 D3D 장치 동작은 macOS 27에서만 확인했으므로 macOS 26.x 런타임 호환성은 아직 실증되지 않았습니다.
- Rosetta 2
- Yaagl HSR OS

## 설치, 복원, 제거

v1.0.0 설치 프로그램은 사용하지 마십시오. Wine 핵심 파일이 실수로 macOS 27 대상으로 빌드되었습니다. 검토된 v1.0.2는 [Releases](https://github.com/dbc-hbin/hsr-wine-d3dmetal/releases/tag/v1.0.2) 또는 [HSRWineD3DMetalInstaller.zip 직접 링크](https://github.com/dbc-hbin/hsr-wine-d3dmetal/releases/download/v1.0.2/HSRWineD3DMetalInstaller.zip)에서 받으십시오. 이 앱은 `wine-11.17-hsr-gptk4b2-stock.tar.xz`를 설치하고 **`Wine 11.17 GPTK4.0b2`**를 등록하며 이전 Yaagl 리소스와 Wine 선택을 보존합니다. **Restore Backup**은 저장된 스냅샷으로 되돌립니다. 별도의 **Uninstall Wine**은 확인 후 이 설치 프로그램 소유로 식별된 런타임, Wine 메뉴 등록, 정확한 캐시 아카이브만 제거합니다. 게임, prefix, 로그인, 레지스트리, 다른 런타임·캐시는 보존하며, 안전할 때 이전 Wine과 저장된 선택을 복원합니다. 다른 런타임을 현재 선택했다면 해당 선택을 유지하고 남겨 둔 백업을 보고합니다.

앱은 공증되거나 Developer ID로 서명되지 않았으므로 macOS가 최초 실행을 차단할 수 있습니다. 다운로드 파일을 확인한 뒤 Finder에서 우클릭하여 **열기**를 선택하거나 개인정보 보호 및 보안 설정에서 허용하십시오. Gatekeeper를 전역으로 끄지 마십시오.

명령줄 설치·복원·제거는 `installer/hsr-wine-installer`를 사용하며 `/Applications/Yaagl HSR OS.app`과 `$HOME/Library/Application Support/Yaagl HSR OS`를 대상으로 합니다. 제거는 절대 암묵적으로 실행되지 않습니다. 반드시 `--uninstall`을 명시하며 `--install` 또는 `--restore`와 함께 사용할 수 없습니다. GUI와 CLI는 Yaagl/Wine 실행 중 작업을 거부합니다.

```sh
installer/hsr-wine-installer --install
installer/hsr-wine-installer --restore
installer/hsr-wine-installer --uninstall
```

저장소: <https://github.com/dbc-hbin/hsr-wine-d3dmetal>

## 런타임 아카이브 재현

Apple 공식 redist가 신뢰 입력이며 D3DMetal만 패치·재서명하고 MetalIR은 수정하지 않습니다. Apple에서 `Game_Porting_Toolkit_4.0_beta_2.dmg`를 받고, 이 소스에서 빌드한 검증된 Wine 11.17 기반 트리 또는 아카이브를 지정합니다.

```sh
scripts/package-hsr-runtime.sh \
  /path/to/wine-11.17-base-or-archive \
  /path/to/Game_Porting_Toolkit_4.0_beta_2.dmg
```

기본 출력은 호환성 파일명 `build/hsr-runtime/wine-11.17-hsr-gptk4b2-stock.tar.xz`와 SHA-256 사이드카입니다. 패키저는 macOS 26.0을 넘는 Wine·핵심 Mach-O를 거부하고, 공식 redist를 검증한 뒤 정확히 6개 PE 그래픽 모듈과 6개 Unix 브리지 심볼릭 링크만 복사합니다. 이어 프로덕션 네이티브 캐시 모듈을 빌드하고 D3DMetal을 패치·재서명한 뒤 프로필 출처와 전체 런타임 인벤토리를 기록합니다. FP64 패처는 절대 호출하지 않으며 최종 MetalIR SHA-256이 `75974d49ad4dd1bdf17ab3cd666ae7cac43e7f7a5760237699ab33ecd3d31daf` 그대로인지 검사합니다. DMG 대신 직접 추출한 공식 `redist` 디렉터리를 지정할 수도 있습니다.

Apple GPTK 라이선스는 해당 조건에 따른 비상업적 배포만 허용합니다. Apple 소프트웨어는 지원되는 Apple 브랜드 하드웨어에서만 실행할 수 있고 임대, 대여, 호스팅, 판매, 수정 또는 파생 저작물 제작을 할 수 없습니다. 패키징된 프레임워크는 Apple 라이선스와 고지를 보존합니다. 배포 전에 공식 이미지의 전체 라이선스를 검토해야 합니다.

## 빌드와 검증

이 포크의 커서·입력 수정을 포함한 지원 Wine 기반을 빌드하고, 사용자가 제공한 GPTK 이미지로 런타임과 설치 프로그램 ZIP을 만듭니다.

```sh
scripts/build-wine-tuned.sh all
scripts/package-hsr-runtime.sh build/wine-tuned/host /path/to/Game_Porting_Toolkit_4.0_beta_2.dmg
installer/build.sh
ditto -c -k --sequesterRsrc --keepParent "installer/HSR Wine D3DMetal Installer.app" HSRWineD3DMetalInstaller.zip
```

Wine 기반 빌드에는 `scripts/build-wine-tuned.sh preflight`가 검사하는 의존성 트리와 툴체인이 필요합니다. 실제 게임이나 prefix를 건드리지 않고 HSR 리소스 변환과 격리된 설치 수명주기를 검증합니다.

```sh
node scripts/test-hsr-launch-regression.mjs
python3 scripts/test-resource-lifecycle.py
```

## 입력기 주의 사항

사용자가 HSR 로그인 화면에서 간헐적인 문자 입력·IME 문제를 관찰했으며 이후 재시도에서는 로그인에 성공했지만, 원인은 재현하거나 수정하지 못했습니다. HSR IME 전반의 호환성을 보장하지 않습니다.

## 라이선스

Wine 소스는 GNU LGPL로 배포됩니다(`COPYING.LIB`). Apple GPTK 구성 요소에는 Apple 라이선스가 적용됩니다.
