-- 验证 defineQuery/defineSet 工厂字段映射与双签名兼容
local src = assert(io.open(arg[1])):read("a")
local captured = {}
local env = {
	type = type, tonumber = tonumber, tostring = tostring, string = string,
	cached_host_query = function(tmo, opts) captured = { tmo = tmo, opts = opts }; return "QR" end,
	host_set = function(spec) captured = { spec = spec }; return true, "ok", { x = 1 } end,
	parse_ok_rsp = function() end,
}
env._G = env
-- 定界提取(起点 marker 到下一个定义起点), 避免 Lua pattern 不跨行的限制
local function extract_between(s, e, name)
	local a = src:find(s, 1, true)
	assert(a, "no start for " .. name)
	local b = src:find(e, a + #s, true)
	assert(b, "no end for " .. name)
	return src:sub(a, b - 1)
end
local body = extract_between("local function defineQuery", "local function defineSet", "defineQuery") ..
	"\n" .. extract_between("local function defineSet", "function getCachedHostGb28181Id", "defineSet") ..
	"\nreturn defineQuery, defineSet"
local defineQuery, defineSet = assert(load(body, "f", "t", env))()

local fails = 0
local function check(d, c) if not c then fails = fails + 1 print("FAIL " .. d) end end

local identity_cfg = function() return { marker = 1 } end
local q = defineQuery{ busy = "b", cache = "c", parsed = true, tag = "t", cfg = identity_cfg,
	tmo = 3000, at = "AT+X?", ev = "EV", dis = "DIS", pre = "PRE", rsp = "RSP" }
-- timeoutMs 签名
check("q ret", q(1234) == "QR")
check("q tmo", captured.tmo == 1234)
local o = captured.opts
check("q map", o.busy_key == "b" and o.cache_key == "c" and o.require_parsed == true and o.policy_tag == "t"
	and o.cfg.marker == 1 and o.default_timeout == 3000 and o.at_cmd == "AT+X?" and o.ack_event == "EV"
	and o.when_disabled == "DIS" and o.before_send == "PRE" and o.on_response == "RSP")
-- opts 签名 + 动态 at
local q2 = defineQuery{ cfg = identity_cfg, ev = "EV2",
	at = function(op) return op.camera and ("AT+M?=" .. op.camera) or "AT+M?" end }
q2({ timeout_ms = 55, camera = 2 })
check("q2 tmo from opts", captured.tmo == 55)
check("q2 dyn at", captured.opts.at_cmd == "AT+M?=2")
q2(nil)
check("q2 nil arg", captured.tmo == nil and captured.opts.at_cmd == "AT+M?")
q2(77)
check("q2 num arg", captured.tmo == 77 and captured.opts.at_cmd == "AT+M?")

-- defineSet
local record_cfg = function() return { rc = 1 } end
local prepped
local s = defineSet{ busy = "sb", tag = "st", cfg = identity_cfg, boot = record_cfg,
	tmo = 8000, ev = "SEV", prep = function(op) prepped = op; return true, nil, "AT+S=1" end, parse = "PARSE" }
local ok, msg, extra = s({ timeout_ms = 99, minutes = 5 })
check("s ret", ok == true and msg == "ok" and extra.x == 1)
local sp = captured.spec
check("s map", sp.busy_key == "sb" and sp.policy_tag == "st" and sp.cfg.marker == 1 and sp.boot_cfg.rc == 1
	and sp.default_timeout == 8000 and sp.timeout_ms == 99 and sp.ack_event == "SEV" and sp.parse_rsp == "PARSE")
sp.prepare()
check("s prep opts", prepped.minutes == 5)
-- 默认 parse 与 nil opts
local s2 = defineSet{ cfg = identity_cfg, ev = "E", prep = function() return true, nil, "AT" end }
s2(nil)
check("s2 default parse", captured.spec.parse_rsp ~= nil and captured.spec.boot_cfg == nil and captured.spec.busy_key == nil)

print(fails == 0 and "ALL FACTORY TESTS PASSED" or (fails .. " FAILURES"))
os.exit(fails == 0 and 0 or 1)
