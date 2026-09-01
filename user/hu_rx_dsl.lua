-- ================================================================
-- Filename : hu_rx_dsl.lua
-- Module   : URC 行匹配 DSL（matchFlag/rows*/lineMatch），由 hu_rx.bind
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C)
    local state, SYS_EVT = C.state, C.SYS_EVT

    ----------------------------------------------------------------
    -- line / field copy
    ----------------------------------------------------------------

    local function normLine(line)
        if not line then
            return line
        end
        return (line:match("^%s*(.-)%s*$") or line)
    end

    local function copyFields(dst, src)
        if src then
            for k, v in pairs(src) do
                dst[k] = v
            end
        end
        return dst
    end

    local function publishAck(ev, payload)
        sys.publish(ev, payload)
        return true
    end

    ----------------------------------------------------------------
    -- capture → row
    ----------------------------------------------------------------

    local function assignCaptureField(row, name, cap)
        local mark = name:sub(1, 1)
        if mark == "!" then
            row[name:sub(2)] = (tonumber(cap) or 0) == 1
        elseif mark == "$" then
            row[name:sub(2)] = cap
        else
            row[name] = tonumber(cap) or 0
        end
    end

    local function fillFromCaptures(row, names, caps)
        for i = 1, #names do
            assignCaptureField(row, names[i], caps[i])
        end
    end

    ----------------------------------------------------------------
    -- pattern matchers
    ----------------------------------------------------------------

    local function matchFlag(pat, ev, tpl)
        return function(line)
            if not line:match(pat) then
                return false
            end
            return publishAck(ev, copyFields({}, tpl))
        end
    end

    local function matchPub(pat, ev, names, tpl)
        return function(line)
            local caps = { line:match(pat) }
            if caps[1] == nil then
                return false
            end
            local row = copyFields({}, tpl)
            fillFromCaptures(row, names, caps)
            return publishAck(ev, row)
        end
    end

    ----------------------------------------------------------------
    -- row collection
    ----------------------------------------------------------------

    local function rowsAppend(stateKey, row)
        if not row then
            return false
        end
        state[stateKey] = state[stateKey] or {}
        state[stateKey][#state[stateKey] + 1] = row
        return true
    end

    local function rowsFlush(endMarker, stateKey, ackEvent)
        return function(line)
            if line ~= endMarker then
                return false
            end
            local rows = state[stateKey]
            if type(rows) ~= "table" or #rows == 0 then
                return false
            end
            state[stateKey] = nil
            return publishAck(ackEvent, rows)
        end
    end

    local function rowsCollect(pat, stateKey, fieldNames)
        return function(line)
            local caps = { line:match(pat) }
            if caps[1] == nil then
                return false
            end
            local row = {}
            for i = 1, #fieldNames do
                row[fieldNames[i]] = tonumber(caps[i]) or 0
            end
            return rowsAppend(stateKey, row)
        end
    end

    local function drainRows(stateKey, ackEvent, payload)
        local rows = state[stateKey]
        if type(rows) == "table" and #rows > 0 then
            state[stateKey] = nil
            sys.publish(ackEvent, payload or rows)
            return true
        end
        return false
    end

    ----------------------------------------------------------------
    -- composition
    ----------------------------------------------------------------

    local function lineMatch(...)
        local handlers = { ... }
        return function(line)
            if not line then
                return false
            end
            for i = 1, #handlers do
                if handlers[i](line) then
                    return true
                end
            end
            return false
        end
    end

    local function normMatchers(...)
        local matcher = lineMatch(...)
        return function(line)
            return matcher(normLine(line))
        end
    end

    return {
        normLine = normLine,
        pubAck = publishAck,
        matchFlag = matchFlag,
        matchPub = matchPub,
        rowsAppend = rowsAppend,
        rowsFlush = rowsFlush,
        rowsCollect = rowsCollect,
        lineMatch = lineMatch,
        normMatchers = normMatchers,
        drainRows = drainRows,
    }
end

return _M
