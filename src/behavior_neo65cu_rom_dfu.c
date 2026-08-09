/*
 * Copyright (c) 2026 Neo65 CU ZMK contributors
 * SPDX-License-Identifier: MIT
 */

#define DT_DRV_COMPAT zmk_behavior_neo65cu_rom_dfu

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <zephyr/device.h>
#include <zephyr/init.h>
#include <zephyr/sys/util.h>

#include <cmsis_core.h>
#include <stm32f0xx.h>

#include <drivers/behavior.h>
#include <zmk/behavior.h>

#define NEO65CU_DFU_MAGIC 0x4E454F44U
#define STM32F072_SYSTEM_MEMORY_START 0x1FFFC800U
#define STM32F072_SYSTEM_MEMORY_END 0x20000000U
#define STM32F072_SRAM_START 0x20000000U
#define STM32F072_SRAM_END 0x20004000U

#define NEO65CU_ESC_ROW_PIN 6U
#define NEO65CU_ESC_COL_PIN 14U
#define NEO65CU_ESC_SETTLE_CYCLES 20000U

/* Retained across NVIC_SystemReset; never stored in flash or option bytes. */
static volatile uint32_t neo65cu_dfu_magic
    __attribute__((section(".noinit.neo65cu_dfu")));

typedef void (*rom_entry_t)(void);

/*
 * Preserve the vendor recovery gesture: row 0 / column 0 is Escape, with
 * rows driven low and columns read through pull-ups.  This runs before the
 * Zephyr GPIO and ZMK stacks, so it still works if USB or key scanning later
 * fails to initialize.  Only volatile GPIO/RCC registers are touched and all
 * of them are restored when Escape is not held.
 */
static bool neo65cu_escape_held_at_boot(void) {
    const uint32_t saved_ahbenr = RCC->AHBENR;

    RCC->AHBENR = saved_ahbenr | RCC_AHBENR_GPIOAEN | RCC_AHBENR_GPIOCEN;
    (void)RCC->AHBENR;

    const uint32_t saved_gpioa_moder = GPIOA->MODER;
    const uint32_t saved_gpioa_otyper = GPIOA->OTYPER;
    const uint32_t saved_gpioa_odr = GPIOA->ODR;
    const uint32_t saved_gpioc_moder = GPIOC->MODER;
    const uint32_t saved_gpioc_pupdr = GPIOC->PUPDR;

    /* Drive row PA6 low before changing it to an output. */
    GPIOA->BRR = BIT(NEO65CU_ESC_ROW_PIN);
    GPIOA->OTYPER &= ~BIT(NEO65CU_ESC_ROW_PIN);
    GPIOA->MODER =
        (GPIOA->MODER & ~GPIO_MODER_MODER6) | GPIO_MODER_MODER6_0;

    /* Read column PC14 as an input with its internal pull-up enabled. */
    GPIOC->MODER &= ~GPIO_MODER_MODER14;
    GPIOC->PUPDR =
        (GPIOC->PUPDR & ~GPIO_PUPDR_PUPDR14) | GPIO_PUPDR_PUPDR14_0;

    for (volatile uint32_t i = 0; i < NEO65CU_ESC_SETTLE_CYCLES; i++) {
        __NOP();
    }

    const bool held = (GPIOC->IDR & BIT(NEO65CU_ESC_COL_PIN)) == 0U;

    GPIOA->MODER = saved_gpioa_moder;
    GPIOA->OTYPER = saved_gpioa_otyper;
    GPIOA->ODR = saved_gpioa_odr;
    GPIOC->MODER = saved_gpioc_moder;
    GPIOC->PUPDR = saved_gpioc_pupdr;
    RCC->AHBENR = saved_ahbenr;

    return held;
}

static void neo65cu_request_rom_dfu(void) {
    neo65cu_dfu_magic = NEO65CU_DFU_MAGIC;
    __DSB();
    __ISB();
    NVIC_SystemReset();
    CODE_UNREACHABLE;
}

static int neo65cu_maybe_enter_rom_dfu(void) {
    if (neo65cu_dfu_magic != NEO65CU_DFU_MAGIC) {
        if (neo65cu_escape_held_at_boot()) {
            neo65cu_request_rom_dfu();
        }

        return 0;
    }

    neo65cu_dfu_magic = 0;
    __DSB();
    __ISB();

    const uint32_t *const vectors =
        (const uint32_t *)STM32F072_SYSTEM_MEMORY_START;
    const uint32_t stack_pointer = vectors[0];
    const uint32_t reset_handler = vectors[1];
    const uint32_t reset_address = reset_handler & ~1U;

    /* Fail closed if the immutable ROM vector table is not plausible. */
    if (stack_pointer < STM32F072_SRAM_START ||
        stack_pointer > STM32F072_SRAM_END ||
        (stack_pointer & 0x7U) != 0U ||
        (reset_handler & 1U) == 0U ||
        reset_address < STM32F072_SYSTEM_MEMORY_START ||
        reset_address >= STM32F072_SYSTEM_MEMORY_END) {
        return 0;
    }

    __disable_irq();

    SysTick->CTRL = 0;
    SysTick->LOAD = 0;
    SysTick->VAL = 0;
    SCB->ICSR = SCB_ICSR_PENDSVCLR_Msk | SCB_ICSR_PENDSTCLR_Msk;

    for (size_t i = 0; i < ARRAY_SIZE(NVIC->ICER); i++) {
        NVIC->ICER[i] = UINT32_MAX;
        NVIC->ICPR[i] = UINT32_MAX;
    }

    /* Cortex-M0 has no VTOR. Map the ROM vectors at 0x00000000 before
     * enabling interrupts in the factory bootloader. These are volatile
     * clock/memory-map registers, not flash or option bytes.
     */
    RCC->APB2ENR |= RCC_APB2ENR_SYSCFGCOMPEN;
    (void)RCC->APB2ENR;
    SYSCFG->CFGR1 =
        (SYSCFG->CFGR1 & ~SYSCFG_CFGR1_MEM_MODE) |
        SYSCFG_CFGR1_MEM_MODE_0;

    __set_CONTROL(0);
    __set_MSP(stack_pointer);
    __DSB();
    __ISB();
    __enable_irq();

    ((rom_entry_t)reset_handler)();
    CODE_UNREACHABLE;
}

SYS_INIT(neo65cu_maybe_enter_rom_dfu, PRE_KERNEL_1, 0);

static int on_pressed(struct zmk_behavior_binding *binding,
                      struct zmk_behavior_binding_event event) {
    ARG_UNUSED(binding);
    ARG_UNUSED(event);

    neo65cu_request_rom_dfu();
    return ZMK_BEHAVIOR_OPAQUE;
}

static const struct behavior_driver_api neo65cu_rom_dfu_driver_api = {
    .binding_pressed = on_pressed,
    .locality = BEHAVIOR_LOCALITY_CENTRAL,
#if IS_ENABLED(CONFIG_ZMK_BEHAVIOR_METADATA)
    .get_parameter_metadata = zmk_behavior_get_empty_param_metadata,
#endif
};

#define NEO65CU_ROM_DFU_INST(n)                                                                  \
    BEHAVIOR_DT_INST_DEFINE(n, NULL, NULL, NULL, NULL, POST_KERNEL,                              \
                            CONFIG_KERNEL_INIT_PRIORITY_DEFAULT,                                 \
                            &neo65cu_rom_dfu_driver_api);

DT_INST_FOREACH_STATUS_OKAY(NEO65CU_ROM_DFU_INST)
