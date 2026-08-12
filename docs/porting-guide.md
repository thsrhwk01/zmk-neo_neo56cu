# Porting ZMK to the Neo65 CU Wired PCB While Preserving STM32 ROM DFU

[한국어](porting-guide_ko.md)

This document records the evidence, design decisions, failed checks, and
hardware-validation sequence used to port ZMK to the `STM32F072CBT6` on the
Qwertykeys/NEO Studio Neo65 CU wired PCB. The work was performed without an
SWD/J-Link debugger, so retaining a proven USB DFU recovery path was the first
requirement rather than a final convenience.

This is not a set of values to copy to another Neo or STM32 keyboard. Its goal
is to show how each hardware contract was established independently:

- Whether the bootloader lives in writable main flash or immutable system ROM
- Where the application vector table and ELF load segments must begin
- How a Cortex-M0 application and ROM bootloader exchange control without VTOR
- Which clock path supplies the required 48 MHz to USB
- Matrix pin order, scan direction, polarity, timing, and optional positions
- How a built BIN was inspected and then tied to a physical readback

> [!WARNING]
> Every address, USB ID, GPIO, and recovery gesture below was verified for the
> **Neo65 CU wired PCB with an STM32F072CBT6**. Do not use this firmware or its
> commands on a tri-mode PCB, the original Neo65, Neo65 Core Plus, Neo65 Sonic
> HE+, LINK65, or an unidentified revision. Never select DFU alt 1, change
> option bytes, or use mass erase.

## 1. Verified Neo65 CU baseline

| Item | Value |
| --- | --- |
| PCB | Qwertykeys/NEO Studio Neo65 CU wired PCB |
| MCU marking | STMicroelectronics `STM32F072CBT6` |
| CPU | Cortex-M0, 48 MHz |
| Clock source | Internal 8 MHz HSI, PLL × 6 |
| Main flash | 128 KiB, `0x08000000`-`0x0801FFFF` |
| SRAM | 16 KiB, `0x20000000`-`0x20003FFF` |
| USB | PA11/PA12, Full-Speed at 48 MHz |
| Factory DFU USB ID | `0483:df11` |
| Application start | `0x08000000` |
| Factory bootloader | STM32 system ROM at `0x1FFFC800` |
| Matrix | 5 rows × 16 columns, 70 logical `LAYOUT_wired` positions |
| Caps Lock LED | PC13, active-high |

The following raw image was verified on physical hardware:

