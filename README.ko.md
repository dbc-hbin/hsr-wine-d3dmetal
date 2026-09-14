# zzz-wine-d3dmetal-dx12

[English](README.md) | **한국어**

macOS(Apple Silicon) 환경의 **Yaagl ZZZ OS**에서 **젠레스 존 제로(Zenless Zone Zero, ZZZ)**를 **Direct3D 12 (GPTK 4.0b2)**로 가장 부드럽고 안정적으로 구동하기 위한 Wine 11.17 최적화 런타임 소스 및 간편 설치 프로그램입니다.

설치 프로그램은 포함된 사전 빌드 Wine 패키지를 설치하고 Yaagl Wine 메뉴에 **`Wine 11.17 ZZZ DX12 (GPTK4.0b2)`**를 등록합니다.

**배포 타깃은 Apple Silicon의 macOS 26.0 이상이며 Rosetta 2가 필요합니다.** v1.0.2는 새 빌드 디렉터리에서 Wine 산출물 45개를 재빌드했습니다. 그중 네이티브 모듈 7개는 SDK 26.5로 macOS 26.0을 타깃으로 빌드했으며, 나머지 Wine 파일은 고정된 P3 패키지를 계승합니다. Tuned 패치, 네이티브 PSO 캐시, `D3DM_MTL4=1`은 유지됩니다.

`libdxccontainer.dylib`는 D3DMetal의 DXIL 컨테이너 분석과 DXBC/HLSL 변환에 필요합니다. 기록된 최소 버전 26.4를 포함해 Apple 원본 바이너리를 그대로 유지했으며, 조사한 import에서 26.4 전용 API는 발견되지 않았습니다. Wine 설정 배치와 DX12 그래픽·컴퓨트·레이 트레이싱 GPU 읽기 검증은 macOS 27에서 통과했습니다. **macOS 26 실기기 실행은 아직 검증하지 않았습니다.**

---

## ⚡ 빠른 시작 (GUI 간편 설치)

일반 사용자분들은 별도의 복잡한 빌드 과정 없이, 포함된 **GUI 설치 프로그램**으로 Yaagl ZZZ OS에 적용할 수 있습니다.

