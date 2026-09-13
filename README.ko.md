# zzz-wine-d3dmetal-dx12

[English](README.md) | **한국어**

macOS(Apple Silicon) 환경의 **Yaagl ZZZ OS**에서 **젠레스 존 제로(Zenless Zone Zero, ZZZ)**를 **Direct3D 12 (GPTK 4.0b2)**로 가장 부드럽고 안정적으로 구동하기 위한 Wine 11.17 최적화 런타임 소스 및 간편 설치 프로그램입니다.

Yaagl 앱의 Wine 메뉴에 **`Wine 11.17 ZZZ DX12 (GPTK4.0b2)`**라는 이름으로 등록되어 원클릭으로 사용하실 수 있습니다.

---

## ⚡ 빠른 시작 (GUI 간편 설치)

일반 사용자분들은 별도의 복잡한 빌드 과정 없이, 포함된 **GUI 설치 프로그램**으로 1초 만에 Yaagl ZZZ OS에 적용할 수 있습니다.

### 방법 1: GUI 앱으로 설치
1. [Releases](https://github.com/dbc-hbin/zzz-wine-d3dmetal-dx12/releases)에서 `ZZZWineDX12Installer.zip`을 다운로드하고 압축을 풉니다.
2. **`ZZZ Wine DX12 Installer.app`**을 실행합니다.
3. Yaagl ZZZ OS 앱 및 데이터 경로가 자동으로 감지됩니다.
4. **`Install Wine 11.17 ZZZ DX12`** 버튼을 누르면 끝!
   - 런타임 패키지 무결성 검증 (SHA-256)
   - `resources.neu` 자동 백업 및 메뉴 등록 (`Wine 11.17 ZZZ DX12 (GPTK4.0b2)`)
   - Wine 런타임 파일 자동 압축 해제 및 활성화
5. Yaagl ZZZ OS를 열고 게임을 시작하시면 바로 적용됩니다.

### 방법 2: 터미널 CLI로 설치
```bash
./installer/zzz-wine-installer --cli
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

### 5. 마우스 커서 롤백 & RawInput 안정화 (`0004-macdrv-reset-rawinput-baseline.patch`)
- 게임 첫 실행 시 마우스 커서가 ZZZ 전용 인게임 커서로 바뀌지 않거나 화면 조작이 먹통이 되던 버그를 완벽히 해결했습니다.
- macdrv RawInput 로직을 안정된 베이스라인으로 롤백하여 마우스 포커스와 카메라 회전이 매끄럽게 동작합니다.

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
    ├── AsarPatcher.swift            # 순수 Swift 기반 resources.neu ASAR 패처
    ├── InstallerEngine.swift        # 자동 감지, 다운로드, 검증, 설치 엔진
    └── ContentView.swift            # SwiftUI 사용자 인터페이스
```

---

## 🛠️ 소스 코드 직접 빌드하기

### 요구 환경
- macOS Sonoma (14.0) 이상 (Apple Silicon M1/M2/M3/M4/M5)
- Xcode Command Line Tools (`xcode-select --install`)
- LLVM MinGW 크로스 컴파일러 (`/opt/llvm-mingw-...`)
- Bison, Pkg-config, GStreamer 의존성

### 빌드 명령어
```bash
# 1. 네이티브 PSO 캐시 dylib 컴파일
node scripts/build-d3dmetal-pso-cache.mjs build/native-pso-cache

# 2. Wine 11.17 소스 빌드 (x86_64 WoW64 + ARM64 wineserver)
./scripts/build-wine-tuned.sh all

# 3. GUI 설치 관리자 컴파일
./installer/build.sh
```

---

## 📄 라이선스 (License)

- Wine 소스 코드는 **GNU Lesser General Public License (LGPL v2.1+)**를 따릅니다.
- D3DMetal 관련 인터페이스 및 설치 프로그램 코드는 본 저장소의 라이선스를 따릅니다.
