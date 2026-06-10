--- 低功耗云端唤醒策略（二选一）
-- @module low_power_wakeup
--
-- 配置真源：config.lua → LOW_POWER_WAKEUP_CFG.mode
--   "mqtt" — rest 下保持 MQTT 长连接（net_mqtt.lua），下行 2001/2002 唤醒
--   "tcp"  — AT+SERVCREATE 专有 TCP 长连接（net_tcp.lua），wake_hex 唤醒
--
-- 调用方：app.lua（进/出 rest）、host_uart.lua（SERVCREATE/SERVCLOSE/GETCFG）、net_tcp.lua（门禁）

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "low_power_wakeup"

local MODE_MQTT = "mqtt"
local MODE_TCP = "tcp"

local function wakeupCfg()
    return _G.LOW_POWER_WAKEUP_CFG or {}
end

local function normalizeMode(mode)
    if type(mode) ~= "string" then
        return MODE_MQTT
    end
    mode = mode:lower()
    if mode == MODE_TCP then
        return MODE_TCP
    end
    return MODE_MQTT
end

--- 当前唤醒通道："mqtt" | "tcp"
function getMode()
    return normalizeMode(wakeupCfg().mode)
end

function isMqttMode()
    return getMode() == MODE_MQTT
end

function isTcpMode()
    return getMode() == MODE_TCP
end

--- 供启动日志 / GETCFG
function modeLabel()
    return getMode()
end

--- 是否允许 AT+SERVCREATE 与 net_tcp 任务
function allowTcpChannel()
    return isTcpMode()
end

--- rest 下是否保持 MQTT（modem_hibernate=false）
function keepMqttAliveInRest()
    return isMqttMode()
end

--- 进 rest 时是否断开 TCP（MQTT 模式关 TCP；TCP 模式保持长连接）
function shouldCloseTcpOnEnterRest()
    return isMqttMode()
end

--- 出 rest 时是否恢复 TCP（仅 TCP 模式）
function shouldRestoreTcpOnExitRest()
    return isTcpMode()
end

--- enterSleep 传给 t3x_ctrl 的 modemHibernate（两种模式均保持蜂窝在线）
function getModemHibernate()
    return false
end

local function safeRequireNetTcp()
    local ok, mod = pcall(require, "net_tcp")
    if ok then
        return mod
    end
    return nil
end

--- 进 rest：按模式处理 TCP 长连接
function onEnterRest()
    if not shouldCloseTcpOnEnterRest() then
        log.info(LOG_TAG, "enter rest, keep tcp (mode=tcp)")
        return
    end
    local net_tcp = safeRequireNetTcp()
    if not net_tcp or not net_tcp.getState then
        return
    end
    local st = net_tcp.getState()
    if st and st.configured then
        log.info(LOG_TAG, "enter rest, close tcp (mode=mqtt)")
        net_tcp.closeChannel(st.sid)
    end
end

--- 出 rest：TCP 模式恢复通道
function onExitRest()
    if not shouldRestoreTcpOnExitRest() then
        return
    end
    local ch = _G.NET_TCP_CHANNEL
    if not ch then
        return
    end
    local net_tcp = safeRequireNetTcp()
    if net_tcp and net_tcp.applyChannel then
        log.info(LOG_TAG, "exit rest, restore tcp")
        net_tcp.applyChannel(ch)
    end
end

--- app / host_uart：SERVCREATE
function applyTcpChannel(ch)
    if not allowTcpChannel() then
        log.info(LOG_TAG, "SERVCREATE blocked, mode=mqtt")
        return false
    end
    local net_tcp = safeRequireNetTcp()
    if not net_tcp or not net_tcp.applyChannel then
        return false
    end
    return net_tcp.applyChannel(ch)
end

--- app / host_uart：SERVCLOSE
function closeTcpChannel(sid)
    if not allowTcpChannel() then
        log.info(LOG_TAG, "SERVCLOSE blocked, mode=mqtt", sid or "?")
        return false
    end
    local net_tcp = safeRequireNetTcp()
    if not net_tcp or not net_tcp.closeChannel then
        return false
    end
    return net_tcp.closeChannel(sid)
end

--- GETCFG 追加字段：wakeup_mode +（TCP 模式）tcp 状态
function appendGetCfgFields()
    local mode = getMode()
    if not allowTcpChannel() then
        return string.format(",wakeup_mode=%s", mode)
    end
    local net_tcp = safeRequireNetTcp()
    if net_tcp and net_tcp.appendGetCfgFields then
        return string.format(",wakeup_mode=%s", mode) .. net_tcp.appendGetCfgFields()
    end
    return string.format(",wakeup_mode=%s,tcp_on=0", mode)
end

return _M
