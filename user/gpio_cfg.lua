-- ================================================================
-- Filename : gpio_cfg.lua
-- Module   : GPIO 输入/输出引脚定义 + KEY_CONFIG 按键触发定义
-- Arch     : 拆分自 config.lua。KEY_CONFIG 依赖本片段内的 GPIO_IN。
-- Note     : 不可命名为 gpio.lua——与合宙核心库 gpio 冲突，Luatools 会拒绝 require "gpio"。
-- ================================================================

-- ===== GPIO 输入引脚：pwr/boot/coproc/usb_det/chg_state/pir_det/misc 7 路 =====
_G.GPIO_IN = {
    pwr_key = {
        pin = 46,
        net_name = "PWRKEY",
        pull = "pullup",
        trigger_mode = "both",
        debounce_ms = 50,
        active_level = 0,
    },
    boot_key = {
        pin = 28,
        net_name = "BOOT_KEY",
        pull = "pullup",
        trigger_mode = "both",
        debounce_ms = 100,
        active_level = 0,
    },
    coproc_ready = {
        pin = 29,
        net_name = "COPROC_READY",
        pull = "pulldown",
        trigger_mode = "rising",
        debounce_ms = 100,
        active_level = 1,
    },
    usb_det = {
        pin = 27,
        net_name = "USB_DET",
        pull = "pullup",
        trigger_mode = "both",
        debounce_ms = 50,
        active_level = 0,
    },
    chg_state = {
        pin = 17,
        net_name = "CHG_STATE",
        pull = "pullup",
        trigger_mode = "both",
        debounce_ms = 50,
        active_level = 1,
    },
    pir_det = {
        pin = 30,
        net_name = "PIR_MCU_DET",
        pull = "pulldown",
        trigger_mode = "rising",
        debounce_ms = 50,
        active_level = 1,
    },
}

-- ===== GPIO 输出引脚：led_red/bat_stat_led/t31x_pwr_wake/t31x_boot/t31x_ota/t31x_mcu_int 6 路 =====
_G.GPIO_OUT = {
    led_red = {
        pin = 20,
        net_name = "LED_RED",
        init_level = 0,
        on_level = 1,
        enabled = false,
    },
    bat_stat_led = {
        pin = 21,
        net_name = "BAT_STAT_LED",
        init_level = 1,
        on_level = 0,
    },
    t31x_boot = {
        pin = 26,
        net_name = "t31x_BOOT",
        init_level = 0,
        on_level = 1,
    },
    t31x_pwr_wake = {
        pin = 22,
        net_name = "t31x_PWR_WAKE",
        init_level = 0,
        on_level = 1,
    },
    t31x_mcu_int = {
        pin = 29,
        net_name = "MCU_INT_CPU",
        init_level = 1,
        on_level = 0,
    },
    t31x_ota = {
        pin = 32,
        net_name = "t31x_OTA",
        init_level = 0,
        on_level = 1,
    },
}

-- ===== KEY_CONFIG：pwrkey/bootkey/ready 触发定义（依赖 GPIO_IN） =====
do
    local IN = _G.GPIO_IN or {}
    local function pwrKeyPin()
        if gpio and gpio.PWR_KEY then
            return gpio.PWR_KEY
        end
        return IN.pwr_key and IN.pwr_key.pin
    end
    _G.KEY_CONFIG = {
        pwrkey = {
            pin = pwrKeyPin(),
            triggerMode = "both",
            pull = "pullup",
            debounce = 50,
            longPressMs = 3000,
            requireReleaseFirst = true,
            events = { short = "GPIO_PWRKEY_SHORT", long = "GPIO_PWRKEY_LONG" },
        },
        bootkey = {
            pin = IN.boot_key and IN.boot_key.pin,
            triggerMode = "both",
            pull = "pullup",
            debounce = 100,
            longPressMs = 2000,
            requireReleaseFirst = true,
            events = { short = "GPIO_BOOTKEY_SHORT", long = "GPIO_BOOTKEY_LONG" },
        },
        ready = {
            pin = IN.coproc_ready and IN.coproc_ready.pin,
            triggerMode = "rising",
            pull = "pulldown",
            debounce = 100,
            activeLevel = 1,
            event = "GPIO_COPROC_READY",
        },
    }
end
