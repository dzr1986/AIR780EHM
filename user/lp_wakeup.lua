-- ================================================================
-- Filename : lp_wakeup.lua
-- Module   : 低功耗唤醒抽象：rest 期间 TCP/MQTT 行为切换，onEnterRest/onExitRest 两态
-- Arch     : doc/modules/LOW_POWER_WAKEUP.md
-- ================================================================

local loader = require "module_loader"
local cfgm = require "config_manager"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local MODE_MQTT = "mqtt"
local MODE_TCP = "tcp"

local netTcpMod
local boundNetTcp

local function wakeupCfg()
    return cfgm.get("LOW_POWER_WAKEUP_CFG")
end

local function isTcpMode()
    local m = wakeupCfg().mode
    return type(m) == "string" and m:lower() == MODE_TCP
end

local function getMode()
    return isTcpMode() and MODE_TCP or MODE_MQTT
end

function isMqttMode()
    return not isTcpMode()
end

function allowTcpChannel()
    return isTcpMode()
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

function bindNetTcp(mod)
    boundNetTcp = type(mod) == "table" and mod or nil
end

local function netTcp()
    if not isTcpMode() then return nil end
    if boundNetTcp then return boundNetTcp end
    if netTcpMod == nil then
        local mod = loader.load("net_tcp")
        netTcpMod = mod or false
    end
    return netTcpMod or nil
end

local function withTcp(fn)
    local nt = netTcp()
    return nt ~= nil and fn(nt) == true
end

function onEnterRest()
    if not isMqttMode() then return end
    local nt = netTcp()
    if not nt or not nt.getState then return end
    local st = nt.getState()
    if st and st.configured then
        nt.closeChannel(st.sid)
    end
end

function onExitRest()
    if not isTcpMode() then return end
    local ch = _G.NET_TCP_CHANNEL
    if not ch then return end
    withTcp(function(nt)
        return nt.applyChannel and nt.applyChannel(ch)
    end)
end

function applyTcpChannel(ch)
    return withTcp(function(nt)
        return nt.applyChannel and nt.applyChannel(ch)
    end)
end

function closeTcpChannel(sid)
    return withTcp(function(nt)
        return nt.closeChannel and nt.closeChannel(sid)
    end)
end

function appCfgFields()
    local mode = getMode()
    if isMqttMode() then
        return string.format(",wakeup_mode=%s", mode)
    end
    local nt = netTcp()
    local extra = (nt and nt.appCfgFields and nt.appCfgFields()) or ",tcp_on=0"
    return string.format(",wakeup_mode=%s", mode) .. extra
end

return _M
