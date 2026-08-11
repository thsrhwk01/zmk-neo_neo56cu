# STM32 ROM DFU를 보존하며 Neo65 CU 유선 PCB에 ZMK 포팅하기

[English](porting-guide.md)

이 문서는 Qwertykeys/NEO Studio Neo65 CU 유선 PCB의 `STM32F072CBT6`에
ZMK를 포팅하면서 확인한 근거, 설계 결정, 실패한 검사와 실기기 검증 순서를
기록합니다. SWD/J-Link debugger 없이 작업했으므로 USB DFU 복구 경로 보존을
마지막 편의 기능이 아니라 첫 번째 요구 조건으로 삼았습니다.

이 문서의 값은 다른 Neo 또는 STM32 키보드에 그대로 복사하기 위한 설정이
아닙니다. 다음 하드웨어 계약을 각각 어떻게 독립적으로 확인했는지 설명하는 것이
목적입니다.

- 부트로더가 쓰기 가능한 main flash에 있는지, 변경 불가능한 system ROM에
  있는지
- 애플리케이션 vector table과 ELF LOAD segment가 어느 주소에서 시작해야 하는지
- VTOR가 없는 Cortex-M0에서 애플리케이션과 ROM 부트로더가 제어권을 주고받는
  방법
- USB에 필요한 정확한 48 MHz를 만드는 clock path
- Matrix pin 순서, scan 방향, 극성, timing 및 optional 위치
- 빌드 BIN을 감사한 ELF와 연결하고 다시 실제 보드의 readback과 연결한 방법

> [!WARNING]
> 아래의 모든 주소, USB ID, GPIO와 복구 동작은
> **STM32F072CBT6가 실장된 Neo65 CU 유선 PCB**에서 확인했습니다. Tri-mode PCB,
> 기존 Neo65, Neo65 Core Plus, Neo65 Sonic HE+, LINK65 및 식별되지 않은 revision에
> 사용하지 마십시오. DFU alt 1 선택, Option Bytes 변경 및 mass erase는 절대
> 사용하지 않습니다.

## 1. 검증된 Neo65 CU 기준점

| 항목 | 값 |
| --- | --- |
| PCB | Qwertykeys/NEO Studio Neo65 CU 유선 PCB |
| MCU marking | STMicroelectronics `STM32F072CBT6` |
| CPU | Cortex-M0, 48 MHz |
| Clock source | 내부 8 MHz HSI, PLL × 6 |
| Main flash | 128 KiB, `0x08000000`-`0x0801FFFF` |
| SRAM | 16 KiB, `0x20000000`-`0x20003FFF` |
| USB | PA11/PA12, 48 MHz Full-Speed |
| 공장 DFU USB ID | `0483:df11` |
| 애플리케이션 시작 | `0x08000000` |
| 공장 부트로더 | `0x1FFFC800`의 STM32 system ROM |
| Matrix | 5행 × 16열, `LAYOUT_wired` 논리 위치 70개 |
| Caps Lock LED | PC13, active-high |

다음 raw image를 실제 하드웨어에서 검증했습니다.

