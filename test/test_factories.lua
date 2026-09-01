-- 验证 defineQuery/defineSet 工厂字段映射（真源：user/hu_ipc.lua）
local src = assert(io.open(arg[1])):read("a")
local captured = {}
local env = {
    type = type, tonumber = tonumber, tostring = tostring, string = string,
    cachedQry = function(tmo, opts) captured = { tmo = tmo, opts = opts }; return "QR" end,
    hostSet = function(spec) captured = { spec = spec }; return true, "ok", { x = 1 } end,
    parseOk = function() end,
}
env._G = env
local function extract_between(s, e, name)
    local a = src:find(s, 1, true)
    assert(a, "no start for " .. name)
    local b = src:find(e, a + #s, true)
    assert(b, "no end for " .. name)
    return src:sub(a, b - 1)
end
local body = extract_between("local function defineQuery", "local function defineSet", "defineQuery") ..
    "\n" .. extract_between("local function defineSet", "local H = {", "defineSet") ..
    "\nreturn defineQuery, defineSet"
local defineQuery, defineSet = assert(load(body, "f", "t", env))()

local fails = 0
local function check(d, c) if not c then fails = fails + 1 print("FAIL " .. d) end end

local identityCfg = function() return { marker = 1 } end
local q = defineQuery{
    busyKey = "b", cacheKey = "c", requireParsed = true, policyTag = "t", cfg = identityCfg,
    timeout = 3000, atCmd = "AT+X?", ackEvent = "EV", whenDisabled = "DIS",
    beforeSend = "PRE", onResponse = "RSP",
}
check("q ret", q(1234) == "QR")
check("q tmo", captured.tmo == 1234)
local o = captured.opts
check("q map", o.busyKey == "b" and o.cacheKey == "c" and o.requireParsed == true and o.policyTag == "t"
    and o.cfg.marker == 1 and o.defaultTimeout == 3000 and o.atCmd == "AT+X?" and o.ackEvent == "EV"
    and o.whenDisabled == "DIS" and o.beforeSend == "PRE" and o.onResponse == "RSP")

local q2 = defineQuery{
    cfg = identityCfg, ackEvent = "EV2",
    atCmd = function(op) return op.camera and ("AT+M?=" .. op.camera) or "AT+M?" end,
}
q2({ timeoutMs = 55, camera = 2 })
check("q2 tmo from opts", captured.tmo == 55)
check("q2 dyn at", captured.opts.atCmd == "AT+M?=2")
q2(nil)
check("q2 nil arg", captured.tmo == nil and captured.opts.atCmd == "AT+M?")
q2(77)
check("q2 num arg", captured.tmo == 77 and captured.opts.atCmd == "AT+M?")

local recCfg = function() return { rc = 1 } end
local prepped
local s = defineSet{
    busyKey = "sb", policyTag = "st", cfg = identityCfg, bootCfg = recCfg,
    timeout = 8000, ackEvent = "SEV",
    prepare = function(op) prepped = op; return true, nil, "AT+S=1" end,
    parseRsp = "PARSE",
}
local ok, msg, extra = s({ timeoutMs = 99, minutes = 5 })
check("s ret", ok == true and msg == "ok" and extra.x == 1)
local sp = captured.spec
check("s map", sp.busyKey == "sb" and sp.policyTag == "st" and sp.cfg.marker == 1 and sp.bootCfg.rc == 1
    and sp.defaultTimeout == 8000 and sp.timeoutMs == 99 and sp.ackEvent == "SEV" and sp.parseRsp == "PARSE")
sp.prepare()
check("s prep opts", prepped.minutes == 5)

local s2 = defineSet{ cfg = identityCfg, ackEvent = "E", prepare = function() return true, nil, "AT" end }
s2(nil)
check("s2 default parse", captured.spec.parseRsp ~= nil and captured.spec.bootCfg == nil and captured.spec.busyKey == nil)

print(fails == 0 and "ALL FACTORY TESTS PASSED" or (fails .. " FAILURES"))
os.exit(fails == 0 and 0 or 1)
