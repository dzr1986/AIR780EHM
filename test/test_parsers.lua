-- 宿主机等价性测试：从 host_uart.lua 提取 DSL 与解析器定义，对比预期发布结果
-- 用法: lua5.3 /tmp/test_parsers.lua /workspaces/AIR780EHM/user/host_uart.lua
local src_path = arg[1]
local f = assert(io.open(src_path))
local src = f:read("a")
f:close()

-- 沙盒环境
local published = {}
local state = {}
local env = {
	state = state,
	sys = { publish = function(ev, val) published[#published + 1] = { ev = ev, val = val } end },
	SYS_EVT = setmetatable({}, { __index = function(_, k) return "EVT_" .. k end }),
	string = string, tonumber = tonumber, tostring = tostring, pairs = pairs, type = type,
	parse_venc_row = function(l) return l:match("^%+VENC:(%d+)") and { raw = l } or nil end,
	parse_audio_row = function(l) return l:match("^%+AUDIO:(%d+)") and { raw = l } or nil end,
}
env._G = env

-- 提取代码段: normalize_host_line + DSL 助手 + 各 try_* 定义
-- 定界方式: 起点 marker 到下一个已知函数/变量起点, 避免 Lua pattern 不跨行的限制
local function extract_between(start_marker, end_marker, name)
	local s = src:find(start_marker, 1, true)
	assert(s, "no start for " .. name)
	local e = src:find(end_marker, s + #start_marker, true)
	assert(e, "no end for " .. name)
	return src:sub(s, e - 1)
end
local chunks = {
	extract_between("local function normHostLine", "local function parse_recordtime_line", "normHostLine"),
	extract_between("-- 行解析 DSL", "local function try_encode_uart_error", "dsl"),
	extract_between("local try_venc_line = norm_matchers", "local try_vencset_line", "try_venc_line"),
}
-- try_vencset/audioset/micset/mic/softphoto(set)/framerate/recordctrl/persondet
local function extract_def(name)
	local s = src:find("local " .. name .. " = ", 1, true)
	assert(s, "no start for " .. name)
	local pos = s
	while true do
		local e = src:find("%)%)", pos)
		assert(e, "no end for " .. name)
		local candidate = src:sub(s, e + 1)
		if load(candidate, name, "t", {}) then
			return candidate
		end
		pos = e + 2
	end
end
for _, name in ipairs({ "try_vencset_line", "try_audioset_line", "try_audio_line", "try_micset_line", "try_mic_line",
	"try_softphotoset_line", "try_softphoto_line", "try_framerate_line", "try_recordctrl_line", "try_persondet_line" }) do
	chunks[#chunks + 1] = extract_def(name)
end
chunks[#chunks + 1] = [[
return {
	vencset = try_vencset_line, audioset = try_audioset_line, micset = try_micset_line,
	mic = try_mic_line, softphotoset = try_softphotoset_line, softphoto = try_softphoto_line,
	framerate = try_framerate_line, recordctrl = try_recordctrl_line, persondet = try_persondet_line,
	venc = try_venc_line, audio = try_audio_line,
}
]]
local code = table.concat(chunks, "\n")
local fn = assert(load(code, "parsers", "t", env))
local P = fn()

local failures = 0
local function check(desc, cond)
	if not cond then
		failures = failures + 1
		print("FAIL: " .. desc)
	end
end
local function last()
	return published[#published]
end
local function reset()
	published = {}
	env.sys.publish = function(ev, val) published[#published + 1] = { ev = ev, val = val } end
	for k in pairs(state) do state[k] = nil end
end

-- vencset
reset()
check("vencset nil", P.vencset(nil) == false)
check("vencset err", P.vencset("+VENCSET:ERROR") and last().val.ok == false and last().ev == "EVT_VENC_SET")
check("vencset ok4", P.vencset("+VENCSET:OK,cam=1,stream=2,needReboot=1,runtimeApply=0"))
local v = last().val
check("vencset ok4 fields", v.ok == true and v.camera == 1 and v.stream == 2 and v.needReboot == true and v.runtimeApply == 0)
check("vencset ok3", P.vencset("+VENCSET:OK,cam=0,stream=1,needReboot=0"))
v = last().val
check("vencset ok3 fields", v.ok == true and v.camera == 0 and v.needReboot == false and v.runtimeApply == nil)
check("vencset no match", P.vencset("+VENCSET:WHAT") == false)

-- audioset
check("audioset ok", P.audioset("+AUDIOSET:OK,cam=0,needReboot=1"))
v = last().val
check("audioset fields", v.ok == true and v.camera == 0 and v.needReboot == true)

-- micset
check("micset ok", P.micset("+MICSET:OK,cam=0,runtimeApply=1"))
v = last().val
check("micset fields", v.ok == true and v.camera == 0 and v.runtimeApply == 1)
check("micset err", P.micset("+MICSET:ERROR") and last().val.ok == false)

-- mic rows
reset()
check("mic row1", P.mic(" +MIC:0,80,28 "))
check("mic row1 state", state.mic_rows and #state.mic_rows == 1 and state.mic_rows[1].volume == 80 and state.mic_rows[1].gain == 28)
check("mic row2", P.mic("+MIC:1,50,10"))
check("mic end", P.mic("+MIC:END"))
check("mic end pub", last().ev == "EVT_MIC_QUERY" and #last().val == 2 and last().val[2].camera == 1)
check("mic state cleared", state.mic_rows == nil)
-- 无收集行时 END 不发布(rowsEndFlus 语义,与 venc/audio/framerate 一致)
check("mic end empty", P.mic("+MIC:END") == false)

-- softphoto
reset()
check("softphoto q", P.softphoto("+SOFTPHOTO:1,20,30,40,50,60,7,8"))
v = last().val
check("softphoto fields", v.enable == 1 and v.nightModeThreshold == 20 and v.dayModeThreshold == 30
	and v.dayModeAltThreshold == 40 and v.gbGainThreshold == 50 and v.gbGainRecordInit == 60
	and v.checkTime == 7 and v.checkCount == 8 and v.parsed == true)
check("softphoto err", P.softphoto("+SOFTPHOTO:ERROR") and last().val.parsed == false and last().val.error == true)
check("softphotoset ok", P.softphotoset("+SOFTPHOTOSET:OK") and last().val.ok == true)

-- framerate
reset()
check("fr row", P.framerate("+FRAMERATE:0,1,25"))
check("fr row state", state.framerate_rows[1].framerate == 25)
check("fr end", P.framerate("+FRAMERATE:END") and last().ev == "EVT_FRAMERATE_QUERY")
check("fr set4", P.framerate("+FRAMERATE:OK,0,1,30,runtimeApply=1"))
v = last().val
check("fr set4 fields", v.ok == true and v.framerate == 30 and v.runtimeApply == 1 and last().ev == "EVT_FRAMERATE_SET")
check("fr set3", P.framerate("+FRAMERATE:OK,0,1,15"))
v = last().val
check("fr set3 default runtimeApply", v.runtimeApply == 1 and v.framerate == 15)
check("fr err", P.framerate("+FRAMERATE:ERROR") and last().val.ok == false and last().val.error == true)

-- recordctrl
check("rc start", P.recordctrl("+RECORDCTRL:OK,1,max_sec=90"))
v = last().val
check("rc start fields", v.ok == true and v.start == 1 and v.max_sec == 90)
check("rc stop", P.recordctrl("+RECORDCTRL:OK,0,reason=tfcard_format"))
v = last().val
check("rc stop reason string", v.start == 0 and v.reason == "tfcard_format")
check("rc stop bare", P.recordctrl("+RECORDCTRL:OK,0"))
v = last().val
check("rc stop bare fields", v.ok == true and v.start == 0)
check("rc stop empty reason", P.recordctrl("+RECORDCTRL:OK,0,reason="))
v = last().val
check("rc stop empty reason fields", v.ok == true and v.start == 0)
check("rc err", P.recordctrl("+RECORDCTRL:ERROR") and last().val.ok == false)
check("rc no match", P.recordctrl("+RECORDCTRL:OK,9") == false)

-- persondet
reset()
check("pd q2", P.persondet("+PERSONDET:1,available=1"))
check("pd q2 state", state.host_person_detect.enable == 1 and state.host_person_detect.available == 1 and state.host_person_detect.parsed == true)
check("pd q2 pub", last().ev == "EVT_PERSONDET_ACK" and last().val == state.host_person_detect)
check("pd q1", P.persondet("+PERSONDET:0"))
check("pd q1 state", state.host_person_detect.enable == 0 and state.host_person_detect.available == nil)
check("pd set ok", P.persondet("+PERSONDET:OK,1") and last().ev == "EVT_PERSONDET_SET" and last().val.enable == 1 and last().val.ok == true)
check("pd err", P.persondet("+PERSONDET:ERROR") and last().val.ok == false)

-- venc/audio rows via external parser
reset()
check("venc row", P.venc("+VENC:0,stuff"))
check("venc row state", state.encode_venc_rows and #state.encode_venc_rows == 1)
check("venc end", P.venc("+VENC:END") and last().ev == "EVT_VENC_QUERY" and #last().val == 1)
check("audio row", P.audio("+AUDIO:0,x") and state.encode_audio_rows and #state.encode_audio_rows == 1)
check("audio end", P.audio("+AUDIO:END") and last().ev == "EVT_AUDIO_QUERY")

-- flag 表独立性（多次 ERROR 发布的表互不共享）
reset()
P.vencset("+VENCSET:ERROR")
local t1 = last().val
P.vencset("+VENCSET:ERROR")
local t2 = last().val
check("flag tables independent", t1 ~= t2)

if failures == 0 then
	print("ALL PARSER TESTS PASSED")
else
	print(failures .. " FAILURES")
	os.exit(1)
end
