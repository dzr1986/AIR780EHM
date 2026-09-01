-- ================================================================
-- Filename : mqtt_conn.lua
-- Module   : topic/cfg/bootstrap/adapter/snap 连接外围，由 net_mqtt.bind
-- Arch     : doc/modules/NET_MQTT_DOWNLINK_DISPATCH.md
-- ================================================================
--
-- 结构：topic → uplink 格式 → MQTT 配置 → adapter/LED → 快照 → bootstrap
--

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C)
    local deviceId = C.deviceId
    local utils = C.utils
    local cfgm = C.cfgm
    local mqttInfo, mqttWarn = C.mqttInfo, C.mqttWarn
    local runtimePower, loader = C.rntmPwr, C.loader
    local flags = C.flags
    local escJson = utils.escJson

    local TOPIC_APP_PREFIX = "/panshi/app/"
    local TOPIC_DEVICE_PREFIX = "/panshi/device/"

    local TIMEOUT = {
        waitLocalIpMs = 300000,
        waitNetReadyMs = 300000,
        waitIpReadyMs = 120000,
    }

    local cachedDeviceId
    local cachedPubTopic
    local cachedSubTopic
    local runtimeMqttCfg

    ----------------------------------------------------------------
    -- topic / deviceNo
    ----------------------------------------------------------------

    local function getDeviceId()
        if cachedDeviceId then
            return cachedDeviceId
        end
        local id = deviceId.getDeviceId()
        if id and id ~= "" and id ~= "unknown_device" then
            cachedDeviceId = id
        end
        return id or "unknown_device"
    end

    local function pubTopic()
        if cachedPubTopic then
            return cachedPubTopic
        end
        local topic = TOPIC_APP_PREFIX .. getDeviceId() .. "/"
        if cachedDeviceId then
            cachedPubTopic = topic
        end
        return topic
    end

    local function subTopic()
        if cachedSubTopic then
            return cachedSubTopic
        end
        local topic = TOPIC_DEVICE_PREFIX .. getDeviceId() .. "/#"
        if cachedDeviceId then
            cachedSubTopic = topic
        end
        return topic
    end

    local function isDlTopic(topic)
        if type(topic) ~= "string" or topic == "" then
            return true
        end
        local prefix = TOPIC_DEVICE_PREFIX .. getDeviceId()
        if topic == prefix or topic == prefix .. "/" then
            return true
        end
        return topic:sub(1, #prefix + 1) == prefix .. "/"
    end

    local function subDownlink(client)
        local filter = subTopic()
        local pkgid = client:subscribe(filter, 1)
        if pkgid then
            mqttInfo("subscribe_downlink", filter, pkgid)
        else
            mqttWarn("subscribe_downlink_failed", filter)
        end
        return pkgid ~= nil
    end

    ----------------------------------------------------------------
    -- uplink JSON 格式
    ----------------------------------------------------------------

    local function msgIdPart(messageId)
        if messageId and messageId ~= "" then
            return string.format(',"messageId":"%s"', escJson(tostring(messageId)))
        end
        return ""
    end

    local function fmtUplink(dataType, fields)
        fields = fields or ""
        return string.format(
            '{"deviceNo":"%s","dataType":"%s"%s,"time":"%s"}',
            getDeviceId(), dataType, fields, utils.formatTime())
    end

    ----------------------------------------------------------------
    -- MQTT 运行期配置
    ----------------------------------------------------------------

    local function normalizeMqttCfg(cfg)
        if not cfg or not cfg.host or cfg.host == "" then
            return nil
        end
        local clientId = cfg.client_id
        if clientId == nil or clientId == "" then
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

    local function currentMqttCfg()
        if runtimeMqttCfg == nil then
            runtimeMqttCfg = normalizeMqttCfg(cfgm.get("MQTT_CFG"))
        end
        return runtimeMqttCfg or {}
    end

    local function mqttCfgEqual(a, b)
        return a.host == b.host
            and a.port == b.port
            and a.ssl == b.ssl
            and a.username == b.username
            and a.password == b.password
            and a.client_id == b.client_id
    end

    local function sameMqttCfg(cfg)
        local nextCfg = normalizeMqttCfg(cfg)
        local cur = currentMqttCfg()
        if not nextCfg or not cur then
            return false
        end
        return mqttCfgEqual(nextCfg, cur)
    end

    local function setMqttCfg(cfg)
        local normalized = normalizeMqttCfg(cfg)
        if not normalized then
            return false
        end
        runtimeMqttCfg = normalized
        return true
    end

    ----------------------------------------------------------------
    -- 蜂窝 adapter / 网络 LED
    ----------------------------------------------------------------

    local function pushNetLed(online)
        pcall(function()
            local hu = utils.hostUart()
            if hu and hu.pushNetLedSt then
                hu.pushNetLedSt(online)
            end
        end)
    end

    local function cellularAdapter()
        if socket and socket.LWIP_GP ~= nil then
            return socket.LWIP_GP
        end
        return nil
    end

    local function adapterReady(adapter)
        if utils.localIp(adapter) then
            return true
        end
        if not socket or not socket.adapter then
            return true
        end
        local target = adapter
        if target == nil and socket.dft then
            target = socket.dft()
        end
        if target == nil then
            return true
        end
        local ok, ready = pcall(socket.adapter, target)
        return ok and ready == true
    end

    ----------------------------------------------------------------
    -- SIM / 无线 / 电量快照
    ----------------------------------------------------------------

    local function snapRadio()
        return {
            csq = mobile.csq and mobile.csq() or "",
            rssi = mobile.rssi and mobile.rssi() or "",
            rsrq = mobile.rsrq and mobile.rsrq() or "",
            rsrp = mobile.rsrp and mobile.rsrp() or "",
            snr = mobile.snr and mobile.snr() or "",
        }
    end

    local function snapBattery()
        local usbOn = runtimePower.isUsbInserted() and 1 or 0
        return {
            power_status = usbOn,
            battery_percent = runtimePower.getBatteryPercent() or "--",
            battery_mv = runtimePower.getBatteryMv() or "--",
            low_power_mode = runtimePower.isLowPowerMode() and "rest" or "normal",
            usb_inserted = usbOn,
            charging = runtimePower.isCharging() and 1 or 0,
        }
    end

    local function fillOperator(snap)
        local cellular = loader.load("cell_boot")
        if cellular then
            snap.operator, snap.operator_name = cellular.resolveOperator(
                snap.imsi, snap.iccid, snap.apn)
        end
        local op, opName, apnFallback = runtimePower.getCellular()
        if snap.operator == "unknown" and op and op ~= "" and op ~= "unknown" then
            snap.operator = op
            snap.operator_name = opName or snap.operator_name
        end
        if not snap.apn and apnFallback and apnFallback ~= "" then
            snap.apn = apnFallback
        end
    end

    local function snapSim()
        local radio = snapRadio()
        local snap = {
            imei = mobile.imei() or "",
            imsi = mobile.imsi() or "",
            iccid = mobile.iccid() or "",
            status = mobile.status and mobile.status() or "",
            csq = radio.csq,
            rssi = radio.rssi,
            rsrq = radio.rsrq,
            rsrp = radio.rsrp,
            snr = radio.snr,
            simid = mobile.simid and mobile.simid() or "",
            ip = utils.localIp() or "",
            operator = "",
            operator_name = "",
        }
        local okApn, apn = pcall(mobile.apn, 0, 1)
        if okApn and apn then
            snap.apn = apn
        end
        fillOperator(snap)
        return snap
    end

    ----------------------------------------------------------------
    -- 网络 bootstrap
    ----------------------------------------------------------------

    local function publishNetReady(ok)
        flags.netReadyPub = true
        sys.publish("net_ready", getDeviceId(), ok)
    end

    local function startNetWaitTask()
        flags.bootstrapStarted = true
        sys.taskInit(function()
            local cellular = loader.load("cell_boot")
            local ip
            if cellular and loader.enabled("cellular") then
                _, ip = cellular.waitNet()
            else
                ip = utils.waitLocalIp(TIMEOUT.waitLocalIpMs)
            end
            if not flags.netReadyPub then
                publishNetReady(ip ~= nil)
            end
        end)
    end

    local function bootstrapNet()
        if not flags.bootstrapStarted then
            startNetWaitTask()
        end
        return true
    end

    local function waitNet()
        if not flags.netReadyPub and not sys.waitUntil("net_ready", TIMEOUT.waitNetReadyMs) then
            sys.waitUntil("IP_READY", TIMEOUT.waitIpReadyMs)
        end
        return getDeviceId()
    end

    ----------------------------------------------------------------
    -- export（名称供 net_mqtt / uplink / dispatch 引用）
    ----------------------------------------------------------------

    return {
        getDeviceId = getDeviceId,
        pubTopic = pubTopic,
        subTopic = subTopic,
        subDownlink = subDownlink,
        isDlTopic = isDlTopic,
        msgIdPart = msgIdPart,
        fmtUplink = fmtUplink,
        curMqttCfg = currentMqttCfg,
        normMqttCfg = normalizeMqttCfg,
        sameMqttCfg = sameMqttCfg,
        setMqttCfg = setMqttCfg,
        pushNetLed = pushNetLed,
        mqttCellAdp = cellularAdapter,
        mqttAdpReady = adapterReady,
        snapSim = snapSim,
        snapRadio = snapRadio,
        snapBattery = snapBattery,
        bootstrapNet = bootstrapNet,
        waitNet = waitNet,
    }
end

return _M