| Item | Value |
| --- | --- |
| Source | [`2a36f566`](https://github.com/thsrhwk01/zmk-neo_neo65cu/commit/2a36f566802fbc65287ddc931ae285326bfa16f5) |
| Build | [GitHub Actions run `31321651375`](https://github.com/thsrhwk01/zmk-neo_neo65cu/actions/runs/31321651375) |
| File | `neo65cu-zmk.bin` |
| Size | 38,812 bytes (`0x979C`) |
| SHA-256 | `63669C31092A134764A3B9BB48FF251312EAFF1B73EDF787DABD2427C6BBF74A` |
| Initial MSP | `0x20001E18` |
| Reset Handler | `0x080024B5` |
| Nonzero handler vectors | 38 |

The BIN was written once, uploaded again before reboot, and compared
byte-for-byte. All installed switches, the Fn layer, Caps Lock LED, three cold
boots, application reset, and three independent ROM DFU entry paths passed.
Unpopulated ISO/split optional footprints remain untested.

## 2. Safety rules when ROM DFU is the only recovery path

The STM32F072 factory bootloader is mask ROM, not a flash-resident bootloader.
A normal alt-0 main-flash write cannot overwrite that ROM. This is useful, but
it does not make arbitrary DFU operations safe: option-byte changes can affect
boot selection and protection, and an image linked for the wrong address can
still leave the keyboard unable to run an application.

The port used these invariants:

1. Confirm the exact PCB and MCU marking before selecting a build.
2. Prove at least one application-independent ROM DFU entry method first.
3. Record a fresh DFU descriptor, USB path, and serial for every session.
4. Read all 128 KiB of current main flash twice and compare the hashes.
5. Keep the official BIN and full readbacks in an external recovery backup.
6. Link and write the application only at main flash `0x08000000`.
7. Never select alt 1, write option bytes, use mass erase, or write system
   memory.
8. Upload the exact written length before reboot and compare it with the BIN.
9. Reconfirm ROM DFU entry after the first successful ZMK boot.
10. Do not approve a new release hash until the entire hardware test is
    repeated.

Do not copy LINK65 values into this port. LINK65 uses a protected flash
bootloader, application offset `0x08006000`, and USB ID `1688:2220`; none of
those values apply to the Neo65 CU.

## 3. Establish backups and recovery before building

### 3.1 Identify the real DFU device

With the original working firmware installed, disconnect USB, hold `Esc`, and
reconnect the cable. Then list devices:

```console
dfu-util -l
```

The tested PCB reported exactly these STM32 DFU interfaces:

```text
0483:df11 alt 0: @Internal Flash  /0x08000000/064*0002Kg
0483:df11 alt 1: @Option Bytes  /0x1FFFF800/01*016 e
```

Alt 0 describes the full 128 KiB main flash as 64 erasable/writable 2 KiB
pages. Alt 1 exposes option bytes and is never selected. The USB path and
serial identify a particular device instance, but the path can change after a
reconnect. Capture both from the current `dfu-util -l` output rather than
hardcoding the values observed during this port.

Messages about another inaccessible VID/PID do not identify the keyboard.
Continue only when one unambiguous `0483:df11` target exposes both expected
descriptors. If the memory map differs, stop.

### 3.2 Read all main flash twice

Use the path and serial from the same fresh listing. Upload only alt 0; these
commands do not erase or write the device.

```powershell
$dfuPath = "path from the current dfu-util -l"
$dfuSerial = "serial from the current dfu-util -l"

dfu-util -d ",0483:df11" -p $dfuPath -S $dfuSerial `
  -a 0 -s "0x08000000:0x20000" `
  -U ".\neo65cu-mainflash-readback-1.bin"

dfu-util -d ",0483:df11" -p $dfuPath -S $dfuSerial `
  -a 0 -s "0x08000000:0x20000" `
  -U ".\neo65cu-mainflash-readback-2.bin"

Get-Item .\neo65cu-mainflash-readback-*.bin | Select-Object Name, Length
Get-FileHash .\neo65cu-mainflash-readback-*.bin -Algorithm SHA256
```

Both uploads were 131,072 bytes and had this SHA-256:

```text
EB3710B65CA65CD43B4EB58027EAB8E7CB843F8DB1DEFDC036ED738CF9093F8C
```

The installed image at the time was a Vial port, not the supplied stock VIA
file. The readback contains a `vial:f64c2b3c` identifier and a small settings
record near `0x0801E000`, so the full readback is the appropriate recovery
artifact for that exact pre-ZMK state.

The separately supplied stock `neo65cu-wired.bin` was also recorded:

| Item | Value |
| --- | --- |
| Size | 23,504 bytes (`0x5BD0`) |
| SHA-256 | `9DBB348E7533896B0728E5D3B84CF383D5C35E3E4AA519E94769770E5B369BB3` |
| Initial MSP | `0x20000400` |
| Reset Handler | `0x08000191` |

Recovery files are intentionally excluded from Git. Their exact external
backup names and hashes are recorded in
[`dev/recovery-files.sha256`](../dev/recovery-files.sha256).

## 4. Determine the flash layout from independent evidence

The reference QMK/Vial definition declares `STM32F072` with `stm32-dfu`. The
stock BIN begins immediately with a valid Cortex-M vector table, and its Reset
Handler points into main flash near `0x08000000`. The current full-flash
readback has the same vector-table pattern at `0x08000000`. Finally, ROM DFU
exposes the entire main flash as alt 0 rather than reserving a protected prefix.

Together these facts establish this layout:

| Region | Address range | Size | Treatment |
| --- | --- | ---: | --- |
| ZMK/main application flash | `0x08000000`-`0x0801FFFF` | 128 KiB | Link and write target |
| STM32 system-memory ROM | `0x1FFFC800`-`0x1FFFF7FF` | 12 KiB | Immutable factory bootloader |
| Option bytes | starts at `0x1FFFF800` | 16 bytes exposed by DFU | Never select or modify |

[`neo65cu.dts`](../boards/arm/neo65cu/neo65cu.dts) therefore defines one code
partition at offset 0 with size `0x20000`:

```dts
code_partition: partition@0 {
    label = "code";
    reg = <0x00000000 0x00020000>;
};
```

This partition is relative to the STM32 main-flash controller at
`0x08000000`. It does not include or describe system ROM. No MCUboot partition,
software vector relay, or LINK65-style handoff partition is used.

### 4.1 Validate the vector table, not just the file size

For a raw application BIN:

- The file must contain at least the complete 48-word STM32F072 vector table.
- The initial MSP must be 8-byte aligned and within 16 KiB SRAM.
- The Reset Handler must have its Thumb bit set.
- Every nonzero handler must point inside the exact BIN payload.
- The payload must end at or below `0x08020000`.

The repository provides a basic PowerShell inspector:

```powershell
.\tools\inspect-firmware.ps1 .\neo65cu-zmk.bin
```

During initial bring-up, the BIN was also compared with ELF load segments,
symbols, the linker map, generated Kconfig, and generated devicetree. The active
release workflow now retains the lightweight raw-BIN checks above.

## 5. Handle both sides of the Cortex-M0 ROM handoff

### 5.1 Cortex-M0 has no VTOR

Unlike Cortex-M3 and later cores, Cortex-M0 cannot redirect exceptions by
writing a Vector Table Offset Register. STM32F0 instead uses the SYSCFG memory
mapping register to alias main flash, system ROM, or SRAM at `0x00000000`.

This creates two separate handoff problems:

- When the ROM bootloader chain-loads ZMK, system ROM may still be mapped at
  address zero.
- When ZMK enters ROM DFU, the ROM vector table must be mapped at zero before
  interrupts are enabled there.

Both directions must be implemented and verified.

### 5.2 Clean inherited ROM state before Zephyr starts

A ROM-to-application handoff may preserve SysTick, NVIC pending state, USB
peripheral state, `CONTROL`, and the current memory alias. A cold power-on can
hide this problem because main flash is already mapped at zero.

[`neo65cu_platform_init.c`](../src/neo65cu_platform_init.c) supplies Zephyr's
pre-C `z_arm_platform_init()` hook. It runs directly from `z_arm_reset` and:

1. Disables interrupts and clears SysTick, PendSV, and PendST state.
2. Enables the SYSCFG APB clock before any memory remap is attempted.
3. Resets the USB peripheral through RCC.
4. Returns to Zephyr's early architecture initialization.

`CONFIG_INIT_ARCH_HW_AT_BOOT=y` then clears architectural/NVIC state, and
Zephyr copies the 48-word application vector table to SRAM `0x20000000` before
mapping SRAM at zero. `CONFIG_PLATFORM_SPECIFIC_INIT=y` ensures the SYSCFG
clock is ready before that remap.

The linked call order was verified during initial bring-up:

```text
z_arm_platform_init
  -> z_arm_init_arch_hw_at_boot
  -> z_arm_prep_c
```

All writes in this path affect volatile core, RCC, USB, GPIO, or SYSCFG
registers. They do not write main flash, system ROM, or option bytes.

### 5.3 Enter ROM DFU without a flash marker

[`behavior_neo65cu_rom_dfu.c`](../src/behavior_neo65cu_rom_dfu.c) uses an
8-byte `.noinit` SRAM marker containing a value and its inverse. A recovery
request writes the marker and calls `NVIC_SystemReset()`.

At `PRE_KERNEL_1` priority 0, before the normal clock driver:

1. The marker is read and immediately cleared.
2. The system-ROM MSP and Reset Handler at `0x1FFFC800` are checked for
   alignment, SRAM range, Thumb state, and ROM range.
3. SysTick and every NVIC enable/pending word are cleared.
4. The SYSCFG clock is enabled and system ROM is mapped at zero.
5. A small assembly trampoline restores `CONTROL`, replaces MSP, enables
   interrupts, and branches to the ROM Reset Handler.

During bring-up, the linked trampoline was disassembled to confirm there is no
load, store, push, or pop after `MSR MSP`. The ROM entry cannot return to the old
stack.

The same source preserves the vendor's hold-Esc recovery gesture. Before
Zephyr GPIO, USB, or ZMK starts, it temporarily drives PA6 low and reads PC14
with a pull-up. If Esc is not held, every touched GPIO and RCC register is
restored. If it is held, the code requests ROM DFU through the same SRAM-only
marker path.

The runtime ROM-DFU binding is:

```text
Fn + Delete
```

The original four-corner combo was removed because its timeout delayed normal
Esc, Delete, Ctrl, and arrow-key input. A dedicated Fn-layer binding invokes the
same SRAM-only handoff and does not erase or program flash. `Fn + Backspace`
similarly invokes `&sys_reset` without making Backspace, Ctrl, or Alt combo keys.

## 6. Prove the USB clock and pins

STM32 USB Full-Speed requires an accurate 48 MHz source. This PCB does not use
an external crystal for the application clock. The verified path is:

```text
8 MHz HSI -> PLL prediv 1 -> PLL × 6 -> 48 MHz system/USB clock
```

The devicetree expresses it directly:

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

USB D- and D+ use PA11 and PA12. The controller is enabled with four
bidirectional endpoints. HSE and LSE remain disabled; PC14 and PC15 are matrix
columns, so enabling LSE would conflict with actual key inputs. HSI48 also
remains disabled because the selected Zephyr STM32F072 USB clock path uses the
PLL.

The pre-C platform hook explicitly resets the USB peripheral to handle a
direct ROM chain-load. When USB does not enumerate, verify the generated clock
tree, oscillator states, PA11/PA12 pinctrl, endpoint count, and inherited USB
state before changing HID descriptors or the keymap.

## 7. Reproduce the matrix as an electrical scanner

The QMK `COL2ROW` scanner drives rows low and reads pulled-up, active-low
columns. In ZMK, that electrical arrangement is named `row2col`.

### 7.1 Verified pins and order

| Group | Order |
| --- | --- |
| Row outputs | PA6, PA7, PB0, PB1, PB9 |
| Column inputs | PC14, PC15, PA0, PA1, PA2, PA3, PA4, PB2, PB10, PB11, PB12, PB13, PB14, PB15, PA8, PA9 |

The essential devicetree properties are:

```dts
diode-direction = "row2col";
col-gpios = <... (GPIO_ACTIVE_LOW | GPIO_PULL_UP)>;
row-gpios = <... GPIO_ACTIVE_LOW>;
```

Several inputs share STM32 EXTI line numbers, for example PC14 with another
port's pin 14. Interrupt-driven scanning cannot represent every input
independently, so the port requires:

```text
CONFIG_ZMK_KSCAN_MATRIX_POLLING=y
```

### 7.2 Timing and debounce

The QMK/ChibiOS behavior was carried over as integer ZMK delays:

```text
CONFIG_ZMK_KSCAN_MATRIX_WAIT_BEFORE_INPUTS=1
CONFIG_ZMK_KSCAN_MATRIX_WAIT_BETWEEN_OUTPUTS=30
```

The first value provides a short propagation delay before reading columns; the
second waits 30 µs after releasing one row before driving the next. Press and
release debounce are both 5 ms.

Treat pin order, scan direction, active level, pulls, and timing as one
contract. A transform error usually moves a stable key; a direction or settling
error can make one press report an adjacent key or leave a previous row state
visible.

### 7.3 Preserve all physical options

The transform contains the exact 70 logical entries from QMK `LAYOUT_wired`,
including split Backspace, ISO Enter, split Left Shift, and alternative bottom
row footprints. Some positions are mutually exclusive and are not populated
on every assembled board. Keeping them in the transform allows one firmware to
represent every supported PCB footprint without inventing matrix coordinates.

Esc is transform position 0 and physically intersects PA6/PC14, which is why
the early recovery scan can be compile-time checked against the normal matrix.

### 7.4 Caps Lock indicator

The stock definition identifies PC13 as an active-high Caps Lock LED.
[`caps_lock_led.c`](../src/caps_lock_led.c) subscribes to ZMK HID indicator
events and drives the GPIO from the host's Caps Lock state. This was tested on
Windows rather than inferred only from a schematic or QMK macro.

## 8. Zephyr/ZMK module structure

| File | Purpose |
| --- | --- |
| [`neo65cu.dts`](../boards/arm/neo65cu/neo65cu.dts) | Memory, clock, USB, matrix, transform, LED, and behavior node |
| [`neo65cu_defconfig`](../boards/arm/neo65cu/neo65cu_defconfig) | SoC, USB, polling, timing, stacks, and early-init settings |
| [`Kconfig.board`](../boards/arm/neo65cu/Kconfig.board) | Board selection and STM32F072 dependency |
| [`Kconfig.defconfig`](../boards/arm/neo65cu/Kconfig.defconfig) | ZMK board name and defaults |
| [`neo65cu.keymap`](../boards/arm/neo65cu/neo65cu.keymap) | Base/Fn layers and reset/ROM-DFU bindings |
| [`neo65cu.zmk.yml`](../boards/arm/neo65cu/neo65cu.zmk.yml) | ZMK board metadata |
| [`behavior binding`](../dts/bindings/behaviors/zmk,behavior-neo65cu-rom-dfu.yaml) | Devicetree schema for the ROM DFU behavior |
| [`behavior_neo65cu_rom_dfu.c`](../src/behavior_neo65cu_rom_dfu.c) | Early Esc scan, SRAM marker, and ROM handoff |
| [`neo65cu_platform_init.c`](../src/neo65cu_platform_init.c) | Pre-C inherited-state cleanup |
| [`caps_lock_led.c`](../src/caps_lock_led.c) | Host LED indicator listener |
| [`zephyr/CMakeLists.txt`](../zephyr/CMakeLists.txt) | Registration of board-specific sources |
| [`zephyr/module.yml`](../zephyr/module.yml) | Board and DTS module roots |
| [`build.yaml`](../build.yaml) | ZMK build matrix |
| [`config/west.yml`](../config/west.yml) | Exact pinned ZMK revision |
| [`inspect-firmware.ps1`](../tools/inspect-firmware.ps1) | Lightweight raw-BIN vector and address validation |

The project is pinned to the exact commit behind ZMK `v0.3.0`:

```text
edf5c0814fd3ea202e43aad2d68fd32e882a518c
```

There is no settings or storage partition. `FLASH`, settings, NVS, filesystem,
stream-flash, watchdog, Bluetooth, MCUboot, software vector relay, and ZMK
Studio are disabled. This reduces RAM/flash pressure and prevents a normal ZMK
feature from writing persistent data during initial bring-up.

## 9. Build and validate the release image

The main [Build and Release workflow](../.github/workflows/build.yml) uses the
standard reusable ZMK user-config build against the pinned ZMK commit:

1. The standard workflow produces the distributable `firmware` artifact.
2. [`inspect-firmware.ps1`](../tools/inspect-firmware.ps1) checks the BIN size,
   MSP, Reset Handler, required vectors, and every nonzero handler address.
3. The package job requires an exact match with the hardware-approved raw-BIN
   hash.
4. The packaged Windows flasher is run with `-ValidateOnly` before upload.

Branch pushes and manual runs create the firmware and, for an approved BIN, the
Windows-flasher artifact. Version tags additionally publish a GitHub Release.
Pull requests only build the firmware.

The initial port used a separate ELF/map/config/DTS inspection build and an
exact comparison with the standard artifact. That deeper one-time bring-up
inspection was removed from the active workflow after the image was validated
on hardware; its conclusions remain documented in the implementation sections
above.

### 9.1 Hardware-approved release gate

[`release/neo65cu-zmk.sha256`](../release/neo65cu-zmk.sha256) is not a
convenience checksum. The package job fails unless the new build equals the
single hardware-approved raw BIN hash. A source or keymap change must not
silently become a release merely because it builds and passes structural checks.

Updating the manifest requires a new pre-flash backup, immediate readback,
cold-boot test, complete installed-key/Fn/LED test, application reset, and all
three ROM DFU recovery tests.

## 10. First flash and physical acceptance test

### 10.1 Prove the application-independent hardware recovery contact

The QMK notes referred to a lower-board `SW1`, but the photographed PCB has no
button fitted. It has a two-pin through-hole footprint labeled `SW?` near the
MCU. Shorting the pads while the keyboard was already running caused no USB or
input change. Holding the short while applying USB power entered
`0483:df11` ROM DFU.

This proves the footprint acts as a power-on boot-selection contact, but not
its exact net name; no schematic or continuity measurement was available. Do
not probe or short other pads. Because the main PCB connects to a case-mounted
daughterboard through magnetic pogo pins, the contact is not a practical
everyday recovery method. Hold-Esc is the normal method.

### 10.2 Write only the validated main-flash image

The following is the sequence used for the first verified image. It is shown
for reproducibility, not as permission to skip the checks in Sections 2 and 3.
Obtain path and serial from a fresh listing, confirm both descriptors, and
complete the 128 KiB backup first.

```powershell
$dfuPath = "path from the current dfu-util -l"
$dfuSerial = "serial from the current dfu-util -l"

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

The download command selected only alt 0 and address `0x08000000`. It did not
use alt 1, mass erase, or `:leave`. The final comparison returned `True` before
USB was disconnected.

### 10.3 Staged acceptance results

The test proceeded in recovery-first order:

1. Confirm exact readback hash and valid vectors before reboot.
2. Disconnect/reconnect USB and confirm HID enumeration.
3. Repeat three no-key cold boots; all 3/3 succeeded.
4. Test every installed key individually for exactly one press and release.
5. Test `Fn + Esc` and `Fn + 1` through `Fn + =` for Grave/F1-F12.
6. Toggle Caps Lock and confirm the PC13 LED follows the host.
7. Press `Backspace + Left Ctrl + Left Alt` and confirm an application restart.
8. Hold Esc during a cold plug and reconfirm `0483:df11` ROM DFU.
9. From ZMK, press the four-corner combo and reconfirm ROM DFU.
10. Use the rear `SW?` contact at power-on and reconfirm ROM DFU.

These initial acceptance results predate the latency-motivated keymap change.
The same tested behaviors are now bound to `Fn + Backspace` and `Fn + Delete`;
those new bindings must be included in the next hardware-validation pass before
the release manifest is updated.

An official/Vial restoration drill was intentionally not performed on the
working board because it would add unnecessary erase/write cycles. Both full
readbacks, the stock BIN, dfu-util environment, exact hashes, and recovery
commands were stored externally instead.

### 10.4 Distribution flasher safeguards

The Windows package automates the same conservative sequence. Before writing,
it validates the release hash and vectors, requires explicit hardware
confirmation, finds exactly one target with the verified alt-0/alt-1
descriptors, locks its fresh path/serial, and uploads all 128 KiB. It then
writes only alt 0 at `0x08000000` and verifies a same-length readback.

The script has no alt-1 download, option-byte write, mass erase, or automatic
`:leave` path. The backup is retained even when a later step fails.

## 11. Symptom-based diagnostics

| Symptom | Check first |
| --- | --- |
| Board remains in ROM DFU after a write | Whether Esc is still held, BIN hash, vector table, initial MSP, Reset Handler, and `0x08000000` link address |
| USB HID never appears after leaving DFU | HSI × 6 PLL, PA11/PA12 pinctrl, USB peripheral reset, SRAM vector remap, and inherited interrupt state |
| Cold boot works but a ROM-to-app handoff fails | SYSCFG clock timing, platform pre-C hook, `CONFIG_INIT_ARCH_HW_AT_BOOT`, and SRAM vector table |
| One key also reports an adjacent key | Row/column direction, active-low flags, pull-ups, pin order, and 1/30 µs scan delays |
| A set of columns is missing | Polling mode, shared EXTI numbers, actual GPIO order, and unpopulated optional footprints |
| Caps Lock types correctly but LED does not change | PC13 polarity, HID indicator support, event listener initialization, and host LED state |
| Runtime `SW?` short does nothing | Expected behavior; the contact was only observed at power-on |
| Hold-Esc does not enter DFU | PA6/PC14 intersection, cold-plug timing, data cable, and whether another key is electrically holding the row/column |
| `Fn + Delete` restarts but no DFU appears | Fn binding, SRAM marker/link placement, ROM vector validation, SYSCFG remap, and jump-trampoline disassembly |
| DFU descriptor differs from the documented map | Stop; do not write or assume it is the same PCB revision |
| Only unrelated or inaccessible DFU devices appear | Recheck cable/driver/port and identify `0483:df11`; never operate on an uncertain target |

Do not diagnose from a Windows sound, LED state, or one error message alone.
Compare the current descriptor, raw BIN hash, vectors, generated clock tree,
and readback.

## 12. Checklist for reproducing or adapting the port

### Before the first build

- [ ] Confirm the exact MCU marking, package, flash size, and SRAM size.
- [ ] Obtain the authoritative matrix pins, order, scan direction, polarity,
      pulls, and timing.
- [ ] Identify USB D-/D+ and independently derive the 48 MHz clock path.
- [ ] Determine whether the bootloader is flash-resident or system ROM.
- [ ] Record every DFU alternate setting without selecting a write target.
- [ ] Read main flash twice and store matching hashes externally.
- [ ] Preserve a known-good official image and exact recovery environment.
- [ ] Validate the application start with vectors, reference firmware, and DFU
      layout rather than copying another board's offset.
- [ ] Account for Cortex-M0 vector remapping and both handoff directions.
- [ ] Start without settings, storage, Studio, Bluetooth, or unrelated
      features.

### Before flashing

- [ ] Confirm that every file-backed ELF LOAD lies within main flash.
- [ ] Confirm a vector table at `0x08000000`, a valid SRAM MSP, and Thumb Reset
      Handler inside the exact BIN payload.
- [ ] Confirm the 48-word SRAM vector table and early-init call order.
- [ ] Inspect the ROM jump tail after `MSR MSP` for stack/memory access.
- [ ] Confirm that no persistent flash-write symbol is linked.
- [ ] Run the raw-BIN vector and address validator.
- [ ] Match the raw BIN to the hardware-approved SHA-256.
- [ ] Re-list DFU and capture the current path/serial.
- [ ] Complete and verify a 131,072-byte pre-flash backup.
- [ ] Select only alt 0 at `0x08000000`; never use alt 1 or mass erase.

### After flashing

- [ ] Upload exactly the BIN length before reboot and compare hashes.
- [ ] Confirm USB HID enumeration and three cold boots.
- [ ] Test every installed key alone, including the full Fn layer.
- [ ] Confirm Caps Lock LED behavior.
- [ ] Confirm application reset separately from ROM DFU entry.
- [ ] Re-test hold-Esc, `Fn + Delete`, and hardware power-on ROM DFU paths.
- [ ] Record source commit, Actions run, raw BIN hash, readback hash, date, and
      remaining unpopulated positions.
- [ ] Keep recovery images outside the public source repository.

The aim is not to make the first image feature-complete. It is to prove one
hardware contract at a time while keeping an application-independent recovery
path available after every experiment.

## References

- [Neo65 CU QMK/Vial reference tree](https://github.com/lizhenmingdirk/qmk_firmware/tree/master/keyboards/neo/neo65cu)
- [Qwertykeys Neo65/60 Cu build guide](https://qwertykeys.notion.site/Neo65-60-Cu-Build-Guide-1863d090094280babee7ce4ff3901aa8)
- [STM32F072x8/xB datasheet](https://www.st.com/resource/en/datasheet/stm32f072cb.pdf)
- [STM32F0x1/F0x2/F0x8 reference manual RM0091](https://www.st.com/resource/en/reference_manual/rm0091-stm32f0x1stm32f0x2stm32f0x8-advanced-armbased-32bit-mcus-stmicroelectronics.pdf)
- [STM32 system-memory boot mode application note AN2606](https://www.st.com/resource/en/application_note/an2606-stm32-microcontroller-system-memory-boot-mode-stmicroelectronics.pdf)
- [ZMK documentation](https://zmk.dev/docs/)
