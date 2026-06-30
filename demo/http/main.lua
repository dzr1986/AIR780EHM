--[[
@module  main
@summary HTTP GET 请求示例 / HTTP GET request demo
@version 1.0
@date    2026.06.30
@usage
本 demo 演示 LuatOS HTTP 功能：
  - 等待网络就绪
  - 向公共 API 发起 HTTP GET 请求
  - 打印响应状态码和响应体
]]

PROJECT = "AIR780EHM_http"
VERSION = "001.999.001"

log.info("main", PROJECT, VERSION)

-- 等待网络连接就绪后发起请求
sys.taskInit(function()
    -- 等待移动网络注册成功
    sys.waitUntil("IP_READY", 60000)
    log.info("http", "network ready, sending HTTP GET request...")

    -- 发起 GET 请求（使用合宙提供的测试接口）
    local code, headers, body = http.request(
        "GET",
        "http://httpbin.luat.com/get?source=air780ehm",
        nil,
        nil,
        { timeout = 10000 }
    ).wait()

    if code == 200 then
        log.info("http", "response code:", code)
        log.info("http", "response body:", body)
    else
        log.error("http", "request failed, code:", code)
    end
end)

sys.run()