| 항목 | 값 |
| --- | --- |
| Source | [`2a36f566`](https://github.com/thsrhwk01/zmk-neo_neo65cu/commit/2a36f566802fbc65287ddc931ae285326bfa16f5) |
| Build | [GitHub Actions run `31321651375`](https://github.com/thsrhwk01/zmk-neo_neo65cu/actions/runs/31321651375) |
| 파일 | `neo65cu-zmk.bin` |
| 크기 | 38,812 bytes (`0x979C`) |
| SHA-256 | `63669C31092A134764A3B9BB48FF251312EAFF1B73EDF787DABD2427C6BBF74A` |
| Initial MSP | `0x20001E18` |
| Reset Handler | `0x080024B5` |
| Nonzero handler vectors | 38 |

BIN을 한 번 기록한 뒤 재부팅하기 전에 다시 upload하여 byte-for-byte 비교했습니다.
장착된 모든 스위치, Fn 레이어, Caps Lock LED, 세 번의 cold boot, 애플리케이션
재시작과 서로 독립적인 세 가지 ROM DFU 진입 경로가 모두 통과했습니다. 미실장
ISO/split optional footprint는 확인 대상에서 남아 있습니다.

## 2. ROM DFU가 유일한 복구 경로일 때의 안전 원칙

STM32F072 공장 부트로더는 flash 안의 부트로더가 아니라 mask ROM입니다. 일반적인
alt 0 main-flash 기록으로 이 ROM을 덮어쓸 수는 없습니다. 하지만 그렇다고 임의의
DFU 동작이 안전한 것은 아닙니다. Option Bytes 변경은 boot 선택과 보호 설정에
영향을 줄 수 있고, 잘못된 주소에 링크된 이미지는 애플리케이션 부팅을 막을 수
있습니다.

이 포팅에서는 다음 불변 조건을 사용했습니다.

1. 빌드를 고르기 전에 정확한 PCB와 MCU marking을 확인합니다.
2. 애플리케이션과 무관한 ROM DFU 진입 방법을 먼저 증명합니다.
3. 매 session마다 fresh DFU descriptor, USB path와 serial을 기록합니다.
4. 현재 main flash 128 KiB를 두 번 읽어 hash를 비교합니다.
5. 공식 BIN과 전체 readback을 외부 복구 백업에 보관합니다.
6. 애플리케이션은 main flash `0x08000000`에만 링크하고 기록합니다.
7. alt 1, Option Bytes 기록, mass erase와 system memory 기록을 사용하지 않습니다.
8. 재부팅 전에 기록한 정확한 길이만큼 upload해 BIN과 비교합니다.
9. 첫 ZMK 부팅 뒤 ROM DFU 재진입을 다시 확인합니다.
10. 전체 실기기 검증을 반복하기 전에는 새 release hash를 승인하지 않습니다.

LINK65 값을 이 포트에 복사하면 안 됩니다. LINK65는 보호된 flash 부트로더,
`0x08006000` 애플리케이션 offset과 `1688:2220` USB ID를 사용하며, 어느 값도
Neo65 CU에 적용되지 않습니다.

## 3. 빌드 전에 백업과 복구 경로부터 만든다

### 3.1 실제 DFU 장치 식별

정상 동작하는 원본 펌웨어 상태에서 USB를 분리하고 `Esc`를 누른 채 케이블을 다시
연결합니다. 다음 명령으로 장치를 조회합니다.

```console
dfu-util -l
```

검증한 PCB는 다음 STM32 DFU interface를 정확히 표시했습니다.

```text
0483:df11 alt 0: @Internal Flash  /0x08000000/064*0002Kg
0483:df11 alt 1: @Option Bytes  /0x1FFFF800/01*016 e
```

Alt 0은 128 KiB main flash 전체를 2 KiB 크기의 erase/write 가능 page 64개로
표현합니다. Alt 1은 Option Bytes를 노출하므로 절대 선택하지 않습니다. USB
path와 serial은 특정 device instance를 식별하지만 재연결 후 path가 바뀔 수
있습니다. 포팅 당시의 값을 고정하지 말고 현재 `dfu-util -l` 결과에서 두 값을
가져옵니다.

접근할 수 없는 다른 VID/PID에 관한 메시지는 이 키보드를 식별하는 근거가
아닙니다. 하나의 명확한 `0483:df11` 대상이 두 예상 descriptor를 모두 표시할
때만 계속합니다. Memory map이 다르면 중단합니다.

### 3.2 Main flash 전체를 두 번 읽기

같은 fresh 목록의 path와 serial을 사용합니다. Alt 0만 upload하는 다음 명령은
장치를 지우거나 기록하지 않습니다.

```powershell
$dfuPath = "현재 dfu-util -l에 표시된 path"
$dfuSerial = "현재 dfu-util -l에 표시된 serial"

dfu-util -d ",0483:df11" -p $dfuPath -S $dfuSerial `
  -a 0 -s "0x08000000:0x20000" `
  -U ".\neo65cu-mainflash-readback-1.bin"

dfu-util -d ",0483:df11" -p $dfuPath -S $dfuSerial `
  -a 0 -s "0x08000000:0x20000" `
  -U ".\neo65cu-mainflash-readback-2.bin"

Get-Item .\neo65cu-mainflash-readback-*.bin | Select-Object Name, Length
Get-FileHash .\neo65cu-mainflash-readback-*.bin -Algorithm SHA256
```

두 upload는 모두 131,072 bytes였고 SHA-256이 다음 값으로 일치했습니다.

```text
EB3710B65CA65CD43B4EB58027EAB8E7CB843F8DB1DEFDC036ED738CF9093F8C
```

당시 설치 이미지는 제공된 stock VIA 파일이 아니라 Vial 포트였습니다. Readback에
`vial:f64c2b3c` 식별 문자열과 `0x0801E000` 부근의 작은 설정 record가 있으므로,
그 두 full readback이 ZMK 설치 직전 상태를 정확히 복구하는 자료입니다.

별도로 제공된 stock `neo65cu-wired.bin`도 다음과 같이 기록했습니다.

| 항목 | 값 |
| --- | --- |
| 크기 | 23,504 bytes (`0x5BD0`) |
| SHA-256 | `9DBB348E7533896B0728E5D3B84CF383D5C35E3E4AA519E94769770E5B369BB3` |
| Initial MSP | `0x20000400` |
| Reset Handler | `0x08000191` |

복구 파일은 의도적으로 Git에서 제외합니다. 외부 백업의 정확한 이름과 hash는
[`dev/recovery-files.sha256`](../dev/recovery-files.sha256)에 기록합니다.

## 4. 독립된 근거로 flash layout 결정하기

참고한 QMK/Vial 정의는 `STM32F072`와 `stm32-dfu`를 선언합니다. Stock BIN은 첫
byte부터 유효한 Cortex-M vector table이며 Reset Handler는 `0x08000000` 부근의
main flash를 가리킵니다. 현재 full-flash readback도 `0x08000000`에 같은 형태의
vector table을 갖습니다. 마지막으로 ROM DFU는 보호된 앞부분 없이 main flash
전체를 alt 0으로 노출합니다.

이 근거를 함께 확인해 다음 layout을 결정했습니다.

| 영역 | 주소 범위 | 크기 | 취급 |
| --- | --- | ---: | --- |
| ZMK/main 애플리케이션 flash | `0x08000000`-`0x0801FFFF` | 128 KiB | Link 및 기록 대상 |
| STM32 system-memory ROM | `0x1FFFC800`-`0x1FFFF7FF` | 12 KiB | 변경 불가능한 공장 부트로더 |
| Option Bytes | `0x1FFFF800`부터 | DFU가 노출한 16 bytes | 선택하거나 변경하지 않음 |

따라서 [`neo65cu.dts`](../boards/arm/neo65cu/neo65cu.dts)는 offset 0, 크기
`0x20000`의 단일 code partition을 정의합니다.

```dts
code_partition: partition@0 {
    label = "code";
    reg = <0x00000000 0x00020000>;
};
```

이 partition은 `0x08000000`에 있는 STM32 main-flash controller를 기준으로 한
상대 주소입니다. System ROM을 포함하거나 표현하지 않습니다. MCUboot partition,
software vector relay 또는 LINK65 형태의 handoff partition도 사용하지 않습니다.

### 4.1 파일 크기뿐 아니라 vector table을 확인한다

Raw application BIN은 다음 조건을 만족해야 합니다.

- STM32F072의 48-word vector table 전체를 포함할 만큼 충분히 커야 합니다.
- Initial MSP가 8-byte aligned이고 16 KiB SRAM 범위 안이어야 합니다.
- Reset Handler의 Thumb bit가 설정되어야 합니다.
- 0이 아닌 모든 handler가 정확한 BIN payload 안을 가리켜야 합니다.
- Payload 끝이 `0x08020000`을 넘지 않아야 합니다.

저장소의 기본 PowerShell 검사기를 사용할 수 있습니다.

```powershell
.\tools\inspect-firmware.ps1 .\neo65cu-zmk.bin
```

CI audit는 BIN을 ELF LOAD segment, symbol, linker map, 생성된 Kconfig와 생성된
devicetree까지 연결해 더 강하게 검사합니다.

## 5. Cortex-M0 ROM handoff의 양쪽 방향 처리

### 5.1 Cortex-M0에는 VTOR가 없다

Cortex-M3 이상과 달리 Cortex-M0는 Vector Table Offset Register를 써서 exception
vector를 옮길 수 없습니다. STM32F0는 대신 SYSCFG memory mapping register로
main flash, system ROM 또는 SRAM을 `0x00000000`에 alias합니다.

이 특성 때문에 두 가지 handoff 문제를 각각 해결해야 합니다.

- ROM 부트로더가 ZMK를 chain-load할 때 system ROM이 여전히 0번지에 매핑되어
  있을 수 있습니다.
- ZMK가 ROM DFU로 들어갈 때 ROM에서 interrupt를 활성화하기 전에 ROM vector를
  0번지에 매핑해야 합니다.

두 방향을 모두 구현하고 감사해야 합니다.

### 5.2 Zephyr 시작 전에 ROM이 남긴 상태 정리

ROM에서 애플리케이션으로 넘어올 때 SysTick, NVIC pending state, USB peripheral,
`CONTROL`과 현재 memory alias가 남을 수 있습니다. 전원을 완전히 끈 cold boot는
이미 main flash가 0번지에 매핑되므로 이 문제를 가릴 수 있습니다.

[`neo65cu_platform_init.c`](../src/neo65cu_platform_init.c)는 Zephyr pre-C hook인
`z_arm_platform_init()`을 제공합니다. `z_arm_reset`에서 직접 호출되어 다음 작업을
수행합니다.

1. Interrupt를 막고 SysTick, PendSV 및 PendST 상태를 지웁니다.
2. Memory remap 전에 SYSCFG APB clock을 활성화합니다.
3. RCC를 통해 USB peripheral을 reset합니다.
4. Zephyr의 early architecture initialization으로 돌아갑니다.

이후 `CONFIG_INIT_ARCH_HW_AT_BOOT=y`가 architecture/NVIC 상태를 정리하고,
Zephyr는 48-word 애플리케이션 vector table을 SRAM `0x20000000`에 복사한 뒤
SRAM을 0번지에 매핑합니다. `CONFIG_PLATFORM_SPECIFIC_INIT=y`가 그 remap 전에
SYSCFG clock이 준비되도록 보장합니다.

CI는 실제 링크 결과의 호출 순서를 검사합니다.

```text
z_arm_platform_init
  -> z_arm_init_arch_hw_at_boot
  -> z_arm_prep_c
```

이 경로의 모든 write는 volatile core, RCC, USB, GPIO 또는 SYSCFG register만
대상으로 합니다. Main flash, system ROM과 Option Bytes를 기록하지 않습니다.

### 5.3 Flash marker 없이 ROM DFU 진입

[`behavior_neo65cu_rom_dfu.c`](../src/behavior_neo65cu_rom_dfu.c)는 값과 그 반대값으로
구성된 8-byte `.noinit` SRAM marker를 사용합니다. 복구 요청은 marker를 쓰고
`NVIC_SystemReset()`을 호출합니다.

일반 clock driver보다 이른 `PRE_KERNEL_1` priority 0에서 다음 순서로 동작합니다.

1. Marker를 읽고 즉시 두 word를 모두 지웁니다.
2. `0x1FFFC800`의 system-ROM MSP와 Reset Handler가 alignment, SRAM 범위,
   Thumb 상태 및 ROM 범위를 만족하는지 확인합니다.
3. SysTick과 모든 NVIC enable/pending word를 지웁니다.
4. SYSCFG clock을 활성화하고 system ROM을 0번지에 매핑합니다.
5. 작은 assembly trampoline이 `CONTROL`을 복원하고 MSP를 교체한 뒤 interrupt를
   활성화해 ROM Reset Handler로 분기합니다.

Audit는 trampoline을 disassemble하여 `MSR MSP` 뒤에 load, store, push 또는 pop이
하나라도 있으면 실패시킵니다. ROM 진입 뒤 기존 stack으로 돌아올 수 없습니다.

같은 소스가 원본 펌웨어의 hold-Esc 복구 동작도 유지합니다. Zephyr GPIO, USB,
ZMK가 시작하기 전에 PA6을 잠시 low로 구동하고 PC14를 pull-up 입력으로 읽습니다.
Esc가 눌리지 않았다면 건드린 GPIO와 RCC register를 모두 복원합니다. 눌려 있다면
같은 SRAM-only marker 경로로 ROM DFU를 요청합니다.

실행 중 사용하는 four-corner combo는 다음과 같습니다.

```text
Esc + Delete + Left Ctrl + Right Arrow
```

멀리 떨어진 키 네 개와 150 ms timeout으로 우발 진입 가능성을 낮췄습니다. 이
combo는 flash를 erase하거나 program하지 않습니다.

## 6. USB clock과 pin 증명

STM32 USB Full-Speed에는 정확한 48 MHz source가 필요합니다. 이 PCB의
애플리케이션 clock에는 외부 crystal을 사용하지 않습니다. 검증한 경로는 다음과
같습니다.

```text
8 MHz HSI -> PLL prediv 1 -> PLL × 6 -> 48 MHz system/USB clock
```

Devicetree에는 다음과 같이 직접 표현했습니다.

```dts
&pll {
    prediv = <1>;
    mul = <6>;
    clocks = <&clk_hsi>;
    status = "okay";
};

&rcc {
    clocks = <&pll>;
    clock-frequency = <DT_FREQ_M(48)>;
    ahb-prescaler = <1>;
    apb1-prescaler = <1>;
};
```

USB D-와 D+는 PA11/PA12를 사용하고 controller는 bidirectional endpoint 4개로
활성화됩니다. HSE와 LSE는 disabled 상태입니다. PC14와 PC15가 matrix column이므로
LSE를 활성화하면 실제 키 입력과 충돌합니다. 선택한 Zephyr STM32F072 USB clock
경로가 PLL을 사용하므로 HSI48도 disabled 상태입니다.

Pre-C platform hook은 ROM direct chain-load를 처리하기 위해 USB peripheral을
명시적으로 reset합니다. USB가 인식되지 않으면 HID descriptor나 keymap을 바꾸기
전에 생성된 clock tree, oscillator 상태, PA11/PA12 pinctrl, endpoint 수와 ROM이
남긴 USB 상태를 확인합니다.

## 7. Matrix를 전기적 scanner로 재현하기

QMK `COL2ROW` scanner는 row를 low로 구동하고 pull-up된 active-low column을
읽습니다. ZMK에서는 같은 전기적 구성을 `row2col`이라고 부릅니다.

### 7.1 확인된 pin과 순서

| 구분 | 순서 |
| --- | --- |
| Row 출력 | PA6, PA7, PB0, PB1, PB9 |
| Column 입력 | PC14, PC15, PA0, PA1, PA2, PA3, PA4, PB2, PB10, PB11, PB12, PB13, PB14, PB15, PA8, PA9 |

Devicetree의 핵심 property는 다음과 같습니다.

```dts
diode-direction = "row2col";
col-gpios = <... (GPIO_ACTIVE_LOW | GPIO_PULL_UP)>;
row-gpios = <... GPIO_ACTIVE_LOW>;
```

여러 입력이 STM32 EXTI line 번호를 공유합니다. 예를 들어 PC14는 다른 port의
14번 pin과 같은 EXTI 번호를 사용합니다. Interrupt-driven scan으로 모든 입력을
독립적으로 표현할 수 없으므로 다음 설정을 강제했습니다.

```text
CONFIG_ZMK_KSCAN_MATRIX_POLLING=y
```

### 7.2 Timing과 debounce

QMK/ChibiOS 동작을 ZMK의 정수 delay로 다음과 같이 옮겼습니다.

```text
CONFIG_ZMK_KSCAN_MATRIX_WAIT_BEFORE_INPUTS=1
CONFIG_ZMK_KSCAN_MATRIX_WAIT_BETWEEN_OUTPUTS=30
```

첫 값은 column을 읽기 전 짧은 propagation delay이고, 두 번째는 이전 row를
해제하고 다음 row를 구동하기 전 30 µs 대기입니다. Press/release debounce는
각각 5 ms입니다.

Pin 순서, scan 방향, active level, pull과 timing을 하나의 계약으로 다뤄야 합니다.
Transform 오류는 보통 안정된 키 하나를 다른 위치로 옮기지만, 방향이나 settling
오류는 한 키가 인접 키까지 보고하거나 이전 row 상태가 남는 현상을 만들 수
있습니다.

### 7.3 모든 물리 option 보존

Transform에는 QMK `LAYOUT_wired`와 정확히 같은 70개 논리 entry가 있습니다.
Split Backspace, ISO Enter, split Left Shift와 alternative bottom row footprint도
포함합니다. 일부 위치는 서로 배타적이라 모든 조립 보드에 동시에 실장되지
않습니다. 그래도 transform에 유지하면 matrix 좌표를 임의로 만들지 않고 하나의
firmware로 PCB의 모든 지원 footprint를 표현할 수 있습니다.

Esc는 transform position 0이고 PA6/PC14 교차점입니다. 따라서 early recovery
scan의 GPIO가 정상 matrix 정의와 같은지 compile-time에 검사할 수 있습니다.

### 7.4 Caps Lock indicator

원본 정의는 PC13을 active-high Caps Lock LED로 식별합니다.
[`caps_lock_led.c`](../src/caps_lock_led.c)는 ZMK HID indicator event를 구독하고
host의 Caps Lock 상태에 따라 GPIO를 구동합니다. QMK macro나 회로 추정에만
의존하지 않고 Windows 실기기에서 확인했습니다.

## 8. Zephyr/ZMK module 구성

| 파일 | 역할 |
| --- | --- |
| [`neo65cu.dts`](../boards/arm/neo65cu/neo65cu.dts) | Memory, clock, USB, matrix, transform, LED 및 behavior node |
| [`neo65cu_defconfig`](../boards/arm/neo65cu/neo65cu_defconfig) | SoC, USB, polling, timing, stack 및 early-init 설정 |
| [`Kconfig.board`](../boards/arm/neo65cu/Kconfig.board) | Board 선택과 STM32F072 의존성 |
| [`Kconfig.defconfig`](../boards/arm/neo65cu/Kconfig.defconfig) | ZMK board 이름과 기본값 |
| [`neo65cu.keymap`](../boards/arm/neo65cu/neo65cu.keymap) | Base/Fn 레이어 및 reset/ROM-DFU combo |
| [`neo65cu.zmk.yml`](../boards/arm/neo65cu/neo65cu.zmk.yml) | ZMK board metadata |
| [`behavior binding`](../dts/bindings/behaviors/zmk,behavior-neo65cu-rom-dfu.yaml) | ROM DFU behavior의 devicetree schema |
| [`behavior_neo65cu_rom_dfu.c`](../src/behavior_neo65cu_rom_dfu.c) | Early Esc scan, SRAM marker 및 ROM handoff |
| [`neo65cu_platform_init.c`](../src/neo65cu_platform_init.c) | Pre-C inherited-state 정리 |
| [`caps_lock_led.c`](../src/caps_lock_led.c) | Host LED indicator listener |
| [`zephyr/CMakeLists.txt`](../zephyr/CMakeLists.txt) | Board 전용 source 등록 |
| [`zephyr/module.yml`](../zephyr/module.yml) | Board와 DTS module root |
| [`build.yaml`](../build.yaml) | ZMK build matrix |
| [`config/west.yml`](../config/west.yml) | 정확히 고정한 ZMK revision |
| [`audit-firmware.py`](../tools/audit-firmware.py) | BIN/ELF/map/config/DTS fail-closed audit |

프로젝트는 ZMK `v0.3.0`에 해당하는 정확한 commit에 고정되어 있습니다.

```text
edf5c0814fd3ea202e43aad2d68fd32e882a518c
```

Settings/storage partition은 없습니다. `FLASH`, settings, NVS, filesystem,
stream-flash, watchdog, Bluetooth, MCUboot, software vector relay와 ZMK Studio를
비활성화했습니다. RAM/flash 사용량을 줄이는 동시에 초기 bring-up 중 일반 ZMK
기능이 persistent data를 기록하지 못하게 하기 위함입니다.

## 9. 독립적으로 감사 가능한 이미지 빌드

기본 [Build and Release workflow](https://github.com/thsrhwk01/zmk-neo_neo65cu/actions/workflows/build.yml)는
같은 고정 ZMK commit으로 두 번 빌드합니다.

1. 표준 ZMK user-config reusable workflow가 배포용 `firmware` artifact를 만듭니다.
2. 별도 west workspace가 `zmk.bin`, `zmk.elf`, `zmk.map`, `zephyr.config`, 생성된
   `zephyr.dts`, symbol과 disassembly를 만듭니다.
3. [`audit-firmware.py`](../tools/audit-firmware.py)가 독립 build를 검사합니다.
4. 다음 job이 표준 workflow BIN과 독립적으로 감사한 BIN의 byte-for-byte
   동일성을 증명합니다.

Audit는 다음 변경을 모두 거부합니다.

- 48-word vector table, 필수 core vector 및 USB IRQ 31
- Main flash/SRAM 경계와 모든 file-backed ELF LOAD segment
- Zero flash offset, 정확한 BIN payload, main stack/MSP, SRAM vector 위치 및
  최소 4 KiB RAM 여유
- Pre-C platform, architecture, C startup 호출 순서
- SoC, early recovery, clock initialization 순서
- ROM vector 범위, 8-byte SRAM marker와 stack access 없는 jump tail
- HSI × 6 PLL, 48 MHz USB clock, PA11/PA12, oscillator 상태와 endpoint
- 정확한 70-position transform, GPIO 순서/flag, polling, LED 및 recovery combo
- Storage/settings/Studio/watchdog 비활성화와 linked persistent-write symbol 부재

### 9.1 Bring-up 중 audit harness 실패

Firmware build는 audit harness보다 먼저 성공했습니다. 다음 failed run은 실제
보드에 기록한 이미지 실패가 아니라 강화하던 검사 코드의 false positive였습니다.

| Run | 실패 내용 | 수정 |
| --- | --- | --- |
| `31319558952` | Map parser가 section이 한 줄에 있다고 가정 | 실제 줄바꿈 linker-map 형식을 parsing |
| `31319948476` | Container ARM binutils 경로를 추정 | `CMakeCache.txt`에서 정확한 tool path 확인 |
| `31321068519` | `__rom_region_end`를 flash 전체 끝으로 해석 | Linked ROM payload 끝으로 해석 |
| `31321291929` | Reset symbol alias 때문에 제한 disassembly가 비어 있음 | 실제 linked reset 주소 범위를 disassemble |
| `31321651375` | 최종 독립 audit 및 exact BIN 비교 | 통과 |

이 CI 반복 중에는 device erase, download 또는 Option Bytes 동작을 실행하지
않았습니다. `359CA48E...`, `98FE8504...` 같은 hash의 candidate BIN은 승인하지
않고 폐기했습니다.

### 9.2 실기기 승인 release gate

[`release/neo65cu-zmk.sha256`](../release/neo65cu-zmk.sha256)은 편의를 위한 checksum이
아닙니다. 새 build가 하나의 실기기 승인 raw BIN hash와 정확히 같지 않으면 package
job이 실패합니다. 소스나 keymap 변경이 정적 audit를 통과해도 자동으로 Release가
되어서는 안 됩니다.

Manifest를 갱신하려면 새 pre-flash backup, 즉시 readback, cold boot, 장착된 모든
키/Fn/LED 검사, 애플리케이션 재시작과 세 ROM DFU 복구 검사를 반복해야 합니다.

## 10. 첫 플래시와 실기기 acceptance test

### 10.1 애플리케이션과 독립된 하드웨어 복구 접점 증명

QMK 자료는 PCB 하단의 `SW1`을 언급하지만 촬영한 PCB에는 버튼이 실장되어 있지
않았습니다. MCU 부근에 `SW?` 실크가 있는 2-pin through-hole footprint가
있습니다. 키보드가 이미 실행 중일 때 두 pad를 쇼트해도 USB와 입력에 변화가
없었습니다. 반면 쇼트를 유지한 채 USB 전원을 인가하면 `0483:df11` ROM DFU에
진입했습니다.

따라서 이 footprint가 power-on boot-selection 접점으로 동작함은 확인했지만,
schematic이나 continuity 측정이 없으므로 정확한 net 이름은 단정하지 않습니다.
다른 pad를 탐침하거나 쇼트하지 마십시오. Main PCB가 자석식 pogo pin으로 케이스에
고정된 daughterboard와 연결되므로 이 접점은 일상적인 복구 방법으로 적합하지
않습니다. 일반적으로 hold-Esc를 사용합니다.

### 10.2 검증된 main-flash 이미지만 기록

다음은 첫 검증 이미지에 실제로 사용한 순서입니다. 2절과 3절의 확인을 생략해도
된다는 뜻이 아니라 재현 가능한 감사 기록으로 제시합니다. Fresh 목록에서 path와
serial을 가져오고 두 descriptor를 확인한 뒤 128 KiB 백업을 먼저 완료해야 합니다.

```powershell
$dfuPath = "현재 dfu-util -l에 표시된 path"
$dfuSerial = "현재 dfu-util -l에 표시된 serial"

Get-FileHash .\neo65cu-zmk.bin -Algorithm SHA256

dfu-util -d ",0483:df11" -p $dfuPath -S $dfuSerial `
  -a 0 -s "0x08000000" `
  -D ".\neo65cu-zmk.bin"

dfu-util -d ",0483:df11" -p $dfuPath -S $dfuSerial `
  -a 0 -s "0x08000000:0x979C" `
  -U ".\neo65cu-zmk-first-flash-readback.bin"

(Get-FileHash .\neo65cu-zmk.bin).Hash -eq `
  (Get-FileHash .\neo65cu-zmk-first-flash-readback.bin).Hash
```

Download 명령은 alt 0과 `0x08000000`만 선택했습니다. Alt 1, mass erase와
`:leave`를 사용하지 않았습니다. USB를 분리하기 전 마지막 비교가 `True`를
반환했습니다.

### 10.3 단계별 acceptance 결과

복구 우선 순서로 다음 검사를 진행했습니다.

1. 재부팅 전에 exact readback hash와 유효한 vector를 확인했습니다.
2. USB를 분리했다가 연결해 HID enumeration을 확인했습니다.
3. 아무 키 없이 cold boot를 세 번 반복했고 3/3회 성공했습니다.
4. 장착된 모든 키를 하나씩 눌러 정확히 하나의 press/release인지 확인했습니다.
5. `Fn + Esc`, `Fn + 1`부터 `Fn + =`까지 Grave/F1-F12를 확인했습니다.
6. Caps Lock을 전환해 PC13 LED가 host 상태를 따르는지 확인했습니다.
7. `Backspace + Left Ctrl + Left Alt`로 애플리케이션 재시작을 확인했습니다.
8. Cold plug 중 Esc를 눌러 `0483:df11` ROM DFU를 다시 확인했습니다.
9. ZMK에서 four-corner combo로 ROM DFU를 다시 확인했습니다.
10. 전원 인가 시 뒷면 `SW?` 접점으로 ROM DFU를 다시 확인했습니다.

정상 보드에 불필요한 erase/write cycle을 추가하지 않기 위해 official/Vial 복구
drill은 실행하지 않았습니다. 대신 두 full readback, stock BIN, dfu-util 환경,
정확한 hash와 복구 명령을 외부에 보관했습니다.

### 10.4 배포 플래셔의 보호 장치

Windows package는 같은 보수적인 순서를 자동화합니다. 기록 전에 release hash와
vector를 확인하고 명시적인 하드웨어 확인을 요구합니다. 검증된 alt 0/alt 1
descriptor를 가진 대상이 정확히 하나인지 확인한 뒤 fresh path/serial을 고정하고
128 KiB 전체를 upload합니다. 이후 alt 0의 `0x08000000`만 기록하고 같은 길이의
readback을 검증합니다.

Script에는 alt 1 download, Option Bytes 기록, mass erase와 자동 `:leave` 경로가
없습니다. 후속 단계가 실패해도 백업은 보존합니다.

## 11. 증상별 진단

| 증상 | 우선 확인할 항목 |
| --- | --- |
| 기록 후 ROM DFU에 계속 남음 | Esc가 눌린 상태인지, BIN hash, vector table, initial MSP, Reset Handler와 `0x08000000` link 주소 |
| DFU를 나온 뒤 USB HID가 전혀 나타나지 않음 | HSI × 6 PLL, PA11/PA12 pinctrl, USB peripheral reset, SRAM vector remap과 inherited interrupt 상태 |
| Cold boot는 되지만 ROM-to-app handoff만 실패 | SYSCFG clock timing, platform pre-C hook, `CONFIG_INIT_ARCH_HW_AT_BOOT` 및 SRAM vector table |
| 한 키가 인접 키도 함께 입력 | Row/column 방향, active-low flag, pull-up, pin 순서와 1/30 µs scan delay |
| 일부 column 묶음이 동작하지 않음 | Polling mode, 공유 EXTI 번호, 실제 GPIO 순서와 미실장 optional footprint |
| Caps Lock 입력은 되지만 LED가 바뀌지 않음 | PC13 극성, HID indicator 지원, event listener 초기화와 host LED 상태 |
| 실행 중 `SW?` 쇼트가 아무 동작도 하지 않음 | 확인된 정상 동작이며, 이 접점은 power-on에서만 반응했음 |
| Hold-Esc로 DFU에 들어가지 않음 | PA6/PC14 교차점, cold-plug timing, data cable 및 다른 키가 row/column을 전기적으로 누르고 있는지 |
| Four-corner combo 뒤 재시작하지만 DFU가 나타나지 않음 | SRAM marker/link 위치, ROM vector 검사, SYSCFG remap과 jump-trampoline disassembly |
| DFU descriptor가 문서의 map과 다름 | 즉시 중단하고 같은 PCB revision이라고 가정하지 않음 |
| 관련 없는 장치나 접근 불가 DFU만 표시 | Cable/driver/port를 다시 확인하고 `0483:df11`을 식별하며 불확실한 대상에는 동작하지 않음 |

Windows 연결음, LED 상태 또는 오류 메시지 하나만으로 원인을 결정하지 마십시오.
현재 descriptor, raw BIN hash, vector, 생성된 clock tree와 readback을 함께
비교합니다.

## 12. 포팅 재현 또는 다른 보드 적용 체크리스트

### 첫 빌드 전

- [ ] 정확한 MCU marking, package, flash와 SRAM 크기를 확인했다.
- [ ] 신뢰할 수 있는 matrix pin, 순서, scan 방향, 극성, pull과 timing을 확보했다.
- [ ] USB D-/D+를 식별하고 48 MHz clock path를 독립적으로 계산했다.
- [ ] 부트로더가 flash-resident인지 system ROM인지 확인했다.
- [ ] 쓰기 대상을 선택하지 않고 모든 DFU alternate setting을 기록했다.
- [ ] Main flash를 두 번 읽어 같은 hash를 외부에 보관했다.
- [ ] 정상 공식 이미지와 정확한 복구 환경을 보존했다.
- [ ] 다른 보드 offset을 복사하지 않고 vector, reference firmware와 DFU layout으로
      애플리케이션 시작 주소를 확인했다.
- [ ] Cortex-M0 vector remap과 양방향 handoff를 처리했다.
- [ ] Settings, storage, Studio, Bluetooth 및 무관한 기능 없이 시작했다.

### 플래시 전

- [ ] 모든 file-backed ELF LOAD가 main flash 안에만 있는지 확인했다.
- [ ] `0x08000000`의 vector table, 유효한 SRAM MSP와 정확한 BIN payload 안의
      Thumb Reset Handler를 확인했다.
- [ ] 48-word SRAM vector table과 early-init 호출 순서를 확인했다.
- [ ] `MSR MSP` 뒤 ROM jump tail에 stack/memory access가 없는지 확인했다.
- [ ] Persistent flash-write symbol이 링크되지 않았는지 확인했다.
- [ ] 표준 ZMK BIN과 독립 감사 BIN을 비교했다.
- [ ] Raw BIN을 실기기 승인 SHA-256과 비교했다.
- [ ] DFU를 다시 조회하고 현재 path/serial을 기록했다.
- [ ] 131,072-byte pre-flash backup을 완료하고 검증했다.
- [ ] Alt 0의 `0x08000000`만 선택하고 alt 1과 mass erase를 사용하지 않는다.

### 플래시 후

- [ ] 재부팅 전에 BIN의 정확한 길이만큼 upload하고 hash를 비교했다.
- [ ] USB HID enumeration과 세 번의 cold boot를 확인했다.
- [ ] 장착된 모든 키와 전체 Fn 레이어를 단독 입력으로 검사했다.
- [ ] Caps Lock LED 동작을 확인했다.
- [ ] 애플리케이션 재시작과 ROM DFU 진입을 별도로 확인했다.
- [ ] Hold-Esc, runtime combo와 hardware power-on ROM DFU 경로를 다시 검사했다.
- [ ] Source commit, Actions run, raw BIN hash, readback hash, 날짜와 미실장 위치를
      기록했다.
- [ ] 복구 이미지를 공개 source 저장소 밖에 보관했다.

목표는 첫 이미지에 모든 기능을 넣는 것이 아닙니다. 각 실험 뒤에도
애플리케이션과 독립적인 복구 경로를 유지하면서 하드웨어 계약을 하나씩 증명하는
것입니다.

## 참고 자료

- [Neo65 CU QMK/Vial 참고 tree](https://github.com/lizhenmingdirk/qmk_firmware/tree/master/keyboards/neo/neo65cu)
- [Qwertykeys Neo65/60 Cu build guide](https://qwertykeys.notion.site/Neo65-60-Cu-Build-Guide-1863d090094280babee7ce4ff3901aa8)
- [STM32F072x8/xB datasheet](https://www.st.com/resource/en/datasheet/stm32f072cb.pdf)
- [STM32F0x1/F0x2/F0x8 reference manual RM0091](https://www.st.com/resource/en/reference_manual/rm0091-stm32f0x1stm32f0x2stm32f0x8-advanced-armbased-32bit-mcus-stmicroelectronics.pdf)
- [STM32 system-memory boot mode application note AN2606](https://www.st.com/resource/en/application_note/an2606-stm32-microcontroller-system-memory-boot-mode-stmicroelectronics.pdf)
- [ZMK 문서](https://zmk.dev/docs/)
