--[[
@module  pwrkey_boot
@summary pwrkey 长按关机；boot 短按/长按控制 T3x
]]

local cfg = require "config"

local M = {}

local pwrkey_down_ms = 0
local pwrkey_timer = nil
local bootkey_down_ms = 0
local bootkey_timer = nil

local function now_ms()
    return mcu.ticks()
end

local function t3x_power_on()
    log.info("boot", "T3x 上电")
    gpio.setup(cfg.t3x_power_io, 1)
    gpio.set(cfg.t3x_power_io, 1)
end

local function t3x_enter_boot_mode()
    log.info("boot", "进入 T3x boot 模式")
    gpio.setup(cfg.t3x_power_io, 1)
    gpio.set(cfg.t3x_power_io, 0)
    sys.timerStart(function()
        gpio.setup(cfg.t3x_boot_io, 1)
        gpio.set(cfg.t3x_boot_io, 1)
        gpio.setup(cfg.t3x_ota_io, 1)
        gpio.set(cfg.t3x_ota_io, 1)
    end, 500)
    sys.timerStart(t3x_power_on, 800)
end

local function on_pwrkey_long()
    log.info("pwrkey", "长按 %d ms，关机", cfg.pwrkey_long_ms)
    pm.shutdown()
end

local function on_bootkey_long()
    log.info("bootkey", "长按 %d ms，T3x boot", cfg.bootkey_long_ms)
    t3x_enter_boot_mode()
end

local function gpio_irq(io, level)
    if io == cfg.pwrkey_io then
        if level == 0 then
            pwrkey_down_ms = now_ms()
            if pwrkey_timer then sys.timerStop(pwrkey_timer) end
            pwrkey_timer = sys.timerStart(on_pwrkey_long, cfg.pwrkey_long_ms)
        else
            if pwrkey_timer then
                sys.timerStop(pwrkey_timer)
                pwrkey_timer = nil
            end
            log.info("pwrkey", "释放")
        end
    elseif io == cfg.bootkey_io then
        if level == 0 then
            bootkey_down_ms = now_ms()
            if bootkey_timer then sys.timerStop(bootkey_timer) end
            bootkey_timer = sys.timerStart(on_bootkey_long, cfg.bootkey_long_ms)
        else
            if bootkey_timer then
                sys.timerStop(bootkey_timer)
                bootkey_timer = nil
            end
            local dur = now_ms() - bootkey_down_ms
            if dur < cfg.bootkey_long_ms then
                log.info("bootkey", "短按，T3x 上电")
                gpio.setup(cfg.t3x_ota_io, 1)
                gpio.set(cfg.t3x_ota_io, 1)
                t3x_power_on()
            end
            log.info("bootkey", "释放")
        end
    end
end

function M.init_gpio()
    if cfg.led_red_io then
        gpio.setup(cfg.led_red_io, 0)
        gpio.set(cfg.led_red_io, 0)
    end
    gpio.setup(cfg.pwrkey_io, gpio_irq, gpio.PULLUP, gpio.BOTH)
    gpio.debounce(cfg.pwrkey_io, 50)
    gpio.setup(cfg.bootkey_io, gpio_irq, gpio.PULLUP, gpio.BOTH)
    gpio.debounce(cfg.bootkey_io, 100)
    log.info("pwrkey_boot", "GPIO 已配置")
end

function M.power_on_t3x()
    t3x_power_on()
end

return M
