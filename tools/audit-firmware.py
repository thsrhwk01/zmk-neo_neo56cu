#!/usr/bin/env python3
"""Fail-closed static audit for the Neo65 CU STM32F072 firmware image."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys


FLASH_START = 0x08000000
FLASH_END = 0x08020000
SRAM_START = 0x20000000
SRAM_END = 0x20004000
SYSTEM_MEMORY_START = 0x1FFFC800
OPTION_BYTES_START = 0x1FFFF800
VECTOR_WORDS = 48
DFU_MAGIC = 0x4E454F44
# Reset/NMI/HardFault/SVC/PendSV/SysTick plus STM32F072 USB IRQ 31.
REQUIRED_VECTORS = (1, 2, 3, 11, 14, 15, 16 + 31)


class AuditError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AuditError(message)


def audit_binary(path: Path) -> dict[str, int | str]:
    image = path.read_bytes()
    require(
        VECTOR_WORDS * 4 <= len(image) <= FLASH_END - FLASH_START,
        f"invalid image size: {len(image)} bytes",
    )

    image_end = FLASH_START + len(image)
    initial_msp, reset_handler = struct.unpack_from("<II", image)
    reset_address = reset_handler & ~1

    require(
        SRAM_START <= initial_msp <= SRAM_END and initial_msp % 8 == 0,
        f"invalid initial MSP: 0x{initial_msp:08X}",
    )
    require(reset_handler & 1 == 1, f"Reset Handler is not Thumb: 0x{reset_handler:08X}")
    require(
        FLASH_START <= reset_address < image_end,
        f"Reset Handler is outside the binary payload: 0x{reset_handler:08X}",
    )

    vectors = struct.unpack_from(f"<{VECTOR_WORDS}I", image)
    for index in REQUIRED_VECTORS:
        require(vectors[index] != 0, f"required core vector {index} is zero")

    nonzero_handlers = 0
    for index, vector in enumerate(vectors[1:], start=1):
        if vector == 0:
            continue
        nonzero_handlers += 1
        require(vector & 1 == 1, f"vector {index} is not Thumb: 0x{vector:08X}")
        address = vector & ~1
        require(
            FLASH_START <= address < image_end,
            f"vector {index} points outside the binary payload: 0x{vector:08X}",
        )

    require(image_end <= FLASH_END, "binary extends beyond STM32F072 main flash")
    require(FLASH_END < SYSTEM_MEMORY_START, "main flash unexpectedly overlaps system memory")
    require(SYSTEM_MEMORY_START < OPTION_BYTES_START, "invalid STM32F072 ROM boundary constants")
    require(
        struct.pack("<I", SYSTEM_MEMORY_START) in image,
        "linked binary does not contain the expected STM32F072 ROM base literal",
    )
    require(
        struct.pack("<I", DFU_MAGIC) in image,
        "linked binary does not contain the two-word ROM-DFU marker magic",
    )

    return {
        "size": len(image),
        "sha256": hashlib.sha256(image).hexdigest().upper(),
        "image_end": image_end,
        "initial_msp": initial_msp,
        "reset_handler": reset_handler,
        "nonzero_handlers": nonzero_handlers,
    }


def parse_config(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("CONFIG_") and "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
        else:
            match = re.fullmatch(r"# (CONFIG_[A-Z0-9_]+) is not set", line)
            if match:
                values[match.group(1)] = "n"
    return values


def audit_config(path: Path) -> None:
    config = parse_config(path)
    expected = {
        "CONFIG_BOARD_NEO65CU": "y",
        "CONFIG_SOC_SERIES_STM32F0X": "y",
        "CONFIG_SOC_STM32F072XB": "y",
        "CONFIG_FLASH_SIZE": "128",
        "CONFIG_SRAM_SIZE": "16",
        "CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC": "48000000",
        "CONFIG_ROM_START_OFFSET": "0",
        "CONFIG_FLASH_LOAD_OFFSET": "0x0",
        "CONFIG_FLASH_LOAD_SIZE": "0x20000",
        "CONFIG_USE_DT_CODE_PARTITION": "y",
        "CONFIG_SYSTEM_CLOCK_INIT_PRIORITY": "0",
        "CONFIG_CLOCK_CONTROL_INIT_PRIORITY": "1",
        "CONFIG_SRAM_VECTOR_TABLE": "y",
        "CONFIG_INIT_ARCH_HW_AT_BOOT": "y",
        "CONFIG_PLATFORM_SPECIFIC_INIT": "y",
        "CONFIG_MAIN_STACK_SIZE": "1024",
        "CONFIG_SYSTEM_WORKQUEUE_STACK_SIZE": "1024",
        "CONFIG_ISR_STACK_SIZE": "1024",
        "CONFIG_HEAP_MEM_POOL_SIZE": "1024",
        "CONFIG_ZMK_USB": "y",
        "CONFIG_USB_DEVICE_STACK": "y",
        "CONFIG_USB_DC_STM32": "y",
        "CONFIG_USB_DC_STM32_CLOCK_CHECK": "y",
        "CONFIG_USB_SELF_POWERED": "n",
        "CONFIG_ZMK_KSCAN_MATRIX_POLLING": "y",
        "CONFIG_FLASH": "n",
        "CONFIG_SETTINGS": "n",
        "CONFIG_NVS": "n",
        "CONFIG_FILE_SYSTEM": "n",
        "CONFIG_STREAM_FLASH": "n",
        "CONFIG_WATCHDOG": "n",
        "CONFIG_ZMK_BLE": "n",
        "CONFIG_BT": "n",
        "CONFIG_ZMK_STUDIO": "n",
    }
    for key, value in expected.items():
        require(config.get(key) == value, f"unexpected Kconfig value: {key}={config.get(key)!r}")

    for key in ("CONFIG_BOOTLOADER_MCUBOOT", "CONFIG_SW_VECTOR_RELAY", "CONFIG_SW_VECTOR_RELAY_CLIENT"):
        require(config.get(key, "n") != "y", f"forbidden chain-loader setting enabled: {key}")


def audit_devicetree(path: Path) -> None:
    text = re.sub(r"\s+", " ", path.read_text(encoding="utf-8"))
    patterns = {
        "128 KiB flash": r"flash@8000000 \{.*?reg = < 0x8000000 0x20000 >",
        "16 KiB SRAM": r"memory@20000000 \{.*?reg = < 0x20000000 0x4000 >",
        "main-flash code partition": r"code_partition: partition@0 \{.*?reg = < 0x0 0x20000 >",
        "HSI clock": r"clk_hsi: clk-hsi \{.*?clock-frequency = < 0x7a1200 >; status = \"okay\"",
        "disabled HSE": r"clk_hse: clk-hse \{.*?status = \"disabled\"",
        "disabled HSI48": r"clk_hsi48: clk-hsi48 \{.*?status = \"disabled\"",
        "disabled LSE on PC14/PC15": r"clk_lse: clk-lse \{.*?status = \"disabled\"",
        "HSI x6 PLL": r"pll: pll \{.*?status = \"okay\"; prediv = < 0x1 >; mul = < 0x6 >; clocks = < &clk_hsi >",
        "48 MHz system clock": r"rcc: rcc@40021000 \{.*?clocks = < &pll >; clock-frequency = < 0x2dc6c00 >",
        "USB PLL clock selection": r"usb: zephyr_udc0: usb@40005c00 \{.*?clocks = < &rcc 0x1c 0x800000 >, < &rcc 0x8 0x12730 >; status = \"okay\"",
        "USB endpoint count": r"usb: zephyr_udc0: usb@40005c00 \{.*?num-bidir-endpoints = < 0x4 >",
        "USB pins": r"usb: zephyr_udc0: usb@40005c00 \{.*?pinctrl-0 = < &usb_dm_pa11 &usb_dp_pa12 >",
    }
    for description, pattern in patterns.items():
        require(re.search(pattern, text) is not None, f"generated devicetree lost {description}")

    transform_match = re.search(
        r"default_transform: keymap_transform_0 \{(.*?)\};", text
    )
    require(transform_match is not None, "generated devicetree lost the matrix transform")
    map_match = re.search(r"\bmap = < (.*?) >;", transform_match.group(1))
    require(map_match is not None, "generated matrix transform has no map")
    actual_map = tuple(int(value, 0) for value in map_match.group(1).split())
    expected_map = (
        *range(0x000, 0x010),
        *range(0x100, 0x10E), 0x10F,
        *range(0x200, 0x20E), 0x20F,
        *range(0x300, 0x30E), 0x40F,
        0x400, 0x401, 0x402, 0x406, 0x40A, 0x40B, 0x40C, 0x40D, 0x40E,
    )
    require(actual_map == expected_map, "generated matrix transform differs from QMK LAYOUT_wired")

    kscan_match = re.search(r"kscan0: kscan \{(.*?)\};", text)
    require(kscan_match is not None, "generated devicetree lost kscan0")
    kscan = kscan_match.group(1)
    require('diode-direction = "row2col";' in kscan,
            "matrix no longer drives rows and reads columns")

    def parse_gpios(property_name: str) -> tuple[tuple[str, int, int], ...]:
        match = re.search(rf"\b{re.escape(property_name)} = (.*?);", kscan)
        require(match is not None, f"kscan0 lost {property_name}")
        return tuple(
            (controller, int(pin, 0), int(flags, 0))
            for controller, pin, flags in re.findall(
                r"< &(\w+) (0x[0-9a-f]+) (0x[0-9a-f]+) >", match.group(1)
            )
        )

    expected_columns = (
        ("gpioc", 14, 0x11), ("gpioc", 15, 0x11),
        ("gpioa", 0, 0x11), ("gpioa", 1, 0x11),
        ("gpioa", 2, 0x11), ("gpioa", 3, 0x11),
        ("gpioa", 4, 0x11), ("gpiob", 2, 0x11),
        ("gpiob", 10, 0x11), ("gpiob", 11, 0x11),
        ("gpiob", 12, 0x11), ("gpiob", 13, 0x11),
        ("gpiob", 14, 0x11), ("gpiob", 15, 0x11),
        ("gpioa", 8, 0x11), ("gpioa", 9, 0x11),
    )
    expected_rows = (
        ("gpioa", 6, 0x01), ("gpioa", 7, 0x01),
        ("gpiob", 0, 0x01), ("gpiob", 1, 0x01),
        ("gpiob", 9, 0x01),
    )
    require(parse_gpios("col-gpios") == expected_columns,
            "generated matrix column pins/flags differ from QMK")
    require(parse_gpios("row-gpios") == expected_rows,
            "generated matrix row pins/flags differ from QMK")
    require(
        re.search(r"caps_lock_led: caps_lock_led \{ gpios = < &gpioc 0xd 0x0 >;", text)
        is not None,
        "Caps Lock LED is no longer active-high PC13",
    )
    require(
        re.search(
            r"combo_rom_dfu \{ timeout-ms = < 0x96 >; "
            r"key-positions = < 0x0 0xf 0x3d 0x45 >; bindings = < &neo_dfu >;",
            text,
        ) is not None,
        "four-corner ROM DFU recovery combo changed",
    )


def run_tool(tool: str, *arguments: str) -> str:
    executable = shutil.which(tool)
    require(executable is not None, f"required tool is missing: {tool}")
    result = subprocess.run(
        [executable, *arguments],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    require(result.returncode == 0, f"{tool} failed:\n{result.stdout}")
    return result.stdout


def audit_elf(
    path: Path, binary: dict[str, int | str], tools: dict[str, str]
) -> None:
    readelf = run_tool(tools["readelf"], "-W", "-h", "-l", str(path))
    require("Machine:" in readelf and "ARM" in readelf, "ELF is not an ARM executable")
    require(re.search(r"Type:\s+EXEC", readelf) is not None, "ELF is not executable")

    entry_match = re.search(r"Entry point address:\s*(0x[0-9a-fA-F]+)", readelf)
    require(entry_match is not None, "could not parse ELF entry point")
    entry = int(entry_match.group(1), 16)
    reset_handler = int(binary["reset_handler"])
    require((entry & ~1) == (reset_handler & ~1), "ELF entry point differs from Reset vector")

    load_segments = []
    for line in readelf.splitlines():
        fields = line.split()
        if not fields or fields[0] != "LOAD":
            continue
        require(len(fields) >= 6, f"could not parse LOAD segment: {line}")
        physical_address = int(fields[3], 16)
        file_size = int(fields[4], 16)
        load_segments.append((physical_address, file_size))
        if file_size:
            require(
                FLASH_START <= physical_address < FLASH_END
                and physical_address + file_size <= int(binary["image_end"]),
                f"file-backed ELF LOAD is outside the exact BIN payload: {line.strip()}",
            )

    require(load_segments, "ELF has no LOAD segments")
    require(
        any(address == FLASH_START and size > 0 for address, size in load_segments),
        "ELF has no file-backed LOAD beginning at 0x08000000",
    )

    nm = run_tool(tools["nm"], "-n", "--defined-only", str(path))
    symbols: dict[str, int] = {}
    for line in nm.splitlines():
        match = re.match(r"^([0-9a-fA-F]+)\s+\w\s+(\S+)$", line)
        if match:
            symbols[match.group(2)] = int(match.group(1), 16)

    forbidden_symbol_fragments = (
        "flash_write",
        "flash_erase",
        "flash_area_write",
        "flash_area_erase",
        "settings_save",
        "nvs_write",
        "stream_flash",
    )
    for symbol in symbols:
        require(
            not any(fragment in symbol.lower() for fragment in forbidden_symbol_fragments),
            f"forbidden persistent-write symbol is linked: {symbol}",
        )

    for symbol in (
        "_vector_start",
        "__rom_region_start",
        "__rom_region_end",
        "_image_ram_start",
        "_image_ram_end",
        "_ram_vector_start",
        "_ram_vector_end",
        "relocate_vector_table",
        "z_main_stack",
        "z_arm_reset",
        "z_arm_prep_c",
        "z_arm_platform_init",
        "z_arm_init_arch_hw_at_boot",
        "neo65cu_dfu_marker",
        "neo65cu_maybe_enter_rom_dfu",
        "neo65cu_jump_to_rom",
        "stm32f0_init",
        "stm32_clock_control_init",
    ):
        require(symbol in symbols, f"required linked symbol is missing: {symbol}")

    require(symbols["_vector_start"] == FLASH_START, "vector table is not at main-flash offset zero")
    require(symbols["__rom_region_start"] == FLASH_START, "ROM link region has a nonzero offset")
    require(symbols["__rom_region_end"] <= FLASH_END,
            "linked ROM contents exceed main flash")
    require(symbols["__rom_region_end"] <= int(binary["image_end"]),
            "linked ROM contents extend past the exact BIN payload")
    require(symbols["_image_ram_start"] == SRAM_START, "RAM image does not begin at STM32F072 SRAM")
    require(symbols["_ram_vector_start"] == SRAM_START,
            "Cortex-M0 SRAM vector table is not mapped at 0x20000000")
    require(
        symbols["_ram_vector_end"] - symbols["_ram_vector_start"] == VECTOR_WORDS * 4,
        "Cortex-M0 SRAM vector table is not exactly 48 words",
    )
    require(
        symbols["z_main_stack"] + 1024 == int(binary["initial_msp"]),
        "Reset vector MSP is not the top of Zephyr's 1024-byte main stack",
    )
    require(symbols["_image_ram_end"] <= SRAM_END - 4096,
            "linked image leaves less than 4 KiB of SRAM headroom")
    require(
        SRAM_START <= symbols["neo65cu_dfu_marker"] <= SRAM_END - 8,
        "ROM-DFU marker is not in SRAM",
    )
    require(
        symbols["_ram_vector_end"] <= symbols["neo65cu_dfu_marker"]
        and symbols["neo65cu_dfu_marker"] + 8 <= symbols["_image_ram_end"]
        and symbols["neo65cu_dfu_marker"] % 4 == 0,
        "ROM-DFU marker overlaps vectors, exceeds the RAM image, or is misaligned",
    )

    reset_disassembly = run_tool(
        tools["objdump"], "-d", "--disassemble=z_arm_reset", str(path)
    ).lower()
    reset_sequence = (
        r"\bbl\s+\S*\s*<z_arm_platform_init>",
        r"\bbl\s+\S*\s*<z_arm_init_arch_hw_at_boot>",
        r"\bbl\s+\S*\s*<z_arm_prep_c>",
    )
    position = 0
    for pattern in reset_sequence:
        match = re.search(pattern, reset_disassembly[position:])
        require(match is not None, f"Reset path lacks ordered call: {pattern}")
        position += match.end()

    disassembly = run_tool(
        tools["objdump"], "-d", "--disassemble=neo65cu_jump_to_rom", str(path)
    ).lower()
    sequence = (
        r"\bmsr\s+control\s*,",
        r"\bmsr\s+msp\s*,",
        r"\bdsb\b",
        r"\bisb\b",
        r"\bcpsie\s+i\b",
        r"\bbx\s+r[0-9]+\b",
    )
    position = 0
    matches = []
    for pattern in sequence:
        match = re.search(pattern, disassembly[position:])
        require(match is not None, f"ROM jump trampoline lacks instruction pattern: {pattern}")
        absolute_start = position + match.start()
        absolute_end = position + match.end()
        matches.append((absolute_start, absolute_end))
        position = absolute_end

    tail = disassembly[matches[1][0] : matches[-1][1]]
    require(
        re.search(r"\b(push|pop|ldr|str|stm|ldm)\b", tail) is None,
        "ROM jump trampoline accesses memory after changing MSP",
    )


def audit_map(path: Path) -> None:
    text = path.read_text(encoding="utf-8", errors="replace")
    require(
        re.search(
            r"^FLASH\s+0x0*8000000\s+0x0*20000\s+xr\s*$",
            text,
            re.IGNORECASE | re.MULTILINE,
        ) is not None,
        "linker map does not use exactly 128 KiB at 0x08000000",
    )
    require(
        re.search(r"\.noinit\.neo65cu_dfu\s*\n\s*0x[0-9a-f]+\s+0x8\b", text, re.IGNORECASE)
        is not None,
        "two-word DFU marker is not an 8-byte .noinit section",
    )

    start = text.find("__init_PRE_KERNEL_1_start")
    end = text.find("__init_PRE_KERNEL_2_start", start)
    require(start >= 0 and end > start, "could not isolate PRE_KERNEL_1 init table")
    init_table = text[start:end]
    soc = init_table.find("soc.c.obj")
    recovery = init_table.find("behavior_neo65cu_rom_dfu.c.obj")
    clock = init_table.find("clock_stm32_ll_common.c.obj")
    require(
        0 <= soc < recovery < clock,
        "early recovery is not linked after basic SoC init and before clock init",
    )


def audit_expected_binary(actual: Path, expected: Path) -> None:
    require(
        actual.read_bytes() == expected.read_bytes(),
        "reusable-workflow BIN differs from the BIN whose ELF/config/map were audited",
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", required=True, type=Path, dest="binary")
    parser.add_argument("--expected-bin", type=Path)
    parser.add_argument("--elf", type=Path)
    parser.add_argument("--map", type=Path, dest="map_file")
    parser.add_argument("--config", type=Path)
    parser.add_argument("--dts", type=Path)
    parser.add_argument("--tool-prefix", default="arm-zephyr-eabi-")
    parser.add_argument("--readelf")
    parser.add_argument("--nm")
    parser.add_argument("--objdump")
    args = parser.parse_args()

    diagnostics = (args.elf, args.map_file, args.config, args.dts)
    require(all(item is not None for item in diagnostics) or not any(diagnostics),
            "--elf, --map, --config, and --dts must be supplied together")

    binary = audit_binary(args.binary)
    if args.expected_bin is not None:
        audit_expected_binary(args.binary, args.expected_bin)

    if args.elf is not None:
        tools = {
            "readelf": args.readelf or f"{args.tool_prefix}readelf",
            "nm": args.nm or f"{args.tool_prefix}nm",
            "objdump": args.objdump or f"{args.tool_prefix}objdump",
        }
        audit_config(args.config)
        audit_devicetree(args.dts)
        audit_elf(args.elf, binary, tools)
        audit_map(args.map_file)

    print(f"size={binary['size']}")
    print(f"sha256={binary['sha256']}")
    print(f"image_end=0x{int(binary['image_end']):08X}")
    print(f"initial_msp=0x{int(binary['initial_msp']):08X}")
    print(f"reset_handler=0x{int(binary['reset_handler']):08X}")
    print(f"nonzero_handler_vectors={binary['nonzero_handlers']}")
    print("audit=PASS")
    if os.environ.get("GITHUB_ACTIONS") == "true":
        print(
            "::notice file=tools/audit-firmware.py,"
            "title=Neo65 CU firmware audit passed::"
            f"sha256={binary['sha256']} size={binary['size']} "
            f"image_end=0x{int(binary['image_end']):08X}"
        )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AuditError, OSError) as error:
        print(f"AUDIT FAILED: {error}", file=sys.stderr)
        if os.environ.get("GITHUB_ACTIONS") == "true":
            annotation = (
                str(error)
                .replace("%", "%25")
                .replace("\r", "%0D")
                .replace("\n", "%0A")
            )
            print(
                "::error file=tools/audit-firmware.py,"
                f"title=Neo65 CU firmware audit::{annotation}",
                file=sys.stderr,
            )
        raise SystemExit(1)
