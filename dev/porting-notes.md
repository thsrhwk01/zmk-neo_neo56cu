# Neo65 CU ZMK 포팅 기록

## 안전 불변 조건

1. 부트로더 또는 system memory를 쓰거나 지우지 않는다.
2. mass erase와 option-byte 변경을 하지 않는다.
3. 실기기 DFU descriptor와 readback을 확인하기 전에는 첫 플래시를 진행하지
   않는다.
4. 자동 플래셔는 실기기 검증 SHA-256, 정확한 DFU descriptor와 alt 0만 허용하고,
   기록 전 128 KiB readback 및 기록 후 exact readback 검증을 fail-closed로
   수행한다. 새 BIN은 같은 실기기 절차를 통과하기 전 배포 manifest에 등록하지
   않는다.
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

초기 bring-up의 ELF/symbol/disassembly 검사로 위 세 함수 호출 순서와 SRAM
vector 크기/주소를 확인했습니다. application에서 ROM으로 갈 때는 반대로 SysTick,
NVIC와 memory map을 정리한 뒤, `MSR MSP` 이후 memory access가 없는 inline-asm
trampoline으로 ROM Reset Handler에 분기합니다.

Neo65 CU의 main PCB는 케이스에 고정된 daughterboard와 자석식 pogo pin으로
접속합니다. 따라서 완전 조립 상태에서는 PCB 뒷면 접점에 접근하기 어렵고, 이를
유일한 복구 수단으로 가정할 수 없습니다. 공식 Neo65/60 Cu 빌드 가이드의
Wired PCB firmware 절차도 Esc 스위치를 장착하고 Esc를 누른 채 USB를 다시
연결해 DFU에 진입하도록 안내합니다:
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

## 자동 빌드와 배포

LINK65 저장소의 build → package → tag release 흐름을 가져오되, LINK65 전용
flash bootloader offset과 VID/PID는 사용하지 않습니다. 현재 Neo65 CU workflow는
다음 순서로 동작합니다.

1. 고정한 ZMK commit으로 표준 ZMK reusable workflow를 한 번 실행합니다.
2. `inspect-firmware.ps1`로 raw BIN의 크기, MSP, Reset Handler와 vector 주소를
   확인합니다.
3. built BIN이 [release/neo65cu-zmk.sha256](../release/neo65cu-zmk.sha256)의
   실기기 검증 해시와 정확히 일치하는지 확인합니다.
4. 검증된 dfu-util 0.11 Windows binary와 대응 source archive, 전용 스크립트를
   `NEO65CU-ZMK-Windows` artifact로 묶고 `-ValidateOnly` 검사를 실행합니다.
5. `v*.*` tag push에는 ZIP, raw BIN 및 외부 체크섬을 GitHub Release에도
   게시합니다.

Windows 스크립트는 firmware/vector/hash 검사를 먼저 끝낸 뒤 사용자에게 GUI
확인을 받습니다. 이어서 fresh `dfu-util -l`을 반복 실행해 정확히 한 개의
`0483:df11` 장치가 verified alt 0/alt 1 memory descriptor를 모두 제공하는지
확인하고, 그 path/serial만 사용합니다. 쓰기 전에는 alt 0 main flash 전체
`0x20000` bytes를 자동 upload하며, 쓰기 뒤에는 BIN 길이만큼 다시 upload해
SHA-256을 비교합니다. 실제 download 호출에는 항상 `-a 0 -s 0x08000000`만
들어가며 alt 1, mass erase와 `:leave`는 없습니다.

manifest 해시는 convenience checksum이 아니라 hardware-release 승인 gate입니다.
source 변경으로 BIN이 달라지면 build와 구조 검사가 통과하더라도 package job이
실패해야 정상입니다. 새 값을 manifest에 쓰려면 새 BIN으로 기존의 descriptor, pre-flash
backup, immediate readback, cold boot, 전체 장착 키/LED 및 세 ROM DFU 복구 경로를
다시 확인해야 합니다.

### 실기기 승인 공개 이미지

