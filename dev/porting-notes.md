# Neo65 CU ZMK 포팅 기록

## 안전 불변 조건

1. 부트로더 또는 system memory를 쓰거나 지우지 않는다.
2. mass erase와 option-byte 변경을 하지 않는다.
3. 실기기 DFU descriptor와 readback을 확인하기 전에는 첫 플래시를 진행하지
   않는다.
4. 자동 플래셔를 만들기 전에 수동 절차와 복구 절차를 실기기에서 각각 세 번
   검증한다.
5. PCB 모델/리비전/MCU marking이 다르면 같은 firmware를 사용하지 않는다.

## 확인한 근거

### QMK Neo65 CU 정의

- processor: `STM32F072`
- bootloader: `stm32-dfu`
- matrix: 5 × 16, `COL2ROW`
- cols: PC14, PC15, PA0, PA1, PA2, PA3, PA4, PB2, PB10, PB11, PB12,
  PB13, PB14, PB15, PA8, PA9
- rows: PA6, PA7, PB0, PB1, PB9
- Caps Lock LED: PC13, active-high
- USB application VID/PID: `4E45:4355`

QMK `COL2ROW` 구현은 각 row를 low로 구동하고 pull-up column을 읽습니다.
ZMK에서는 같은 scan topology가 `row2col`입니다.

QMK ChibiOS 기본 timing은 입력 전 약 0.25 us와 row 해제 후 30 us입니다.
ZMK 정수 설정에는 각각 1 us와 30 us를 사용했습니다.

### 공식 애플리케이션 BIN

`neo65cu-wired.bin`:

- size: 23,504 bytes (`0x5BD0`)
- SHA-256: `9DBB348E7533896B0728E5D3B84CF383D5C35E3E4AA519E94769770E5B369BB3`
- word 0: `0x20000400` (valid SRAM pointer)
- word 1: `0x08000191` (Thumb Reset Handler in main flash)
- UTF-16 strings include `NEO Studio` and `Neo65 Cu`

파일의 첫 word부터 vector table이므로 vendor application은 `0x08000000`에
기록되는 raw binary입니다. LINK65처럼 main flash 앞부분에 별도 flash
bootloader를 둔 형태가 아닙니다.

### STM32F072/Zephyr 기준

- STM32F072xB main flash: `0x08000000` + 128 KiB
- SRAM: `0x20000000` + 16 KiB
- factory system-memory bootloader entry: `0x1FFFC800`
- USB DFU가 사용하는 PA11/PA12는 matrix와 겹치지 않음
- Zephyr F072 USB clock node는 PLLCLK를 사용하므로 HSI 8 MHz × 6 = 48 MHz
- PC14/PC15를 matrix GPIO로 쓰므로 HSE/LSE는 활성화하지 않음

system memory는 mask ROM 영역이므로 main flash code partition이나 `.bin`에
포함되지 않습니다. 이 사실이 실기기 검증 생략을 허용하는 것은 아닙니다.

Cortex-M0에는 VTOR가 없으므로 소프트 ROM DFU 진입 시 SYSCFG clock을 켜고
system flash를 `0x00000000`에 remap한 뒤 ROM Reset Handler로 분기합니다.
이 과정에서 쓰는 것은 SRAM marker와 volatile peripheral register뿐이며 flash,
option bytes, system ROM에는 쓰지 않습니다.

Zephyr 3.5 STM32F0의 `relocate_vector_table()`은 C runtime보다 먼저 실행되지만,
일반 clock-control driver가 SYSCFG clock을 켜는 시점은 그보다 뒤입니다. Cold
boot에서는 main flash가 이미 0번지라 이 차이가 드러나지 않지만, ROM DFU가
system memory를 0번지에 둔 채 애플리케이션을 직접 chain-load하면 interrupt
vector remap 실패 원인이 될 수 있습니다. 이를 막기 위해
`CONFIG_PLATFORM_SPECIFIC_INIT=y`와 `src/neo65cu_platform_init.c`를 추가했습니다.
pre-C hook은 다음 순서로 동작합니다.

1. interrupt를 잠그고 SysTick 및 PendSV/PendST pending을 지웁니다.
2. ROM이 사용한 USB peripheral을 RCC reset으로 초기 상태로 되돌립니다.
3. SYSCFG APB clock을 켜 SRAM vector remap이 실제 register에 반영되게 합니다.
4. 이어지는 `CONFIG_INIT_ARCH_HW_AT_BOOT=y`가 CONTROL과 NVIC enable/pending을
   정리합니다.
5. `z_arm_prep_c()`가 48-word vector를 SRAM `0x20000000`에 복사하고 SRAM을
   0번지로 remap합니다.

