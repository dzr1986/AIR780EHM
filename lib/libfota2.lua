--[[
@module libfota2
@summary FOTA 升级 v2（合宙 IoT + 脚本版 VERSION 转 IoT 版）
@version 1.1
@date    2024.11.22
@author  wendal/HH
@demo    fota2

@usage
local libfota2 = require "libfota2"
-- 合宙 IoT：空 opts，需全局 PRODUCT_KEY / PROJECT / VERSION
libfota2.request(function(ret) if ret == 0 then rtos.reboot() end end, {})
-- 自建/CDN：url 前加 ### 表示完整地址
libfota2.request(cb, { url = "###http://cdn.example.com/fw.bin" })
]]

local sys = require "sys"
require "sysplus"

local libfota2 = {}

local LOG_TAG = "libfota2"
local IOT_UPGRADE_URL = "http://iot.openluat.com/api/site/firmware_upgrade?"
local IOT_HOST = "iot.openluat.com"
local SCRIPT_VERSION_PATTERN = "^%d%d%d%.%d%d%d%.%d%d%d$"

--- 合宙 IoT 平台错误码说明（HTTP 非 200 时 body 内 code）
local IOT_ERR_HINT = {
    [3] = "无效的设备，检查 imei 参数",
    [17] = "无权限，检查 IMEI 是否在项目下、固件与项目是否同账号",
    [21] = "不允许升级，检查平台是否禁止该 IMEI",
    [25] = "无效的项目，检查 PRODUCT_KEY",
    [26] = "无效固件，检查 firmware_name 与后台一致",
    [27] = "已是最新或未配置升级设备",
    [40] = "循环升级被禁，在平台解除该 IMEI 禁止",
    [43] = "差分包生成中，等待 1~3 分钟后重试",
}

local function coreVersionNumber()
    local coreVer = rtos and rtos.version and rtos.version()
    if not coreVer or coreVer == "" then
        return nil
    end
    return coreVer:sub(1, 1) == "V" and coreVer:sub(2) or coreVer
end

--- 脚本版 001.000.002 → IoT 2034.001.002
local function resolveIotOtaVersion(ver)
    if ver == nil or ver == "" then
        ver = _G.VERSION
    end
    if type(ver) ~= "string" then
        return nil
    end
    if ver:match(SCRIPT_VERSION_PATTERN) then
        local x, _, z = ver:match("^(%d%d%d)%.(%d%d%d)%.(%d%d%d)$")
        local core = coreVersionNumber()
        if not core then
            return nil
        end
        return core .. "." .. x .. "." .. z
    end
    local coreInVer = ver:match("^(%d+)%.")
    local core = coreVersionNumber()
    if coreInVer and core and coreInVer == core and ver:match("^%d+%.%d%d%d%.%d%d%d$") then
        return ver
    end
    return nil
end

local function defaultFirmwareName()
    local bsp = rtos.bsp()
    if bsp:find("-") then
        bsp = bsp:sub(1, bsp:find("-") - 1)
    end
    return (_G.PROJECT or "PANSHI_CAT1") .. "_LuatOS-SoC_" .. bsp
end

local function defaultDeviceQuery()
    if mobile then
        return "imei=" .. mobile.imei()
    end
    if wlan and wlan.getMac then
        return "mac=" .. wlan.getMac()
    end
    return "uid=" .. mcu.unique_id():toHex()
end

local function isJsonBody(str)
    if type(str) ~= "string" then
        return false
    end
    local start = string.find(str, "^%{")
    local _, endPos = string.find(str, "%}$")
    return start == 1 and endPos == #str and string.sub(str, 2, #str - 1):find("%B{") == nil
end

