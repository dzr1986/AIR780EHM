--- 外设聚合模块
-- 统一管理 LED、电源键、t3x 按键、PIR 硬件（lib/pir）
-- PIR 业务不走本模块回调：硬件中断 → APP_PIR_HW_TRIGGERED → pirCtrl（app 内 pirCtrl.start）
-- 媒体/录像请订阅 APP_EVENTS 或改 pirCtrl，勿传 onPirTriggered / onTriggered
require "sys"
require "sysplus"
local ledCtrl = require "ledCtrl"
local powerKey = require "powerKey"
local t3xKey = require "t3xKey"
local pir = require "pir"
local pirCtrl = require "pirCtrl"
local _M = {}
module(..., package.seeall)

--- 将 app 扁平配置映射为子模块结构
-- @param cfg 扁平或嵌套配置表
-- @return { led, pwrkey, t3xKey, pir }
local function normalizeConfig(cfg)
    cfg = cfg or {}

    local led = cfg.led or {}
    local pwrkey = cfg.pwrkey or {}
    local t3xKeyCfg = cfg.t3xKey or {}
    local pirCfg = cfg.pir or {}

    if cfg.ledRedPin then led.redPin = cfg.ledRedPin end
    if cfg.ledBluePin then led.bluePin = cfg.ledBluePin end

    if cfg.pwrkeyPin then pwrkey.pin = cfg.pwrkeyPin end
    if cfg.onPwrkeyShort then pwrkey.onShortPress = cfg.onPwrkeyShort end
    if cfg.onPwrkeyLong then pwrkey.onLongPress = cfg.onPwrkeyLong end

    if cfg.bootkeyPin or cfg.onBootkeyShort or cfg.onBootkeyLong then
        t3xKeyCfg.bootkey = t3xKeyCfg.bootkey or {}
        if cfg.bootkeyPin then t3xKeyCfg.bootkey.pin = cfg.bootkeyPin end
        if cfg.onBootkeyShort then t3xKeyCfg.bootkey.onShortPress = cfg.onBootkeyShort end
        if cfg.onBootkeyLong then t3xKeyCfg.bootkey.onLongPress = cfg.onBootkeyLong end
    end
    if cfg.t3xStartupPin or cfg.ont3xStarted then
        t3xKeyCfg.t3xStartup = t3xKeyCfg.t3xStartup or {}
        if cfg.t3xStartupPin then t3xKeyCfg.t3xStartup.pin = cfg.t3xStartupPin end
        if cfg.ont3xStarted then t3xKeyCfg.t3xStartup.onStarted = cfg.ont3xStarted end
    end

    if cfg.pirPin then pirCfg.pin = cfg.pirPin end

    return {
        led = led,
        pwrkey = pwrkey,
        t3xKey = t3xKeyCfg,
        pir = pirCfg,
    }
end

--[[
启动所有外设模块

@param cfg 配置表，支持嵌套或 app 扁平字段：
  led = { redPin, bluePin }
  pwrkey = { pin, onShortPress, onLongPress }
  t3xKey = { bootkey = { pin, onShortPress, onLongPress }, t3xStartup = { pin, onStarted } }
  pir = { pin, cooldown, debounce }   -- 仅硬件；无 onTriggered 回调
  或扁平：ledRedPin, ledBluePin, pwrkeyPin, onPwrkeyLong, bootkeyPin, onBootkeyLong,
         t3xStartupPin, ont3xStarted, pirPin
  PIR 状态/策略：pirCtrl.getState() / getMediaConfig()，见 getState/getConfig
]]
function _M.start(cfg)
    local sub = normalizeConfig(cfg)
    ledCtrl.start(sub.led)
    powerKey.start(sub.pwrkey)
    t3xKey.start(sub.t3xKey)
    pir.start(sub.pir)
    return true
end

--- 获取所有子模块状态
function _M.getState()
    return {
        led = ledCtrl.getState(),
        pwrkey = powerKey.getState(),
        t3xKey = t3xKey.getState(),
        pir = pirCtrl.getState(),
    }
end

--- 获取所有子模块配置
function _M.getConfig()
    return {
        led = ledCtrl.getConfig(),
        pwrkey = powerKey.getConfig(),
        t3xKey = t3xKey.getConfig(),
        pir = pirCtrl.getMediaConfig(),
    }
end

function _M.setLed(red, blue)
    ledCtrl.setLed(red, blue)
end

function _M.turnOffLed()
    ledCtrl.turnOff()
end

function _M.runLedPattern(pattern)
    if pattern == "blink_red" and ledCtrl.blinkRed then
        sys.taskInit(ledCtrl.blinkRed)
    elseif pattern == "blink_blue" and ledCtrl.blinkBlue then
        sys.taskInit(ledCtrl.blinkBlue)
    else
        log.warn("peripheral", "未知LED模式", pattern)
    end
end

return _M