최종 ELF audit는 위 세 함수 호출 순서와 SRAM vector 크기/주소를 symbol 및
disassembly로 확인합니다. application에서 ROM으로 갈 때는 반대로 SysTick,
NVIC와 memory map을 정리한 뒤, `MSR MSP` 이후 memory access가 없는 inline-asm
trampoline으로 ROM Reset Handler에 분기합니다.

Neo65 CU의 main PCB는 케이스에 고정된 daughterboard와 자석식 pogo pin으로
접속합니다. 따라서 접속 상태에서 PCB 뒷면의 SW1을 누르기 어렵고, SW1을 유일한
복구 수단으로 가정할 수 없습니다. 공식 Neo65/60 Cu 빌드 가이드의 Wired PCB
firmware 절차도 Esc 스위치를 장착하고 Esc를 누른 채 USB를 다시 연결해 DFU에
진입하도록 안내합니다:
https://qwertykeys.notion.site/Neo65-60-Cu-Build-Guide-1863d090094280babee7ce4ff3901aa8

ZMK 포트는 이 동작을 보존합니다. `PRE_KERNEL_1`에서 다른 GPIO/USB/ZMK 장치가
초기화되기 전에 Esc의 실제 matrix 교차점인 PA6(row 0)/PC14(column 0)만
일시적으로 스캔합니다. Esc가 눌렸으면 SRAM marker를 기록해 reset한 뒤 immutable
system-ROM DFU로 분기합니다. Esc가 아니면 변경한 GPIO/RCC register를 모두 원래
값으로 복원합니다. 이 경로 역시 main flash, option bytes, system ROM을 쓰지
않습니다.

## Link65 포팅에서 적용한 교훈

- DFU의 쓰기 가능 범위와 실제 application vector 주소를 같은 것으로 가정하지
  않는다.
- MCU가 비슷해도 bootloader offset/chain-load 조건을 복사하지 않는다.
- USB clock을 matrix보다 먼저 검증한다.
- diode 이름 대신 실제로 어느 GPIO를 구동하고 어느 GPIO를 읽는지 확인한다.
- GPIO input propagation과 output switching delay를 모두 옮긴다.
- 복구 경로를 기능 검증보다 먼저 시험한다.

Neo65 CU에는 Link65 전용 `0x08006000` partition, APM32F103 MSP mask, early-stack
linker snippet, `1688:2220` VID/PID를 적용하지 않았습니다.

## 자동 빌드 검증

### 최종 정적 검증 후보