local function logIotErrorBody(url, body)
    if not url or not string.find(url, IOT_HOST) then
        return
    end
    log.info(LOG_TAG, "合宙IoT响应解析")
    local jsonBody, ok = json.decode(body)
    local code
    if ok == 1 and isJsonBody(body) then
        code = jsonBody.code
    else
        log.info(LOG_TAG, "响应非JSON", type(body), body)
        return
    end
    local hint = IOT_ERR_HINT[code]
    if hint then
        log.info(LOG_TAG, "code", code, hint)
    else
        log.info(LOG_TAG, "code", code)
    end
end

local function fotaTask(cbFnc, opts)
    local ret = 0
    local code, _, body = http.request(
        opts.method,
        opts.url,
        opts.headers,
        opts.body,
        opts,
        opts.server_cert,
        opts.client_cert,
        opts.client_key,
        opts.client_password
    ).wait()

    if code == 200 or code == 206 then
        ret = (body == 0) and 4 or 0
    elseif code == -4 then
        ret = 1
    elseif code == -5 then
        ret = 3
    elseif code == 401 or code == 403 then
        log.error(LOG_TAG, "http fota", code, "合宙IoT无权限")
        logIotErrorBody(opts.url, body)
        ret = 3
    elseif code >= 300 then
        log.error(LOG_TAG, "http fota", code, "body", body)
        logIotErrorBody(opts.url, body)
        ret = 3
    else
        log.error(LOG_TAG, "http fota", code, "body", body)
        ret = 4
        logIotErrorBody(opts.url, body)
    end
    cbFnc(ret)
end

local function buildIotUpgradeUrl(opts)
    if not opts.project_key then
        opts.project_key = _G.PRODUCT_KEY
        if not opts.project_key then
            log.error(LOG_TAG, "need PRODUCT_KEY")
            return false
        end
    end

    if not opts.version then
        opts.version = _G.IOT_VERSION or _G.VERSION
    end

    local iotVer = resolveIotOtaVersion(opts.version)
    if not iotVer then
        log.error(LOG_TAG, "version 无效", opts.version)
        return false
    end
    if iotVer ~= opts.version then
        log.info(LOG_TAG, "IoT version", opts.version, "→", iotVer)
    end
    opts.version = iotVer

    if not opts.firmware_name then
        opts.firmware_name = defaultFirmwareName()
    end

    local query
    if opts.imei then
        opts.url = string.format(
            "%simei=%s&project_key=%s&firmware_name=%s&version=%s",
            opts.url, opts.imei, opts.project_key, opts.firmware_name, opts.version
        )
    else
        query = defaultDeviceQuery()
        opts.url = string.format(
            "%s%s&project_key=%s&firmware_name=%s&version=%s",
            opts.url, query, opts.project_key, opts.firmware_name, opts.version
        )
    end
    return true, query
end

--[[
fota 升级
@api libfota2.request(cbFnc, opts)
@function cbFnc 回调 cbFnc(result)；0=成功
@table opts 可选：url, version, project_key, firmware_name, imei, timeout, method 等
@return nil
]]
function libfota2.request(cbFnc, opts)
    opts = opts or {}
    if fota then
        opts.fota = true
    else
        os.remove("/update.bin")
        opts.dst = "/update.bin"
    end
    cbFnc = cbFnc or function() end

    if not opts.url then
        opts.url = IOT_UPGRADE_URL
    end

    local query = ""
    if opts.url:sub(1, 3) ~= "###" and not opts.url_done then
        local ok
        ok, query = buildIotUpgradeUrl(opts)
        if not ok then
            cbFnc(5)
            return
        end
    else
        opts.url = opts.url:sub(4)
    end

    opts.url_done = true
    opts.method = opts.method or "GET"

    log.info("libfota2.url", opts.method, opts.url)
    log.info("libfota2.project_key", opts.project_key)
    log.info("libfota2.firmware_name", opts.firmware_name)
    log.info("libfota2.version", opts.version)
    if query ~= "" then
        log.info("libfota2.imei/mac/uid", query)
    end

    sys.taskInit(fotaTask, cbFnc, opts)
end

return libfota2