### 방법 1: GUI 앱으로 설치
1. [ZZZWineDX12Installer.zip](https://github.com/dbc-hbin/zzz-wine-d3dmetal-dx12/releases/latest/download/ZZZWineDX12Installer.zip)을 다운로드하고 압축을 풉니다.
2. **`ZZZ Wine DX12 Installer.app`**을 실행합니다.
3. Yaagl ZZZ OS 앱 및 데이터 경로가 자동으로 감지됩니다.
4. Yaagl ZZZ OS를 종료한 후 **`Install Wine 11.17 ZZZ DX12`** 버튼을 누릅니다.
   - 포함된 사전 빌드 Wine 런타임 아카이브를 Yaagl에 설치합니다.
   - Yaagl Wine 메뉴에 **`Wine 11.17 ZZZ DX12 (GPTK4.0b2)`**를 등록합니다.
   - Yaagl의 리소스, Wine 선택 및 Wine 디렉터리를 백업하여 기존 구성을 복원할 수 있습니다.
5. Yaagl ZZZ OS를 열고 Wine 메뉴에서 설치된 Wine 런타임을 선택해 게임을 시작합니다.

포함된 아카이브는 Yaagl의 로컬 런타임 저장소에 유지되므로, 오프라인에서도 Yaagl Wine 메뉴에서 이 Wine 런타임을 선택하거나 다른 Wine 런타임으로 전환할 수 있습니다. 설치 프로그램은 Node.js를 필요로 하지 않습니다.

### v1.0.3: 런처 업데이트와 복원

v1.0.3은 설치 프로그램만 수정합니다. 동봉된 macOS 26 Wine 아카이브와 튜닝은 v1.0.2와 동일합니다.

- 앱 번들이 아니라 Yaagl 데이터 폴더의 실행용 `resources.neu`만 등록합니다. 앱 리소스와 기존 앱 백업은 건드리지 않으며, 시작 동기화가 구버전 앱 리소스로 실행용 리소스를 덮어쓰지 않도록 합니다.
- `.zzz-wine-registration`의 네이티브 helper가 앱 내부 업데이트의 다운로드 파일을 교체하기 전에 Wine을 등록합니다. 설치·업데이트 때만 실행되며 백그라운드 서비스나 Node.js는 필요하지 않습니다. 지원하지 않는 프런트엔드 구조나 helper 오류는 기존 리소스 교체 전에 업데이트를 중단합니다.
- 복원은 현재 등록된 리소스와 짝이 맞는 원본을 사용하며, 오래된 전체 리소스 백업으로 되돌리지 않습니다. 다음 업데이트를 준비해도 현재 리소스의 복원 지점은 유지됩니다.

이전 설치기로 Yaagl이 이미 다운그레이드됐다면 먼저 Yaagl을 원하는 버전으로 업데이트하고 종료한 뒤 v1.0.3으로 설치하세요. 앱 전체 교체나 외부에서의 리소스 교체는 앱 내부 업데이트 hook을 우회할 수 있으므로, 그런 변경 후에는 설치기를 다시 실행하세요.

### 방법 2: 터미널 CLI로 설치
```bash
./installer/zzz-wine-installer --install \
  --app-path "/Applications/Yaagl ZZZ OS.app" \
  --support-path "$HOME/Library/Application Support/Yaagl ZZZ OS"

# 이전 Wine 디렉터리 복원
./installer/zzz-wine-installer --restore \
  --app-path "/Applications/Yaagl ZZZ OS.app" \
  --support-path "$HOME/Library/Application Support/Yaagl ZZZ OS"
```

---

## 🚀 적용된 최적화 및 패치 안내

이 빌드는 순정 Wine 11.17에 ZZZ 및 macOS 환경에 특화된 여러 최적화 패치를 통합한 버전입니다.

### 1. Direct3D 12 & Apple GPTK 4.0b2 완벽 대응
- Apple Game Porting Toolkit 4.0b2의 최신 D3DMetal 및 Metal IR 변환 계층을 통합했습니다.
- ZZZ의 고품질 DirectX 12 렌더링 호출을 Apple Silicon의 Metal API로 빠르고 정확하게 변환합니다.

### 2. Apple Silicon 네이티브 ARM64 Wineserver (`0002-native-x86-server.patch`)
- 기존 x86_64 Wine은 프로세스를 총괄하는 `wineserver`까지 Rosetta 2 에뮬레이션으로 동작하여 불필요한 지연이 발생했습니다.
- 이 빌드는 `wineserver`를 Apple Silicon(ARM64) 네이티브로 빌드하여 실행하므로, 윈도우 스레드 관리와 IPC 시스템 호출 오버헤드가 크게 단축됩니다.

### 3. 고성능 MSync 동기화 패치 (`0001`, `0003`, `0007`, `0012`)
- Windows의 동기화 객체(뮤텍스, 이벤트, 세마포어)를 macOS 커널의 빠른 Mach 세마포어와 공유 메모리에 직결했습니다.
- 멀티스레드 렌더링 환경에서 스레드가 대기할 때 커널 전환 비용을 최소화하여 프레임 드랍과 끊김 현상을 방지합니다.

### 4. 네이티브 Metal PSO 캐시 및 캐시 웜업 (`libYaaglNativePsoCache`)
- 게임 플레이 중 새로운 셰이더를 처음 만날 때 발생하는 **미세 끊김(Micro-stuttering)**을 잡기 위한 전용 네이티브 캐시 계층입니다.
- 중복 셰이더 생성을 막고 디바이스 수명 동안 Metal 파이프라인 상태 객체(PSO)를 재사용합니다.
- 사전 캐시 웜업(Warmup) 구조로 쾌적한 전투 환경을 제공합니다.

### 5. 커서 소유권과 RawInput 분리 (`0004-macdrv-reset-rawinput-baseline.patch`)
- 네이티브 커서 표시와 창 판정은 유지하고, 커서 소유권 동기화가 포인터 좌표를 변경하지 않도록 분리했습니다.
- warp 변위를 보정한 마우스 이동량을 포인터 좌표와 별도로 전달합니다. 첫 실제 이동을 버리지 않고 소수 이동량과 이벤트 병합을 보존합니다.
- 수정 소스의 서버 프로토콜은 **966**입니다. Wine 클라이언트·서버 모듈을 함께 재빌드해야 합니다. 동봉 설치기·런타임에는 아직 이 변경을 빌드해 넣지 않았습니다.
- `node scripts/wine-mac-cursor-input-regression.mjs`로 실제 소스에서 추출한 입력 로직을 검사합니다. 네이티브 커서 픽셀과 게임 카메라의 실제 동작 검증을 대신하지는 않습니다.

### 6. 영상/오디오 및 시스템 자원 최적화 (`0005`, `0006`, `0008` ~ `0014`)
- **미디어 재생 개선**: GStreamer 및 Media Foundation 최적화로 인게임 컷씬 및 비디오 재생이 끊기지 않습니다.
- **오디오 레이턴시 감소**: CoreAudio 버퍼링을 개선하여 소리 밀림 현상을 줄였습니다.
- **창 메시지 및 네트워크**: 윈도우 이벤트 큐와 소켓 통신을 다듬어 입력 반응 속도를 높였습니다.

---

## 📂 저장소 구조

```
zzz-wine-d3dmetal-dx12/
├── external/               # Apple GPTK 4.0b2 순정 D3DMetal.framework 원본
│   └── D3DMetal.framework  # D3DMetal 바이너리 및 libmetalirconverter.dylib
├── dlls/                   # Wine 11.17 수정/패치된 DLL 소스 코드
├── server/                 # ARM64 네이티브 지원 및 msync가 적용된 wineserver 소스
├── include/                # msync.h 등 추가/수정된 헤더 파일
├── d3dmetal-pso-cache/     # libYaaglNativePsoCache 네이티브 캐시 소스 (Objective-C++)
├── patches/                # 적용된 개별 패치 파일 모음 (0001 ~ 0014)
│   ├── wine-tuned/         # 성능 최적화 및 버그 수정 패치 14종
│   └── wine-p3/            # 베이스라인 호스트 msync 및 D3DMetal 브릿지 패치
├── scripts/                # Wine 빌드 및 패키징 스크립트
└── installer/              # SwiftUI 기반 간편 GUI 설치 프로그램 소스 및 빌드 산출물
    ├── ZZZ Wine DX12 Installer.app  # 컴파일된 실행형 macOS 앱 번들
    ├── zzz-wine-installer           # CLI 실행 바이너리
    ├── RuntimePackage.swift         # 사전 빌드 Wine 패키지 메타데이터
    ├── AsarPatcher.swift            # Yaagl Wine 메뉴 등록 패처
    ├── InstallerEngine.swift        # 자동 감지, 설치, 등록 및 복원 엔진
    ├── ContentView.swift            # SwiftUI 사용자 인터페이스
    └── resources/typescript.js      # 메뉴 패칭용 내장 JavaScript 컴파일러
```

---

## 🛠️ 소스 코드 직접 빌드하기

### 요구 환경
- macOS 26.0 이상 (Apple Silicon M1/M2/M3/M4/M5), Rosetta 2, macOS 26 SDK
- Xcode Command Line Tools (`xcode-select --install`)
- LLVM MinGW 크로스 컴파일러 (`/opt/llvm-mingw-...`)
- Bison, Pkg-config, GStreamer 의존성
- 준비된 P3 소스·호스트·의존성 트리·provenance, 로컬 GPTK 오버레이 및 Steam helper 파일. 이 저장소는 외부 빌드 입력을 다운로드하지 않습니다.

### 빌드 명령어
```bash
# 검증된 로컬 입력 디렉터리와 설치된 SDK 경로를 지정합니다.
export WINE_P3_ROOT="/absolute/path/to/prepared/wine-p3"
export YAAGL_STEAM_HELPER_DIR="/absolute/path/to/protonextras"
export GPTK_SOURCE="/absolute/path/to/gptk-overlay/wine"
export MACOSX_DEPLOYMENT_TARGET=26.0
export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
export WINE_PACKAGE_NAME=wine-11.17-zzz-dx12-gptk4b2-macos26
export WINE_RUNTIME_ID=11.17-zzz-dx12-tuned-stage-parallel-cache-warmup-cursor-rollback-gptk4b2-arm64server

# 1. 새 build/wine-tuned 디렉터리에서 Wine 오버레이를 빌드합니다.
./scripts/build-wine-tuned.sh all

# 2. 네이티브 PSO 모듈을 빌드하고 런타임 의존성을 패키징합니다.
./scripts/package-wine-p3-runtime.sh build/wine-tuned/host "$GPTK_SOURCE" \
  build/wine-tuned/provenance.json build/wine-tuned/package

# 3. GUI 설치 관리자 컴파일
./installer/build.sh
```

설치 앱 빌드에는 새 `build/wine-tuned/package/wine-11.17-zzz-dx12-gptk4b2-macos26.tar.xz` 아카이브 또는 명시적인 `RUNTIME_ARCHIVE_SOURCE`가 필요합니다. 기존에 설치된 오래된 런타임을 대신 포함하지 않습니다.

---

## 📄 라이선스 (License)

- Wine 소스 코드는 **GNU Lesser General Public License (LGPL v2.1+)**를 따릅니다.
- D3DMetal 관련 인터페이스 및 설치 프로그램 코드는 본 저장소의 라이선스를 따릅니다.
