# Neo65 CU Wired용 ZMK 포팅

Qwertykeys/NEO Studio **Neo65 CU 유선 PCB**의 STM32F072용 USB 전용 ZMK
보드 정의입니다. Tri-mode PCB, 기존 Neo65, Neo65 Core Plus, Neo65 Sonic HE+
등 다른 PCB에는 사용할 수 없습니다.

> [!WARNING]
> 현재 상태는 소스 및 빌드 검증 단계이며 실기기 검증 전입니다. DFU descriptor,
> 전체 main-flash readback, 물리 복구 경로를 먼저 확인하기 전에는 플래시하지
> 마십시오.

## 부트로더 보존 원칙

이 포트의 최우선 조건은 **부트로더를 절대 덮어쓰지 않는 것**입니다.

- Neo65 CU 공식/QMK 애플리케이션은 main flash `0x08000000`에서 시작합니다.
- STM32F072의 공장 USB DFU는 별도의 읽기 전용 system ROM
  `0x1FFFC800`에 있습니다.
- ZMK devicetree의 code partition은 main flash
  `0x08000000`-`0x0801FFFF`만 나타냅니다. system ROM은 이 flash controller와
  linker 영역 밖에 있습니다.
- mass erase, option-byte 변경, system-memory 쓰기 명령은 사용하지 않습니다.
- LINK65의 `0x08006000` 주소나 `1688:2220` DFU ID를 사용하면 안 됩니다.
- 이 저장소는 의도하지 않은 기록을 막기 위해 자동 플래셔를 제공하지 않습니다.

제공된 공식 `neo65cu-wired.bin`을 분석한 기준값은 다음과 같습니다.

| 항목 | 값 |
| --- | --- |
| 파일 크기 | 23,504 bytes (`0x5BD0`) |
| SHA-256 | `9DBB348E7533896B0728E5D3B84CF383D5C35E3E4AA519E94769770E5B369BB3` |
| Initial MSP | `0x20000400` |
| Reset Handler | `0x08000191` |

첫 두 vector word가 main flash 기준 애플리케이션임을 보여 주며, QMK 정의 역시
`STM32F072`와 `stm32-dfu`를 사용합니다.

## 구현된 하드웨어

- MCU: STM32F072xB, Cortex-M0, 48 MHz
- Flash/SRAM: 128 KiB / 16 KiB
- USB: PA11/PA12, Full-Speed, PLL 48 MHz
- 매트릭스: 5행 × 16열, QMK `LAYOUT_wired`의 70개 위치
- 스캔: 행 active-low 출력, 열 active-low pull-up 입력, polling
- 디바운스: press/release 각각 5 ms
- Caps Lock LED: PC13, active-high
- 소프트 ROM DFU: `Esc + Delete + Left Ctrl + Right Arrow`

소프트 ROM DFU 동작은 SRAM에 marker를 쓴 뒤 reset하고 system ROM으로
점프할 뿐, flash와 option bytes에는 아무것도 쓰지 않습니다.

## 빌드

GitHub Actions에서 수동으로 `Build Neo65 CU ZMK firmware` workflow를 실행하면
`neo65cu-zmk.bin`을 포함한 `firmware` artifact가 생성됩니다. 빌드는 ZMK
`v0.3.0` commit에 고정되어 있으며 후속 검증 job이 다음 조건을 검사합니다.

- 이미지 크기 128 KiB 이하
- MSP가 STM32F072의 16 KiB SRAM 안에 있고 8-byte 정렬됨
- Reset Handler가 Thumb code이며 main flash 안에 있음
- system ROM 주소가 애플리케이션 image 범위 밖에 있음

2026-08-09에 source commit `0304665`를 대상으로 실행한
[GitHub Actions run #31291324252](https://github.com/thsrhwk01/zmk-neo_neo56cu/actions/runs/31291324252)에서
보드 탐색, `neo65cu` 빌드, artifact 병합, STM32F072 image-boundary 검증이 모두
성공했습니다. 이는 컴파일 및 정적 검증 결과이며 실기기 플래시/동작 검증을
의미하지 않습니다.

로컬 west workspace가 준비되어 있다면 다음 형태로 빌드할 수 있습니다.

```console
west build -s zmk/app -b neo65cu -- \
  -DZMK_CONFIG=/path/to/zmk-neo_neo65cu/config \
  -DZMK_EXTRA_MODULES=/path/to/zmk-neo_neo65cu
```

PowerShell에서는 원본 또는 빌드 이미지를 정적으로 검사할 수 있습니다.

```powershell
.\tools\inspect-firmware.ps1 .\neo65cu-wired.bin
.\tools\inspect-firmware.ps1 .\neo65cu-zmk.bin
```

## 첫 플래시 전 필수 게이트

다음은 명령 예시가 아니라 **확인 순서**입니다. 하나라도 다르면 중단해야
합니다.

1. 원본 펌웨어 상태에서 Esc를 누른 채 USB를 연결하거나 PCB의 SW1을 사용해
   DFU에 진입합니다.
2. `dfu-util -l`에서 대상이 정확히 `0483:df11`, alternate setting 0,
   STM32 internal flash인지 확인합니다.
3. upload가 허용되면 main flash `0x08000000`부터 `0x20000` bytes를 읽어
   별도 보관하고 크기와 SHA-256을 기록합니다.
4. 공식 `neo65cu-wired.bin`과 복구용 `dfu-util` 환경을 다른 위치에도
   보관합니다.
5. 실제 descriptor/readback 결과를 `dev/porting-notes.md`의 미확인 항목과
   대조합니다.

실기기 확인 전에는 구체적인 download 명령을 이 README에 싣지 않습니다.
검증 뒤에도 쓰기 대상은 main flash의 애플리케이션 시작 주소뿐이어야 하며,
mass erase와 option-byte 변경은 사용하지 않습니다.

## 키맵

기본 키맵은 공식 QMK keymap의 두 레이어를 따릅니다. FN은 왼쪽 화살표 바로
왼쪽 키이며, 1번 레이어에서 숫자열이 Grave/F1-F12가 됩니다.

- `Backspace + Left Ctrl + Left Alt`: ZMK 소프트 reset
- `Esc + Delete + Left Ctrl + Right Arrow`: STM32 system-ROM USB DFU

QMK가 노출한 split Backspace, ISO Enter, split Left Shift, 6.25u/7u bottom-row
matrix 위치를 모두 transform에 포함했습니다. 조립된 스위치 위치에 따라
키맵을 조정할 수 있습니다.

## 현재 제한

- 실기기 USB, 전체 70개 matrix 위치, Caps Lock LED, ROM DFU 진입은 아직
  검증이 필요합니다.
- VIA/Vial 및 ZMK Studio는 지원하지 않습니다.
- 설정 저장용 flash partition은 만들지 않았습니다.
- Bluetooth/2.4 GHz가 없는 유선 PCB만 대상으로 합니다.

분석 근거와 실기기 체크리스트는 [dev/porting-notes.md](dev/porting-notes.md)에
기록합니다.