2026-08-10에 source commit
`2a36f566802fbc65287ddc931ae285326bfa16f5`를 대상으로 실행한
[GitHub Actions run #31321651375](https://github.com/thsrhwk01/zmk-neo_neo65cu/actions/runs/31321651375)의
모든 build 및 당시 심층 검사 job이 성공했습니다.

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

초기 포트의 bring-up 단계에서는 별도의 ELF/map/config/DTS build와 표준 BIN 비교도
수행했습니다. 해당 일회성 검사 코드는 실기기 검증 완료 후 active workflow와
저장소에서 제거했습니다. 현재 CI에 남은 경량 검사는 부트 가능한 이미지를 증명하는
대신 명백히 잘못된 크기·MSP·vector와 승인되지 않은 hash의 배포를 차단합니다.
GitHub가 표시하는 artifact digest는 ZIP digest이므로 raw BIN SHA-256과 혼동하지
않습니다.

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

## 2026-08-11 첫 ZMK 실기기 검증

PCB 뒷면 사진 3장에서 MCU marking `STM32F072CBT6`를 확인했습니다. QMK
문서에는 PCB 하단의 물리 버튼을 `SW1`이라고 적었지만, 실제 PCB에는 버튼이
실장되어 있지 않고 MCU 부근 하단에 실크 `SW?`와 2핀 through-hole footprint만
있습니다.

전원이 켜져 정상 입력 중일 때 이 두 패드를 쇼트해도 USB disconnect나 키 입력
중단은 없었습니다. 반면 두 패드를 먼저 쇼트하고 USB 전원을 인가한 뒤 해제하면
다음 system-ROM DFU descriptor가 열렸습니다.

- VID/PID: `0483:df11`
- serial: `FFFFFFFEFFFF`
- alt 0: internal flash `0x08000000`, 64 × 2 KiB
- alt 1: option bytes `0x1FFFF800` (선택하지 않음)

따라서 이 footprint가 기능상 애플리케이션 독립적인 boot-selection 복구
접점임을 확인했습니다. 회로도나 MCU pin continuity를 측정하지 않았으므로 정확한
net 이름은 기록하지 않습니다.

최종 raw BIN은 38,812 bytes이며 SHA-256은 다음과 같습니다.

`63669C31092A134764A3B9BB48FF251312EAFF1B73EDF787DABD2427C6BBF74A`

fresh `dfu-util -l` 결과의 path/serial을 지정하고 alt 0만 선택해
`0x08000000`에 기록했습니다. erase와 download가 각각 100% 완료됐고, alt 1,
mass erase 및 `:leave`는 사용하지 않았습니다. 같은 DFU session에서 재부팅 전에
`0x08000000:0x979C`를 `neo65cu-zmk-first-flash-readback.bin`으로 upload했습니다.
실제로 사용한 명령은 다음과 같습니다.

```powershell
dfu-util -d ",0483:df11" -p "2-2.3" -S "FFFFFFFEFFFF" `
  -a 0 -s "0x08000000" `
  -D ".\firmware\neo65cu-zmk.bin"

dfu-util -d ",0483:df11" -p "2-2.3" -S "FFFFFFFEFFFF" `
  -a 0 -s "0x08000000:0x979C" `
  -U ".\neo65cu-zmk-first-flash-readback.bin"
```

USB path는 재연결 시 달라질 수 있으므로 이 값은 기록일 당시의 값이며, 재사용
전에 반드시 fresh `dfu-util -l`로 다시 확인해야 합니다.

readback 결과는 다음과 같습니다.

- size: 38,812 bytes
- SHA-256: `63669C31092A134764A3B9BB48FF251312EAFF1B73EDF787DABD2427C6BBF74A`
- 배포 BIN과 exact match: `True`
- Initial MSP: `0x20001E18`
- Reset Handler: `0x080024B5`
- invalid vector: 0

USB를 완전히 분리한 뒤 아무 키 없이 세 차례 cold boot해 정상 USB enumeration,
Windows 키 입력과 Caps Lock LED 전환을 확인했습니다. 이어서 다음 두
애플리케이션 복구 경로도 각각
`0483:df11` system-ROM DFU 진입에 성공했습니다.

1. Esc를 누른 채 USB 연결
2. 정상 실행 중 `Esc + Delete + Left Ctrl + Right Arrow` 동시 입력

이로써 하드웨어 `SW?`, ZMK 조기 Esc, 실행 중 four-corner combo의 세 ROM DFU
진입 경로가 실기기에서 확인됐습니다.

현재 장착된 layout의 모든 키를 개별 검사했습니다. 각 키는 정확히 하나의
입력만 발생했고, release 뒤 잔류 입력이나 인접 키 동시 입력이 없었습니다.
Fn 키와 `Fn + Esc`, `Fn + 1`부터 `Fn + =`까지의 Grave/F1-F12 레이어도
정상 동작했습니다. 미장착 ISO/split optional footprint는 이 검사에 포함하지
않았습니다.

정상 실행 중 `Backspace + Left Ctrl + Left Alt`를 동시에 입력했을 때 USB가
끊겼다가 ZMK 애플리케이션으로 정상 재연결됐으며, 이후 키 입력도 정상임을
확인했습니다.

## 실기기 검증 결과 및 선택 잔여 항목

- [x] PCB 실크와 MCU marking 사진 기록 (`STM32F072CBT6`)
- [x] 현재 Vial에서 hold-Esc로 DFU 진입 확인
- [x] ZMK 초기 부팅 hold-Esc로 DFU 재진입 확인
- [x] PCB 뒷면 미실장 `SW?` 위치와 power-on hardware DFU 동작 기록
- [x] DFU VID/PID `0483:df11` 확인
- [x] alternate setting과 memory descriptor 원문 기록
- [x] main flash 128 KiB readback 및 SHA-256 기록
- [x] 최종 ZMK BIN alt 0 기록 및 동일 길이 readback exact-match 확인
- [x] ZMK image/ELF/map/config/DTS 및 배포 BIN 동일성 정적 검사
      (Actions run #31321651375)
- [x] ZMK USB enumeration 3회 cold-plug 확인
- [x] 현재 장착 layout의 모든 키와 Fn 레이어 확인
- [ ] 미장착 ISO/split optional layout footprints 확인
- [x] 단일 키 입력 시 인접 키 동시 입력/잔류 없음 확인
- [x] Caps Lock LED active-high 확인
- [x] `Backspace + Left Ctrl + Left Alt` 애플리케이션 재시작 확인
- [x] four-corner combo로 ROM DFU 진입 확인
- [ ] official/Vial 원본 복구 드릴 (정상 보드의 불필요한 재기록을 피하려고 미실행)
- [x] 첫 ZMK flash 뒤 cold-plug Esc DFU 재진입 확인

실기기 결과는 날짜, source commit, firmware SHA-256, 사용한 정확한 명령과 함께
이 문서에 추가합니다.

## 2026-08-12 키맵 입력 지연 정리

기존 애플리케이션 재시작 및 ROM DFU combo의 구성 키는 combo timeout 동안 단독
입력이 보류되어 일반적인 Backspace, Ctrl, Alt, Esc, Delete와 화살표 사용에서
지연이 느껴졌습니다. 두 combo를 제거하고 같은 behavior를 Fn 레이어의
`Fn + Backspace`와 `Fn + Delete`에 각각 배치했습니다.

Keymap Editor용 `config/neo65cu.json`의 `row`/`col`은 전기적 matrix 좌표가 아니라
시각적 레이아웃 내 순번입니다. 네 번째 행을 `row 3, col 0..14`, 하단 행을
`row 4, col 0..8`로 정리했습니다. 실제 kscan 및 matrix transform은 변경하지
않았습니다.

이 변경으로 생성되는 새 BIN은 build 및 구조 검사 뒤 `Fn + Backspace`,
`Fn + Delete`, 일반 구성 키의 지연 해소를 실제 보드에서 확인하기 전까지 release
manifest에 승인하지 않습니다.
