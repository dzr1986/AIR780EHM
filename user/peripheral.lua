--- 外设聚合模块
-- 统一管理 LED、GPIO 按键（lib/key）、PIR 硬件（lib/pir）
-- PIR 业务：硬件中断 → PIR_HW_TRIGGERED → pir_ctrl（app 内 pir_ctrl.start）
require "sys"
require "sysplus"
local led_ctrl = require "led_ctrl"
local key = require "key"
local pir = require "pir"
local pir_ctrl = require "pir_ctrl"
local _M = {}
module(..., package.seeall)

--- 将 app 扁平配置映射为 lib/key 结构
-- @param cfg 扁平或嵌套配置表
-- @return { led, key }
local function normalizeConfig(cfg)
    cfg = cfg or {}

    local led = cfg.led or {}
    local keyCfg = cfg.key or {}

    if cfg.ledRedPin then led.redPin = cfg.ledRedPin end
    if cfg.ledBluePin then led.bluePin = cfg.ledBluePin end

    if cfg.pwrkeyPin or cfg.onPwrkeyShort or cfg.onPwrkeyLong then
        keyCfg.pwrkey = keyCfg.pwrkey or {}
        if cfg.pwrkeyPin then keyCfg.pwrkey.pin = cfg.pwrkeyPin end
        if cfg.onPwrkeyShort then keyCfg.pwrkey.onShortPress = cfg.onPwrkeyShort end
        if cfg.onPwrkeyLong then keyCfg.pwrkey.onLongPress = cfg.onPwrkeyLong end
    end

    if cfg.bootkeyPin or cfg.onBootkeyShort or cfg.onBootkeyLong then
        keyCfg.bootkey = keyCfg.bootkey or {}
        if cfg.bootkeyPin then keyCfg.bootkey.pin = cfg.bootkeyPin end
        if cfg.onBootkeyShort then keyCfg.bootkey.onShortPress = cfg.onBootkeyShort end
        if cfg.onBootkeyLong then keyCfg.bootkey.onLongPress = cfg.onBootkeyLong end
    end

    if cfg.readyPin or cfg.onReady then
        keyCfg.ready = keyCfg.ready or {}
        if cfg.readyPin then keyCfg.ready.pin = cfg.readyPin end
        if cfg.onReady then keyCfg.ready.onReady = cfg.onReady end
    end

    return {
        led = led,
        key = keyCfg,
    }
end

--[[
启动所有外设模块

@param cfg 配置表；按键默认从 key_config.KEY_CONFIG 加载，可扁平覆盖：
  pwrkeyPin, bootkeyPin, readyPin, onPwrkeyShort/Long, onBootkeyShort/Long, onReady
  或嵌套 key = { pwrkey={}, bootkey={}, ready={} }
]]
function _M.start(cfg)
    local sub = normalizeConfig(cfg)
    led_ctrl.start(sub.led)
    key.start(sub.key)
    pir.start()
    return true
end

function _M.getState()
    return {
        led = led_ctrl.getState(),
        key = key.getState(),
        pir = pir_ctrl.getState(),
    }
end

function _M.getConfig()
    return {
        led = ledCtrl.getConfig(),
        key = key.getConfig(),
        pir = pir_ctrl.getMediaConfig(),
    }
end

function _M.setLed(red, blue)
    led_ctrl.setLed(red, blue)
end

function _M.turnOffLed()
    led_ctrl.turnOff()
end

function _M.runLedPattern(pattern)
    if pattern == "blink_red" and led_ctrl.blinkRed then
        sys.taskInit(led_ctrl.blinkRed)
    elseif pattern == "blink_blue" and led_ctrl.blinkBlue then
        sys.taskInit(led_ctrl.blinkBlue)
    else
        log.warn("peripheral", "未知LED模式", pattern)
    end
end

return _M