2026-08-10에 source commit
`2a36f566802fbc65287ddc931ae285326bfa16f5`를 대상으로 실행한
[GitHub Actions run #31321651375](https://github.com/thsrhwk01/zmk-neo_neo65cu/actions/runs/31321651375)의
모든 job이 성공했습니다.

| job | 결과 |
| --- | --- |
| `Fetch Build Keyboards` | success |
| 표준 ZMK `Build (neo65cu)` | success |
| `Merge Output Artifacts` | success |
| 독립 `Build auditable ELF and metadata` | success |
| `Verify exact release BIN` | success |

두 빌드는 서로 독립된 west workspace에서 정확히 고정한 ZMK commit
`edf5c0814fd3ea202e43aad2d68fd32e882a518c`를 사용합니다. 독립 빌드의
ELF/map/config/generated DTS를 감사한 뒤, 표준 `firmware` artifact의 raw BIN과
byte-for-byte 비교했습니다. 양쪽 성공 주석에 기록된 값은 동일합니다.

| 항목 | 값 |
| --- | --- |
| artifact | `firmware`, ID `9040356512` |
| raw BIN | `neo65cu-zmk.bin` |
| size | 38,812 bytes (`0x979C`) |
| application end | `0x0800979C` |
| SHA-256 | `63669C31092A134764A3B9BB48FF251312EAFF1B73EDF787DABD2427C6BBF74A` |
| Initial MSP | `0x20001E18` |
| Reset Handler | `0x080024B5` |
| nonzero handler vectors | 38 |

`audit-neo65cu` artifact(ID `9040368094`)에는 정확히 검사한 `zmk.bin`, ELF, map,
`.config`, generated DTS, symbols 및 disassembly가 들어 있습니다. GitHub가
표시하는 artifact digest는 ZIP digest이므로 raw BIN SHA-256과 혼동하지 않습니다.

검사는 다음 항목을 fail-closed로 고정합니다.

- 48개 vector 전체와 USB IRQ 31, ELF LOAD와 raw BIN payload 경계
- main flash/SRAM/linker partition, main stack/MSP, SRAM vector 및 RAM 여유
- pre-C platform/architecture/C startup과 SoC/Esc/clock init 순서
- ROM 주소/vector, SRAM marker 및 MSP 변경 뒤 stack access 없는 jump tail
- HSI/PLL/USB clock tree, oscillator 상태, endpoint와 PA11/PA12
- QMK와 동일한 70개 transform, matrix GPIO/flags, LED와 recovery combo
- flash/settings/NVS/filesystem/watchdog 비활성화와 write symbol 부재
- 표준 배포 BIN과 감사 BIN의 완전 동일성

### 감사 도구를 다듬은 과정

- run `#31319558952`: 실제 map의 section 줄바꿈 형식을 parser가 잘못 가정
- run `#31319948476`: Actions container의 ARM binutils 절대 경로를 찾지 못함
- run `#31321068519`: 사용 끝 symbol인 `__rom_region_end`를 flash region 끝으로
  잘못 해석
- run `#31321291929`: 동일 주소의 reset symbol alias 때문에 제한 disassembly가
  비어 있었음

각 경우 표준/독립 firmware build 자체는 성공했고, 실패 원인은 강화 중인 audit
harness의 오탐이었습니다. map 형식, CMake가 기록한 실제 tool 경로, symbol 의미,
linked reset 주소 범위를 사용하도록 각각 수정한 뒤 최종 run에서 전부
통과했습니다. 초기 `359CA48E...`, 이후 로컬에 받았던 `98FE8504...` 등 최종
SHA-256과 다른 BIN은 모두 폐기 후보입니다. 이 전체 과정에서 실기기 download,
erase 또는 option-byte 명령은 실행하지 않았습니다.

## 실기기 DFU 및 원본 readback 확인

2026-08-09, `dfu-util 0.11`로 확인한 실제 장치:

- DFU VID/PID: `0483:df11`
- serial: `FFFFFFFEFFFF`
- 확인 당시 USB path: `2-2.3`
- alt 0: `@Internal Flash  /0x08000000/064*0002Kg`
- alt 1: `@Option Bytes  /0x1FFFF800/01*016 e`
- alt 1은 모든 절차에서 선택 금지

alt 0의 main flash `0x08000000`부터 `0x20000` bytes를 두 번 upload했습니다.
두 파일은 모두 131,072 bytes이고 SHA-256이 아래 값으로 일치했습니다.

`EB3710B65CA65CD43B4EB58027EAB8E7CB843F8DB1DEFDC036ED738CF9093F8C`

readback vector는 Initial MSP `0x20000400`, Reset Handler `0x08000191`로
유효합니다. 첫 upload 전에 남아 있던 `dfuERROR/status(10)`은 dfu-util이
clear한 뒤 `dfuIDLE/status(0)`가 되었고, 이후 두 번 모두 131,072 bytes upload가
완료됐습니다. 이 과정에서 download/erase/option-byte 명령은 실행하지
않았습니다.

현재 설치 이미지는 제공된 공식 `neo65cu-wired.bin`과 동일하지 않습니다.
readback에 `vial:f64c2b3c` 식별 문자열이 있고, main code가 flash page 0-17에,
2 bytes의 설정 데이터가 page 60 (`0x0801E000`)에 있습니다. 따라서 이 두
readback은 현재 설치된 Vial 포트를 되돌릴 때 사용하는 원본 복구 자료입니다.
제공된 공식 BIN은 별도의 VIA 복구 자료로 유지합니다.

## 실기기 검증 대기 항목

- [ ] PCB 실크와 MCU marking 사진 기록 (`STM32F072CBT6` 예상)
- [x] 현재 Vial에서 hold-Esc로 DFU 진입 확인
- [ ] ZMK 초기 부팅 hold-Esc로 DFU 재진입 확인
- [ ] PCB 뒷면 SW1 위치와 pogo-pin 접속 중 접근 가능 여부 기록
- [x] DFU VID/PID `0483:df11` 확인
- [x] alternate setting과 memory descriptor 원문 기록
- [x] main flash 128 KiB readback 및 SHA-256 기록
- [ ] official BIN 복원 성공 확인
- [x] ZMK image/ELF/map/config/DTS 및 배포 BIN 동일성 정적 검사
      (Actions run #31321651375)
- [ ] ZMK USB enumeration 3회 cold-plug 확인
- [ ] 70개 matrix 위치 및 optional layout footprints 확인
- [ ] 단일 키 입력 시 인접 키 동시 입력/잔류 여부 확인
- [ ] Caps Lock LED active-high 확인
- [ ] four-corner combo로 ROM DFU 진입 확인
- [ ] ROM DFU에서 official BIN 복원 확인
- [ ] 각 단계 뒤 cold-plug Esc DFU 진입 재확인

실기기 결과는 날짜, source commit, firmware SHA-256, 사용한 정확한 명령과 함께
이 문서에 추가합니다.
