-- ================================================================
-- Filename : libfota2.lua
-- Module   : FOTA 下载引擎：合宙差分升级协议、HTTP(S)、断点续传、校验写盘
-- Arch     : 见 doc/LUA_MODULES.md
-- ================================================================

local libfota2 = {}

local function isjson(str)
    local start, _ = string.find(str, "^%{")
    local _, end_ = string.find(str, "%}$")
    return start == 1 and end_ == #str and string.sub(str, 2, #str - 1):find("%B{") == nil
end

-- 云平台错误码 → log 文案（键为 hziot 返回 code；特殊分支见 fota_task）
local FOTA_ERR_INFO = {
    [43] = { "请等待", "云平台生成差分包需1-3分钟,稍后重试" },
    [3] = { "无效的设备", "检查请求键名(imei小写)正确性" },
    [17] = { "无权限", "设备imei/固件/项目key需在同一账户下,可联系合宙技术支持核实修改归属" },
    [21] = { "不允许升级", "检查IOT平台该imei是否被禁止升级" },
    [25] = { "无效的项目", "productkey不一致或设备不在本人账户下,请联系合宙处理" },
    [26] = { "无效的固件", "固件名称错误或项目无对应固件,对照升级日志中设备当前固件名与配置固件名" },
    [27] = { "已是最新版本", "固件/脚本已是最新,或项目未添加该设备,或升级配置为否" },
    [40] = { "循环升级", "解除该imei的禁止升级;一天请求超6次会被平台禁止" },
}

local function fota_task(cbFnc, opts)
    local ret = 0
    local url = opts.url
    local code, headers, body = http.request(opts.method, opts.url, opts.headers, opts.body, opts, opts.server_cert,
                                    opts.client_cert, opts.client_key, opts.client_password).wait()
    if string.find(url, "iot.openluat.com") and type(code) == "number" and code < 0 and url:sub(1, 7) == "http://" then
        local retry_url = "https://" .. url:sub(8)
        log.info("libfota2", "retry_https", retry_url)
        opts.url = retry_url
        url = retry_url
        code, headers, body = http.request(opts.method, opts.url, opts.headers, opts.body, opts, opts.server_cert,
                                    opts.client_cert, opts.client_key, opts.client_password).wait()
    end
    -- log.info("http fota", code, headers, body)
    if code == 200 or code == 206 then
        if body == 0 then
            ret = 4
        else
            ret = 0
        end
    elseif code == -4 then
        ret = 1
    elseif code == -5 then
        ret = 3
    else
        ret = 4
        local hziot = "iot.openluat.com"
        local msg, json_body, result
        if string.find(url, hziot) then
            if type(body) == "string" and body ~= "" then
                json_body, result = json.decode(body)
            else
                result = 0
            end
            -- 如果json解析失败，证明服务器下发的不是json
            if result == 1 and type(body) == "string" and isjson(body) then
                code = json_body["code"]
            else
                -- 这个值随便取的，只要不和其他定义重复就行
                code = 1111111111111
            end
            local info = FOTA_ERR_INFO[code]
            if info then
                log.info(info[1], info[2])
            elseif code == 1111111111111 then
                log.info("云平台下发的不是json", "我看看body是个什么东西", type(body), body)
            else
                log.info("不是上面的那些错误code", code)
            end
        end
    end

    cbFnc(ret)
end

--[[
fota升级
@api libfota2.request(cbFnc, opts)
@function cbFnc 用户回调函数，回调函数的调用形式为：cbFnc(result) , 必须传
@table fota参数, 后面有详细描述
@return nil 无返回值
@usaga

-- opts参数说明, 所有参数都是可选的
-- 1. opts.url string 升级所需要的URL, 若使用合宙iot平台,则不需要填
-- 2. opts.version string 版本号, 默认是 BSP版本号.x.z格式
-- 3. opts.timeout int 请求超时时间, 默认300000毫秒,单位毫秒
-- 4. opts.project_key string 合宙IOT平台的项目key, 默认取全局变量PRODUCT_KEY. 自建服务器不用填
-- 5. opts.imei string 设备识别码, 默认取IMEI(Cat.1模块)或WLAN MAC地址(wifi模块)或MCU唯一ID
-- 6. opts.firmware_name string 固件名称,默认是 _G.PROJECT.. "_LuatOS-SoC_" .. rtos.bsp()
-- 7. opts.server_cert string 服务器证书, 默认不使用
-- 8. opts.client_cert string 客户端证书, 默认不使用
-- 9. opts.client_key string 客户端私钥, 默认不使用
-- 10. opts.client_password string 客户端私钥口令, 默认不使用
-- 11. opts.method string 请求方法, 默认是GET
-- 12. opts.headers table 额外添加的请求头,默认不需要
-- 13. opts.body string 额外添加的请求body,默认不需要
]]
function libfota2.request(cbFnc, opts)
    if not opts then
        opts = {}
    end
    if fota then
        opts.fota = true
    else
        os.remove("/update.bin")
        opts.dst = "/update.bin"
    end
    if not cbFnc then
        cbFnc = function(ret)
        end
    end
    -- 处理URL
    if not opts.url then
        opts.url = "https://iot.openluat.com/api/site/firmware_upgrade?"
    end
    local query = ""
    if opts.url:sub(1, 3) ~= "###" and not opts.url_done then
        -- 补齐project_key函数
        if not opts.project_key then
            opts.project_key = _G.PRODUCT_KEY
            if not opts.project_key then
                log.error("libfota2", "iot.openluat.com need PRODUCT_KEY!!!")
                cbFnc(5)
                return
            end
        end
        -- 补齐version参数
        if not opts.version then
            local x, y, z = string.match(_G.VERSION, "(%d+).(%d+).(%d+)")
            opts.version = rtos.version():sub(2) .. "." .. x .. "." .. z
        end
        -- 补齐firmware_name参数
        if not opts.firmware_name then
            local bsp = rtos.bsp()
            -- 如bsp包含'-', 就截取'-'前面的部分, 例如"air105-evb"就取"air105"
            if bsp:find("-") then
                bsp = bsp:sub(1, bsp:find("-") - 1)
            end
            opts.firmware_name = _G.PROJECT .. "_LuatOS-SoC_" .. bsp
        end
        -- 补齐imei参数
        if not opts.imei then
            if mobile then
                query = "imei=" .. mobile.imei()
            elseif wlan and wlan.getMac() then
                query = "mac=" .. wlan.getMac()
            else
                query = "uid=" .. mcu.unique_id():toHex()
            end
        end

        -- 然后拼接到最终的url里
        if not opts.imei then
            opts.url = string.format("%s%s&project_key=%s&firmware_name=%s&version=%s", opts.url, query, opts.project_key, opts.firmware_name, opts.version)
        else
            opts.url = string.format("%simei=%s&project_key=%s&firmware_name=%s&version=%s", opts.url, opts.imei, opts.project_key, opts.firmware_name, opts.version)
        end
    else
        if opts.url:sub(1,3)=="###" then
            opts.url = opts.url:sub(4)
        end
    end
    opts.url_done = true
    -- 处理method
    if not opts.method then
        opts.method = "GET"
    end
    log.info("libfota2", "url", opts.method, opts.url, "q", query, "pk", opts.project_key,
             "fn", opts.firmware_name, "ver", opts.version)
    sys.taskInit(fota_task, cbFnc, opts)
end

return libfota2
