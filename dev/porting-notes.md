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

## 실기기 검증 대기 항목

- [ ] PCB 실크와 MCU marking 사진 기록 (`STM32F072CBT6` 예상)
- [ ] SW1/hold-Esc로 DFU 진입 확인
- [ ] DFU VID/PID `0483:df11` 확인
- [ ] alternate setting과 memory descriptor 원문 기록
- [ ] main flash 128 KiB readback 및 SHA-256 기록
- [ ] official BIN 복원 성공 확인
- [ ] ZMK image의 MSP/Reset Handler/크기 정적 검사
- [ ] ZMK USB enumeration 3회 cold-plug 확인
- [ ] 70개 matrix 위치 및 optional layout footprints 확인
- [ ] 단일 키 입력 시 인접 키 동시 입력/잔류 여부 확인
- [ ] Caps Lock LED active-high 확인
- [ ] four-corner combo로 ROM DFU 진입 확인
- [ ] ROM DFU에서 official BIN 복원 확인
- [ ] 각 단계 뒤 physical DFU 진입 재확인

실기기 결과는 날짜, source commit, firmware SHA-256, 사용한 정확한 명령과 함께
이 문서에 추가합니다.
