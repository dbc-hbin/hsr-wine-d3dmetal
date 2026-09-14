# HSR Wine D3DMetal

Apple Silicon Mac의 **Yaagl HSR OS**에서 **붕괴: 스타레일**을 실행하기 위한 Wine 11.17 소스와 설치 프로그램입니다. 이 포크는 Wine 기반과 macOS 커서·입력 수정을 유지하고, 그래픽 계층은 수정하지 않은 Apple GPTK 4.0 beta 2 D3DMetal·MetalIR 파일로 교체합니다. Yaagl 표시 이름은 정확히 **`Wine 11.17 GPTK4.0b2`**, 내부 런타임 ID는 `11.17-hsr-gptk4b2-stock`입니다.

HSR에서 유효한 Direct3D 11 경로를 사용합니다. `-use-d3d12`를 추가하거나 강제하지 않으며, DXMT 주입, 기존 FP64 MetalIR 패치, 기존 네이티브 PSO 브리지를 사용하지 않습니다.

## 요구 사항

- Apple Silicon Mac
- macOS 26 이상
- Rosetta 2
- Yaagl HSR OS

## 설치와 복원

[`v1.0.0` 릴리스](https://github.com/dbc-hbin/hsr-wine-d3dmetal/releases/tag/v1.0.0)의 [설치 프로그램 ZIP](https://github.com/dbc-hbin/hsr-wine-d3dmetal/releases/download/v1.0.0/HSRWineD3DMetalInstaller.zip)을 다운로드하고 `HSRWineD3DMetalInstaller.zip`을 푼 뒤, Yaagl HSR OS를 종료하고 **HSR Wine D3DMetal Installer.app**을 실행합니다. 앱은 포함된 `wine-11.17-hsr-gptk4b2-stock.tar.xz`를 설치하고 **`Wine 11.17 GPTK4.0b2`**를 등록하며, 복원을 위해 이전 Yaagl 리소스와 Wine 선택을 보존합니다. 설치 프로그램의 Restore 기능으로 저장된 상태를 복구할 수 있습니다.

앱은 공증되거나 Developer ID로 서명되지 않았으므로 macOS가 최초 실행을 차단할 수 있습니다. 다운로드 파일을 확인한 뒤 Finder에서 우클릭하여 **열기**를 선택하거나 개인정보 보호 및 보안 설정에서 허용하십시오. Gatekeeper를 전역으로 끄지 마십시오.

명령줄 설치·복원은 `installer/hsr-wine-installer`를 사용하며 `/Applications/Yaagl HSR OS.app`과 `$HOME/Library/Application Support/Yaagl HSR OS`를 대상으로 합니다.

저장소: <https://github.com/dbc-hbin/hsr-wine-d3dmetal>

## 런타임 아카이브 재현

Apple 바이너리는 이 저장소에서 빌드하거나 패치하지 않는 입력입니다. Apple에서 `Game_Porting_Toolkit_4.0_beta_2.dmg`를 받고, 이 소스에서 빌드한 검증된 Wine 11.17 기반 트리 또는 아카이브를 지정합니다.

```sh
scripts/package-hsr-stock-runtime.sh \
  /path/to/wine-11.17-base-or-archive \
  /path/to/Game_Porting_Toolkit_4.0_beta_2.dmg
```

기본 출력은 `build/hsr-runtime/wine-11.17-hsr-gptk4b2-stock.tar.xz`와 SHA-256 사이드카입니다. 패키저는 공식 평가 이미지를 읽기 전용으로 마운트하고 D3DMetal 버전, Apple 서명, 고정된 순정 해시를 확인합니다. 전체 redist를 덮어씌워 수정된 D3DMetal·MetalIR 바이트를 배제하고, 런타임 인벤토리를 작성하며 심볼릭 링크와 권한을 보존합니다. DMG 대신 직접 추출한 `redist` 디렉터리도 사용할 수 있습니다.

Apple GPTK 라이선스는 해당 조건에 따른 비상업적 배포만 허용합니다. Apple 소프트웨어는 지원되는 Apple 브랜드 하드웨어에서만 실행할 수 있고 임대, 대여, 호스팅, 판매, 수정 또는 파생 저작물 제작을 할 수 없습니다. 패키징된 프레임워크는 Apple 라이선스와 고지를 보존합니다. 배포 전에 공식 이미지의 전체 라이선스를 검토해야 합니다.

## 빌드와 검증

이 포크의 커서·입력 수정을 포함한 지원 Wine 기반을 빌드하고, 사용자가 제공한 GPTK 이미지로 런타임과 설치 프로그램 ZIP을 만듭니다.

```sh
scripts/build-wine-tuned.sh all
scripts/package-hsr-stock-runtime.sh build/wine-tuned/host /path/to/Game_Porting_Toolkit_4.0_beta_2.dmg
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
