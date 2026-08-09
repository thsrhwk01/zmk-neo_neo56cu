# Neo65 CU Wired용 ZMK 포팅

Qwertykeys/NEO Studio **Neo65 CU 유선 PCB**의 STM32F072용 USB 전용 ZMK
보드 정의입니다. Tri-mode PCB, 기존 Neo65, Neo65 Core Plus, Neo65 Sonic HE+
등 다른 PCB에는 사용할 수 없습니다.

> [!WARNING]
> 아래에 식별한 최종 후보는 소스/ELF/BIN 정적 검증을 통과했지만 아직 ZMK
> 실기기 검증 전입니다. DFU descriptor와 전체 main-flash readback은 확인했지만,
> ZMK의 cold-plug Esc 복구 경로를 포함한 단계별 검증이 남아 있습니다. 다른
> commit이나 SHA-256의 BIN으로 대체하지 마십시오.

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
- 초기 ROM DFU 복구: Esc를 누른 채 USB 연결
- 소프트 ROM DFU: `Esc + Delete + Left Ctrl + Right Arrow`

두 경로 모두 SRAM에 marker를 쓴 뒤 reset하고 system ROM으로 점프할 뿐,
flash와 option bytes에는 아무것도 쓰지 않습니다. Esc 확인은 Zephyr GPIO 및
ZMK 초기화 전의 `PRE_KERNEL_1` 단계에서 PA6(row 0)을 low로 구동하고
PC14(column 0)를 pull-up 입력으로 읽습니다. 따라서 정상 ZMK 키 스캔이나 USB
enumeration에 의존하지 않습니다.

ROM DFU가 Cortex-M 전체 reset 없이 애플리케이션을 직접 실행하는 경우도
방어합니다. Zephyr reset 경로의 pre-C platform hook이 먼저 SysTick과 USB
peripheral의 잔류 상태를 지우고 SYSCFG clock을 활성화합니다. 그 뒤
`CONFIG_INIT_ARCH_HW_AT_BOOT`가 CONTROL/NVIC 상태를 초기화하고, Cortex-M0용
vector table을 SRAM `0x20000000`에 복사해 remap합니다. 따라서 system ROM이
0번지에 매핑된 채 넘어와도 첫 interrupt가 ROM vector로 새지 않도록 했습니다.

## 빌드

GitHub Actions의 `Build Neo65 CU ZMK firmware` workflow는 ZMK `v0.3.0`의 정확한
commit `edf5c0814fd3ea202e43aad2d68fd32e882a518c`에 고정되어 있습니다. 표준 ZMK
workflow의 배포 BIN과 별도의 격리 workspace에서 만든 ELF/BIN을 각각 빌드한 뒤
다음을 fail-closed로 검사합니다.

- 48-word vector table 전체의 Thumb bit와 handler payload 범위, USB IRQ 31
- main flash `0x08000000` 링크 시작, 128 KiB 경계, 정확한 ELF LOAD/BIN 포함 관계
- MSP와 실제 1,024-byte Zephyr main stack의 일치, SRAM vector 및 4 KiB 이상 여유
- pre-C platform init → architecture init → C startup 호출 순서
- SoC init → 조기 Esc 복구 → PLL clock init의 링크 순서
- ROM vector 검증, 8-byte SRAM marker, MSP 변경 뒤 stack access가 없는 ROM jump
- HSI 8 MHz × 6 PLL/USB 48 MHz, PA11/PA12, endpoint 수와 HSE/LSE 비활성화
- QMK와 동일한 70개 matrix transform, GPIO 순서/flags, Caps Lock LED와 복구 combo
- flash/settings/NVS/filesystem/watchdog 비활성화 및 persistent-write symbol 부재
- 표준 `firmware` artifact의 BIN과 위 ELF를 감사한 BIN의 byte-for-byte 동일성

2026-08-10 기준 최종 정적 검증 후보는 다음 하나입니다.

