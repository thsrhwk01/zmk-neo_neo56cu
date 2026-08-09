/*
 * Copyright (c) 2026 Neo65 CU ZMK contributors
 * SPDX-License-Identifier: MIT
 */

#include <cmsis_core.h>
#include <stm32f0xx.h>

/*
 * This hook runs directly from z_arm_reset, before z_arm_prep_c() copies the
 * Cortex-M0 vector table to SRAM.  The STM32F0 remap register is in SYSCFG,
 * whose APB clock is normally enabled later by the clock-control driver.  A
 * cold boot already maps main flash at zero, but a direct handoff from the
 * factory ROM can leave system memory mapped there.  Enable SYSCFG now so
 * Zephyr's SRAM remap cannot silently miss that chain-loaded case.
 *
 * The ROM USB bootloader can also leave SysTick and USB peripheral state
 * behind.  Clear them before Zephyr briefly restores interrupts in
 * z_arm_init_arch_hw_at_boot().  These writes affect only volatile core/RCC
 * registers; they cannot erase main flash, system ROM, or option bytes.
 */
void z_arm_platform_init(void) {
    __disable_irq();

    SysTick->CTRL = 0U;
    SysTick->LOAD = 0U;
    SysTick->VAL = 0U;
    SCB->ICSR = SCB_ICSR_PENDSVCLR_Msk | SCB_ICSR_PENDSTCLR_Msk;

    RCC->APB2ENR |= RCC_APB2ENR_SYSCFGCOMPEN;
    (void)RCC->APB2ENR;

    RCC->APB1RSTR |= RCC_APB1RSTR_USBRST;
    (void)RCC->APB1RSTR;
    RCC->APB1RSTR &= ~RCC_APB1RSTR_USBRST;

    __DSB();
    __ISB();
}
