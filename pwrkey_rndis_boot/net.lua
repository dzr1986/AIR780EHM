--[[
@module  net
@summary 4G 联网（摘自 testmy/user/single_mqtt.lua 统一联网逻辑，RNDIS 共享此连接）
]]

local cfg = require "config"

local M = {}

function M.start()
    sys.taskInit(function()
        if not mobile then
            log.warn("net", "无 mobile 库，跳过 4G")
            return
        end

        if cfg.netstatus_io then
            gpio.setup(cfg.netstatus_io, 0)
        end

        local restart_count = 0
        local max_restart_attempts = 3
        local restart_delay = 30000

        while restart_count < max_restart_attempts do
            local ret = sys.waitUntil("IP_READY", 60000)
            if ret then
                log.info("NETWORK", "联网成功",
                    "ip=", socket.localIP(),
                    "imei=", mobile.imei(),
                    "csq=", mobile.csq())
                sys.publish("net_ready")
                return
            end

            restart_count = restart_count + 1
            log.warn("NETWORK", "联网失败，第", restart_count, "次")
            if restart_count < max_restart_attempts then
                log.info("NETWORK", restart_delay / 1000, "秒后 mobile.reset")
                sys.wait(restart_delay)
                mobile.reset()
            else
                log.error("NETWORK", "已达最大重试，RNDIS 可能无法共享上网")
            end
        end
    end)
end

return M
