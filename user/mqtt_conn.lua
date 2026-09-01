-- ================================================================
-- Filename : mqtt_conn.lua
-- Module   : topic / 配置 / 组网 / 快照，由 net_mqtt.bind
-- Arch     : doc/modules/NET_MQTT_DOWNLINK_DISPATCH.md
-- ================================================================

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C)
    local idMod = C.deviceId
    local utils = C.utils
    local config = C.config
    local logInfo = C.logInfo
    local logWarn = C.logWarn
    local power = C.power
    local loader = C.loader
    local flags = C.flags
    local escJson = utils.escJson

    local APP_TOPIC = "/panshi/app/"
    local DEVICE_TOPIC = "/panshi/device/"
    local WAIT_LOCAL_IP_MS = 300000
    local WAIT_NET_READY_MS = 300000
    local WAIT_IP_READY_MS = 120000

    local cache = {
        deviceId = nil,
        pubTopic = nil,
        subTopic = nil,
        dlPrefix = nil,
        mqttCfg = nil,
        cell = nil,
    }

    ----------------------------------------------------------------
    -- 设备号 / 主题
    ----------------------------------------------------------------

    local function getDeviceId()
        local id = cache.deviceId
        if id then
            return id
        end
        id = idMod.getDeviceId()
        if id and id ~= "" and id ~= "unknown_device" then
            cache.deviceId = id
            return id
        end
        return id or "unknown_device"
    end

    local function cachePut(key, value)
        if cache.deviceId then
            cache[key] = value
        end
        return value
    end

    local function dlPrefix()
        local prefix = cache.dlPrefix
        if prefix then
            return prefix
        end
        return cachePut("dlPrefix", DEVICE_TOPIC .. getDeviceId())
    end

    local function pubTopic()
        local topic = cache.pubTopic
        if topic then
            return topic
        end
        return cachePut("pubTopic", APP_TOPIC .. getDeviceId() .. "/")
    end

    local function subTopic()
        local topic = cache.subTopic
        if topic then
            return topic
        end
        return cachePut("subTopic", dlPrefix() .. "/#")
    end

    local function isDownTopic(topic)
        if type(topic) ~= "string" or topic == "" then
            return true
        end
        local prefix = dlPrefix()
        return topic == prefix or topic:sub(1, #prefix + 1) == prefix .. "/"
    end

    local function subDown(client)
        local topic = subTopic()
        local pkgid = client:subscribe(topic, 1)
        if pkgid then
            logInfo("subscribe_downlink", topic, pkgid)
        else
            logWarn("subscribe_downlink_failed", topic)
        end
        return pkgid ~= nil
    end

    ----------------------------------------------------------------
    -- 上行 JSON
    ----------------------------------------------------------------

    local function msgIdJson(messageId)
        if messageId and messageId ~= "" then
            return string.format(',"messageId":"%s"', escJson(tostring(messageId)))
        end
        return ""
    end

    local function fmtUplink(dataType, fields)
        return string.format(
            '{"deviceNo":"%s","dataType":"%s"%s,"time":"%s"}',
            getDeviceId(), dataType, fields or "", utils.formatTime())
    end

    ----------------------------------------------------------------
    -- MQTT 配置
    ----------------------------------------------------------------

    local function normMqttCfg(cfg)
        if not cfg or not cfg.host or cfg.host == "" then
            return nil
        end
        local clientId = cfg.client_id
        if not clientId or clientId == "" then
            clientId = nil
        end
        return {
            host = cfg.host,
            port = tonumber(cfg.port) or 1883,
            ssl = cfg.ssl == true or cfg.ssl == 1,
            username = cfg.username or "",
            password = cfg.password or "",
            client_id = clientId,
        }
    end

    local function mqttCfg()
        if cache.mqttCfg == nil then
            cache.mqttCfg = normMqttCfg(config.get("MQTT_CFG"))
        end
        return cache.mqttCfg or {}
    end

    local function sameMqttCfg(cfg)
        local nxt = normMqttCfg(cfg)
        if not nxt then
            return false
        end
        local cur = mqttCfg()
        return nxt.host == cur.host
            and nxt.port == cur.port
            and nxt.ssl == cur.ssl
            and nxt.username == cur.username
            and nxt.password == cur.password
            and nxt.client_id == cur.client_id
    end

    local function setMqttCfg(cfg)
        local nxt = normMqttCfg(cfg)
        if not nxt then
            return false
        end
        cache.mqttCfg = nxt
        return true
    end

    ----------------------------------------------------------------
    -- 网卡 / 联网灯
    ----------------------------------------------------------------

    local function pushNetLed(online)
        local ok, hu = pcall(utils.hostUart)
        if ok and hu and hu.pushNetLedSt then
            pcall(hu.pushNetLedSt, hu, online)
        end
    end

    local function cellAdapter()
        if socket and socket.LWIP_GP ~= nil then
            return socket.LWIP_GP
        end
        return nil
    end

    local function adapterReady(adapter)
        if utils.localIp(adapter) or not socket or not socket.adapter then
            return true
        end
        if adapter == nil and socket.dft then
            adapter = socket.dft()
        end
        if adapter == nil then
            return true
        end
        local ok, ready = pcall(socket.adapter, adapter)
        return ok and ready == true
    end

    ----------------------------------------------------------------
    -- 快照
    ----------------------------------------------------------------

    local function mobVal(fn)
        return fn and fn() or ""
    end

    local function radioSnap()
        return {
            csq = mobVal(mobile.csq),
            rssi = mobVal(mobile.rssi),
            rsrq = mobVal(mobile.rsrq),
            rsrp = mobVal(mobile.rsrp),
            snr = mobVal(mobile.snr),
        }
    end

    local function battSnap()
        local usbOn = power.isUsbInserted() and 1 or 0
        return {
            power_status = usbOn,
            usb_inserted = usbOn,
            battery_percent = power.getBatteryPercent() or "--",
            battery_mv = power.getBatteryMv() or "--",
            low_power_mode = power.isLowPowerMode() and "rest" or "normal",
            charging = power.isCharging() and 1 or 0,
        }
    end

    local function loadCell()
        if cache.cell == nil then
            cache.cell = loader.load("cell_boot") or false
        end
        return cache.cell or nil
    end

    local function fillOperator(snap)
        local cell = loadCell()
        if cell then
            snap.operator, snap.operator_name = cell.resolveOperator(
                snap.imsi, snap.iccid, snap.apn)
        end
        local op, opName, apnFallback = power.getCellular()
        if snap.operator == "unknown" and op and op ~= "" and op ~= "unknown" then
            snap.operator = op
            snap.operator_name = opName or snap.operator_name
        end
        if not snap.apn and apnFallback and apnFallback ~= "" then
            snap.apn = apnFallback
        end
    end

    local function simSnap()
        local snap = radioSnap()
        snap.imei = mobile.imei() or ""
        snap.imsi = mobile.imsi() or ""
        snap.iccid = mobile.iccid() or ""
        snap.status = mobVal(mobile.status)
        snap.simid = mobVal(mobile.simid)
        snap.ip = utils.localIp() or ""
        snap.operator = ""
        snap.operator_name = ""
        local okApn, apn = pcall(mobile.apn, 0, 1)
        if okApn and apn then
            snap.apn = apn
        end
        fillOperator(snap)
        return snap
    end

    ----------------------------------------------------------------
    -- 组网
    ----------------------------------------------------------------

    local function pubNetReady(ok)
        flags.netReadyPub = true
        sys.publish("net_ready", getDeviceId(), ok)
    end

    local function startNet()
        if flags.bootstrapStarted then
            return true
        end
        flags.bootstrapStarted = true
        sys.taskInit(function()
            local cell = loadCell()
            local ip
            if cell and loader.enabled("cellular") then
                _, ip = cell.waitNet()
            else
                ip = utils.waitLocalIp(WAIT_LOCAL_IP_MS)
            end
            if not flags.netReadyPub then
                pubNetReady(ip ~= nil)
            end
        end)
        return true
    end

    local function waitNet()
        if not flags.netReadyPub and not sys.waitUntil("net_ready", WAIT_NET_READY_MS) then
            sys.waitUntil("IP_READY", WAIT_IP_READY_MS)
        end
        return getDeviceId()
    end

    return {
        -- 主题
        getDeviceId = getDeviceId,
        pubTopic = pubTopic,
        subTopic = subTopic,
        subDown = subDown,
        isDownTopic = isDownTopic,
        -- 上行 JSON
        msgIdJson = msgIdJson,
        fmtUplink = fmtUplink,
        -- 配置
        mqttCfg = mqttCfg,
        normMqttCfg = normMqttCfg,
        sameMqttCfg = sameMqttCfg,
        setMqttCfg = setMqttCfg,
        -- 网卡 / 灯
        pushNetLed = pushNetLed,
        cellAdapter = cellAdapter,
        adapterReady = adapterReady,
        -- 快照
        simSnap = simSnap,
        radioSnap = radioSnap,
        battSnap = battSnap,
        -- 组网
        startNet = startNet,
        waitNet = waitNet,
    }
end

return _M
