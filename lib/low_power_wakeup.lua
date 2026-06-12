--- 低功耗云端唤醒策略（二选一）
-- @module low_power_wakeup
--
-- 配置：config.lua → LOW_POWER_WAKEUP_CFG.mode
--   "mqtt" — rest 下保持 MQTT（net_mqtt.lua）
--   "tcp"  — AT+SERVCREATE 专有 TCP（net_tcp.lua；完整版见 archive/slim/user/net_tcp.lua）

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "lpw"
local MODE_MQTT, MODE_TCP = "mqtt", "tcp"

local function cfg()
    return _G.LOW_POWER_WAKEUP_CFG or {}
end

local function getMode()
    local m = cfg().mode
    if type(m) == "string" and m:lower() == MODE_TCP then
        return MODE_TCP
    end
    return MODE_MQTT
end

function isMqttMode()
    return getMode() == MODE_MQTT
end

function isTcpMode()
    return getMode() == MODE_TCP
end

function modeLabel()
    return getMode()
end

function allowTcpChannel()
    return isTcpMode()
end

function keepMqttAliveInRest()
    return isMqttMode()
end

function shouldCloseTcpOnEnterRest()
    return isMqttMode()
end

function shouldRestoreTcpOnExitRest()
    return isTcpMode()
end

function getModemHibernate()
    return false
end

local netTcpMod

local function netTcp()
    if not isTcpMode() then
        return nil
    end
    if netTcpMod == nil then
        local ok, mod = pcall(require, "net_tcp")
        netTcpMod = ok and mod or false
    end
    return netTcpMod or nil
end

function onEnterRest()
    if not shouldCloseTcpOnEnterRest() then
        log.info(LOG_TAG, "inT")
        return
    end
    local nt = netTcp()
    if not nt or not nt.getState then
        return
    end
    local st = nt.getState()
    if st and st.configured then
        log.info(LOG_TAG, "inM")
        nt.closeChannel(st.sid)
    end
end

function onExitRest()
    if not shouldRestoreTcpOnExitRest() then
        return
    end
    local ch = _G.NET_TCP_CHANNEL
    if not ch then
        return
    end
    local nt = netTcp()
    if nt and nt.applyChannel then
        log.info(LOG_TAG, "outT")
        nt.applyChannel(ch)
    end
end

function applyTcpChannel(ch)
    if not allowTcpChannel() then
        log.info(LOG_TAG, "scB")
        return false
    end
    local nt = netTcp()
    if not nt or not nt.applyChannel then
        log.warn(LOG_TAG, "noTcp")
        return false
    end
    return nt.applyChannel(ch)
end

function closeTcpChannel(sid)
    if not allowTcpChannel() then
        log.info(LOG_TAG, "scX", sid or "?")
        return false
    end
    local nt = netTcp()
    if not nt or not nt.closeChannel then
        return false
    end
    return nt.closeChannel(sid)
end

function appendGetCfgFields()
    local mode = getMode()
    if not allowTcpChannel() then
        return string.format(",wakeup_mode=%s", mode)
    end
    local nt = netTcp()
    local extra = (nt and nt.appendGetCfgFields and nt.appendGetCfgFields()) or ",tcp_on=0"
    return string.format(",wakeup_mode=%s", mode) .. extra
end

return _M
