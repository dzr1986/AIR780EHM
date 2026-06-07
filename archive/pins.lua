--- 模块功能：GPIO 通用控制库，参考根目录 lib/pins.lua 设计
-- @module pins
-- @author GitHub Copilot
-- @release 2026.5.13

require "sys"
module(..., package.seeall)

local dirs = {}
local state = {}

local function normalizeLevel(value)
    if value == nil then
        return nil
    end

    value = tonumber(value)
    if value and value ~= 0 then
        return 1
    end
    return 0
end

local function setupOutput(pin, level)
    local outputLevel = normalizeLevel(level) or 0
    gpio.setup(pin, outputLevel)
    dirs[pin] = true
    state[pin] = state[pin] or {pin = pin}
    state[pin].mode = "output"
    state[pin].level = outputLevel
end

local function setupInput(pin, pull)
    gpio.setup(pin, nil, pull)
    dirs[pin] = false
    state[pin] = state[pin] or {pin = pin}
    state[pin].mode = "input"
    state[pin].pull = pull
    state[pin].level = gpio.get(pin)
end

--- 配置 GPIO 模式
-- @number pin GPIO ID
-- @param val number、nil 或 function
-- number 表示输出模式默认电平；nil 表示输入模式；function 表示中断回调
-- @param pull 上下拉配置
-- @param edge 中断触发边沿
-- @param debounce 去抖时间，单位 ms
-- @return function
-- 输出模式返回的函数可设置电平；输入/中断模式返回的函数可读取电平。
-- 为兼容参考 lib/pins.lua，返回函数在输入/输出间会自动切换。
function setup(pin, val, pull, edge, debounce)
    if not pin then
        return function()
            return nil
        end
    end

    close(pin)

    if type(val) == "function" then
        gpio.setup(pin, function(level, ioNumber)
            state[pin] = state[pin] or {pin = pin}
            state[pin].mode = "interrupt"
            state[pin].level = level
            state[pin].last_interrupt_pin = ioNumber or pin
            val(level, ioNumber or pin)
        end, pull, edge)
        if debounce and debounce > 0 then
            gpio.debounce(pin, debounce)
        end
        dirs[pin] = false
        state[pin] = {
            pin = pin,
            mode = "interrupt",
            pull = pull,
            edge = edge,
            debounce = debounce,
            level = gpio.get(pin),
        }
        return function()
            local level = gpio.get(pin)
            state[pin].level = level
            return level
        end
    end

    if val ~= nil then
        setupOutput(pin, val)
    else
        setupInput(pin, pull)
    end

    return function(nextValue)
        local outputLevel = normalizeLevel(nextValue)

        if outputLevel == nil then
            if dirs[pin] then
                setupInput(pin, pull)
            end
            local inputLevel = gpio.get(pin)
            state[pin] = state[pin] or {pin = pin}
            state[pin].level = inputLevel
            return inputLevel
        end

        if not dirs[pin] then
            setupOutput(pin, outputLevel)
        else
            gpio.set(pin, outputLevel)
            state[pin] = state[pin] or {pin = pin}
            state[pin].mode = "output"
            state[pin].level = outputLevel
        end
        return outputLevel
    end
end

--- 关闭 GPIO
function close(pin)
    if pin then
        gpio.close(pin)
        dirs[pin] = nil
        state[pin] = nil
    end
end

function getState(pin)
    if pin then
        return state[pin]
    end
    return state
end