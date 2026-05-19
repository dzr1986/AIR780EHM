--- 模块功能：基于 pwm demo 抽出的可复用 PWM 库
-- @module pwmTask
-- @author GitHub Copilot
-- @release 2026.5.13

require "sys"
module(..., package.seeall)

require "demoTask"

local DEFAULT_CHANNEL = 4
local config = {
    channel = DEFAULT_CHANNEL,
    task_name = "pwm_demo",
    phase_gap = 3000,
    legacy_sequence = nil,
    dynamic_sequence = nil,
    setup = nil,
}
local state = {
    last_task_name = nil,
    last_channel = DEFAULT_CHANNEL,
}

local function mergeConfig(newConfig)
    if type(newConfig) ~= "table" then
        return config
    end

    for key, value in pairs(newConfig) do
        if value ~= nil then
            config[key] = value
        end
    end
    return config
end

function configure(newConfig)
    return mergeConfig(newConfig)
end

function getConfig()
    return config
end

local function defaultLegacySequence()
    return {
        {freq = 1000, duty = 45, precision = 100, duration = 1000},
        {freq = 500, duty = 60, precision = 100, duration = 2000},
        {freq = 300, duty = 80, precision = 100, duration = 3000},
    }
end

local function defaultDynamicSequence()
    return {
        {action = "wait", duration = 2000},
        {action = "duty", value = 25},
        {action = "wait", duration = 2000},
        {action = "freq", value = 2000},
        {action = "wait", duration = 2000},
    }
end

function runLegacySequence(sequence, channel)
    local pwmChannel = channel or DEFAULT_CHANNEL
    local items = sequence or defaultLegacySequence()

    for _, item in ipairs(items) do
        local ok = pwm.open(pwmChannel, item.freq, item.duty, item.div or 0, item.precision or 100)
        log.info("pwmTask.runLegacySequence", pwmChannel, item.freq, item.duty, ok)
        sys.wait(item.duration or 1000)
        pwm.close(pwmChannel)
        sys.wait(item.gap or 1000)
    end
end

function runDynamicSequence(sequence, channel, setup)
    local pwmChannel = channel or DEFAULT_CHANNEL
    local setupConfig = setup or {freq = 1000, duty = 50, div = 0, precision = 100}
    local items = sequence or defaultDynamicSequence()

    assert(pwm.setup(pwmChannel, setupConfig.freq, setupConfig.duty, setupConfig.div or 0, setupConfig.precision or 100), "pwm.setup failed")
    assert(pwm.start(pwmChannel), "pwm.start failed")

    for _, item in ipairs(items) do
        if item.action == "wait" then
            sys.wait(item.duration or 1000)
        elseif item.action == "duty" then
            assert(pwm.setDuty(pwmChannel, item.value), "pwm.setDuty failed")
        elseif item.action == "freq" then
            assert(pwm.setFreq(pwmChannel, item.value), "pwm.setFreq failed")
        end
    end

    pwm.stop(pwmChannel)
end

function startDemo(config)
    local cfg = mergeConfig(config or {})
    local channel = cfg.channel or DEFAULT_CHANNEL
    local taskName = cfg.task_name or "pwm_demo"
    state.last_task_name = taskName
    state.last_channel = channel
    return demoTask.startOnce(taskName, function()
        runLegacySequence(cfg.legacy_sequence, channel)
        sys.wait(cfg.phase_gap or 3000)
        runDynamicSequence(cfg.dynamic_sequence, channel, cfg.setup)
    end)
end

function getState()
    return {
        last_task_name = state.last_task_name,
        last_channel = state.last_channel,
        running = state.last_task_name and demoTask.isRunning(state.last_task_name) or false,
    }
end
