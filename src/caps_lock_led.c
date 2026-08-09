/*
 * Copyright (c) 2026 Neo65 CU ZMK contributors
 * SPDX-License-Identifier: MIT
 */

#include <errno.h>
#include <stdbool.h>

#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/init.h>
#include <zephyr/sys/util.h>

#include <zmk/event_manager.h>
#include <zmk/events/hid_indicators_changed.h>

#define CAPS_LOCK_LED_BIT BIT(1)
#define CAPS_LOCK_LED_NODE DT_ALIAS(caps_led)

static const struct gpio_dt_spec caps_lock_led =
    GPIO_DT_SPEC_GET(CAPS_LOCK_LED_NODE, gpios);
static bool caps_lock_led_ready;

static int caps_lock_led_init(void) {
    if (!gpio_is_ready_dt(&caps_lock_led)) {
        return -ENODEV;
    }

    const int err = gpio_pin_configure_dt(&caps_lock_led, GPIO_OUTPUT_INACTIVE);
    if (err == 0) {
        caps_lock_led_ready = true;
    }
    return err;
}

static int caps_lock_led_listener(const zmk_event_t *event_header) {
    const struct zmk_hid_indicators_changed *event =
        as_zmk_hid_indicators_changed(event_header);

    if (caps_lock_led_ready && event != NULL) {
        gpio_pin_set_dt(&caps_lock_led,
                        (event->indicators & CAPS_LOCK_LED_BIT) != 0U);
    }

    return ZMK_EV_EVENT_BUBBLE;
}

SYS_INIT(caps_lock_led_init, APPLICATION, CONFIG_APPLICATION_INIT_PRIORITY);

ZMK_LISTENER(neo65cu_caps_lock_led, caps_lock_led_listener);
ZMK_SUBSCRIPTION(neo65cu_caps_lock_led, zmk_hid_indicators_changed);
