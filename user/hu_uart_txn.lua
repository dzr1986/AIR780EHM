-- ================================================================
-- Filename : hu_uart_txn.lua
-- Module   : UART 事务互斥锁 + T3x 主动推送静默窗
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local DEFAULT = {
    hostPushQuietMs = 300,
    txnWaitSlice = 80,
    txnWaitMin = 20,
    hostIdleSliceMin = 20,
}

function bind(state, hostNowMs, opts)
    opts = opts or {}
    local cfg = {}
    for k, v in pairs(DEFAULT) do
        cfg[k] = opts[k] or v
    end

    local uartTxnOwner = nil
    local uartTxnDepth = 0

    local function noteHostPush()
        state.host_push_quiet_until = hostNowMs() + cfg.hostPushQuietMs
    end

    local function hostBusy()
        local untilMs = tonumber(state.host_push_quiet_until) or 0
        return untilMs > 0 and hostNowMs() < untilMs
    end

    local function waitHostIdle(timeoutMs)
        timeoutMs = math.max(0, tonumber(timeoutMs) or 2000)
        local deadline = hostNowMs() + timeoutMs
        while hostBusy() do
            local now = hostNowMs()
            if now >= deadline then
                return false
            end
            local quietUntil = tonumber(state.host_push_quiet_until) or 0
            local slice = math.min(quietUntil - now + cfg.hostIdleSliceMin, deadline - now)
            if slice < cfg.hostIdleSliceMin then
                slice = cfg.hostIdleSliceMin
            end
            if now + slice > deadline then
                slice = deadline - now
            end
            if slice <= 0 then
                return false
            end
            sys.wait(slice)
        end
        return true
    end

    local function uartAcquire(timeoutMs)
        timeoutMs = tonumber(timeoutMs) or 8000
        local me = coroutine.running()
        if not me then
            return false
        end
        if uartTxnOwner == me then
            uartTxnDepth = uartTxnDepth + 1
            return true
        end
        local deadline = hostNowMs() + timeoutMs
        while state.uart_txn_busy do
            local now = hostNowMs()
            if now >= deadline then
                return false
            end
            local slice = deadline - now
            if slice > cfg.txnWaitSlice then
                slice = cfg.txnWaitSlice
            elseif slice < cfg.txnWaitMin then
                slice = cfg.txnWaitMin
            end
            sys.wait(slice)
        end
        state.uart_txn_busy = true
        uartTxnOwner = me
        uartTxnDepth = 1
        return true
    end

    local function uartRelease()
        local me = coroutine.running()
        if uartTxnOwner ~= me then
            return
        end
        uartTxnDepth = uartTxnDepth - 1
        if uartTxnDepth <= 0 then
            uartTxnDepth = 0
            uartTxnOwner = nil
            state.uart_txn_busy = false
        end
    end

    return {
        noteHostPush = noteHostPush,
        hostBusy = hostBusy,
        waitHostIdle = waitHostIdle,
        uartAcquire = uartAcquire,
        uartRelease = uartRelease,
    }
end

return _M
