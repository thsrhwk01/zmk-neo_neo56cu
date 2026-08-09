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

2026-08-09 GitHub Actions 결과:

- repository: `thsrhwk01/zmk-neo_neo65cu`
- source commit: `03046650512806228579bc332836a2ec4a37732d`
- run: [#31291324252](https://github.com/thsrhwk01/zmk-neo_neo65cu/actions/runs/31291324252)
- `Fetch Build Keyboards`: success
- `Build (neo65cu)`: success
- `Merge Output Artifacts`: success
- `Verify STM32F072 image boundaries`: success
- generated artifact: `firmware`

다운로드한 `neo65cu-zmk.bin`을 로컬에서도 재검사했습니다.

- size: 38,452 bytes (`0x9634`)
- SHA-256: `359CA48EE7CC099E82E363FCA47B47B7CE5A9273ED822C0E5B8E94E9647EC991`
- Initial MSP: `0x20001E18`
- Reset Handler: `0x080024B5`
- main flash 및 STM32F072 SRAM 경계 검사: pass

이 run에서는 어떤 USB/DFU 장치에도 접근하지 않았고 실기기 flash write도 하지
않았습니다. artifact 다운로드 API는 인증이 필요하므로 이 세션에서는 생성
여부까지만 공개 API로 재확인했습니다.

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
- [x] ZMK image의 MSP/Reset Handler/크기 정적 검사 (Actions run #31291324252)
- [ ] ZMK USB enumeration 3회 cold-plug 확인
- [ ] 70개 matrix 위치 및 optional layout footprints 확인
- [ ] 단일 키 입력 시 인접 키 동시 입력/잔류 여부 확인
- [ ] Caps Lock LED active-high 확인
- [ ] four-corner combo로 ROM DFU 진입 확인
- [ ] ROM DFU에서 official BIN 복원 확인
- [ ] 각 단계 뒤 cold-plug Esc DFU 진입 재확인

실기기 결과는 날짜, source commit, firmware SHA-256, 사용한 정확한 명령과 함께
이 문서에 추가합니다.