| 항목 | 값 |
| --- | --- |
| source commit | `2a36f566802fbc65287ddc931ae285326bfa16f5` |
| Actions run | [#31321651375](https://github.com/thsrhwk01/zmk-neo_neo65cu/actions/runs/31321651375) |
| artifact | `firmware` (ID `9040356512`) |
| raw BIN 이름 | `neo65cu-zmk.bin` |
| 크기 | 38,812 bytes (`0x979C`) |
| SHA-256 | `63669C31092A134764A3B9BB48FF251312EAFF1B73EDF787DABD2427C6BBF74A` |
| Initial MSP | `0x20001E18` |
| Reset Handler | `0x080024B5` |
| nonzero handler vectors | 38 |

모든 job이 성공했고 독립 감사 BIN과 배포 BIN에서 위 값이 동일했습니다. ZIP
artifact의 digest가 아니라 압축을 푼 **raw BIN**의 SHA-256을 비교해야 합니다.
이전에 받은 `98FE8504...` 등 다른 SHA-256의 `neo65cu-zmk.bin`은 현재 소스와
일치하지 않는 폐기 후보입니다. 이 결과는 컴파일/정적 검증이며 실기기 USB,
matrix 및 복구 동작 성공을 의미하지는 않습니다.

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

1. 위 run의 `firmware` artifact만 내려받아 압축을 풀고, raw BIN의 이름, 크기,
   SHA-256이 표와 완전히 같은지 확인합니다.
2. 원본 펌웨어 상태에서 Esc를 누른 채 USB를 연결해 DFU에 진입합니다. Neo65
   CU는 main PCB와 케이스 고정 daughterboard가 자석식 pogo pin으로 연결되어
   조립·접속 상태에서 PCB 뒷면 SW1 접근이 어려우므로, SW1을 필수 복구 경로로
   간주하지 않습니다.
3. `dfu-util -l`에서 대상이 정확히 `0483:df11`, alternate setting 0,
   STM32 internal flash인지 확인합니다.
4. upload가 허용되면 main flash `0x08000000`부터 `0x20000` bytes를 읽어
   별도 보관하고 크기와 SHA-256을 기록합니다.
5. 공식 `neo65cu-wired.bin`과 복구용 `dfu-util` 환경을 다른 위치에도
   보관합니다.
6. 실제 descriptor/readback 결과를 `dev/porting-notes.md`의 미확인 항목과
   대조합니다.

실기기 확인 전에는 구체적인 download 명령을 이 README에 싣지 않습니다.
검증 뒤에도 쓰기 대상은 main flash의 애플리케이션 시작 주소뿐이어야 하며,
mass erase와 option-byte 변경은 사용하지 않습니다.

## 키맵

기본 키맵은 공식 QMK keymap의 두 레이어를 따릅니다. FN은 왼쪽 화살표 바로
왼쪽 키이며, 1번 레이어에서 숫자열이 Grave/F1-F12가 됩니다.

- `Backspace + Left Ctrl + Left Alt`: ZMK 소프트 reset
- Esc를 누른 채 USB 연결: ZMK 초기 부팅 단계에서 STM32 system-ROM USB DFU
- `Esc + Delete + Left Ctrl + Right Arrow`: STM32 system-ROM USB DFU

QMK가 노출한 split Backspace, ISO Enter, split Left Shift, 6.25u/7u bottom-row
matrix 위치를 모두 transform에 포함했습니다. 조립된 스위치 위치에 따라
키맵을 조정할 수 있습니다.

## 현재 제한

- 실기기 USB, 전체 70개 matrix 위치, Caps Lock LED, ZMK cold-plug Esc 및
  four-corner ROM DFU 진입은 아직 검증이 필요합니다.
- VIA/Vial 및 ZMK Studio는 지원하지 않습니다.
- 설정 저장용 flash partition은 만들지 않았습니다.
- Bluetooth/2.4 GHz가 없는 유선 PCB만 대상으로 합니다.

분석 근거와 실기기 체크리스트는 [dev/porting-notes.md](dev/porting-notes.md)에
기록합니다.
