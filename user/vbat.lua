require "sys"
require "config"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local LOG_TAG = "battery_adc"
local BUILD_TAG = "v4-filter"
local taskStarted = false
local voltageMv, percent, consumptionRate = 0, 0, 0
local lastPercent, lastReadTime
local filteredMv, stablePercent
local function getCfg()
	return _G.BATTERY_CFG or {}
end
local function getAdcCfg()
	return getCfg().adc or {}
end
local function getCellCfg()
	return getCfg().cell or {}
end
local function getFilterCfg()
	return getCfg().filter or {}
end
local function sampleIntervalMs()
	return getCfg().sample_interval_ms or (10 * 1000)
end
local function resolveMvScale()
	local adcCfg = getAdcCfg()
	local scale
	local s = tonumber(adcCfg.mv_scale)
	if s and s > 1 then
		scale = s
	else
		local div = adcCfg.divider
		if type(div) == "table" then
			local r = tonumber(div.r_kohm)
			local rx = tonumber(div.rx_kohm)
			if r and rx and rx > 0 then
				scale = (r + rx) / rx
			else
				scale = 1510 / 510
			end
		else
			scale = 1510 / 510
		end
	end
	local cal = tonumber(adcCfg.mv_calibration)
	if cal and cal > 0 then
		scale = scale * cal
	end
	return scale
end
local function pinToCellMv(pinMv, scale)
	return math.floor(pinMv * scale + 0.5)
end
local function percentFromCellMv(cellMv)
	local vmax = tonumber(getCellCfg().v_max_mv) or 4200
	local vmin = tonumber(getCellCfg().v_min_mv) or 3000
	if cellMv >= vmax then
		return 100
	end
	if cellMv <= vmin then
		return 1
	end
	local step = (vmax - vmin) / 100
	local p = (cellMv - vmin) / step
	if p < 1 then
		p = 1
	end
	return math.floor(p)
end
local function trimmedMean(samples)
	local drop = tonumber(getFilterCfg().trim_drop) or 2
	local n = #samples
	if n == 0 then
		return nil
	end
	table.sort(samples)
	if n <= drop * 2 + 1 then
		local sum = 0
		for i = 1, n do
			sum = sum + samples[i]
		end
		return math.floor(sum / n + 0.5)
	end
	local sum, c = 0, 0
	for i = drop + 1, n - drop do
		sum = sum + samples[i]
		c = c + 1
	end
	return math.floor(sum / c + 0.5)
end
local function smoothCellMv(rawCellMv)
	local fc = getFilterCfg()
	local alpha = tonumber(fc.ema_alpha)
	if alpha == nil or alpha <= 0 or alpha > 1 then
		alpha = 0.35
	end
	local maxStep = tonumber(fc.mv_max_step) or 35
	if filteredMv == nil then
		filteredMv = rawCellMv
		return filteredMv
	end
	local target = math.floor(rawCellMv * alpha + filteredMv * (1 - alpha) + 0.5)
	local diff = target - filteredMv
	if maxStep > 0 and math.abs(diff) > maxStep then
		if diff > 0 then
			target = filteredMv + maxStep
		else
			target = filteredMv - maxStep
		end
	end
	filteredMv = target
	return filteredMv
end
local function smoothPercent(cellMv, rawPct)
	local fc = getFilterCfg()
	local vmax = tonumber(getCellCfg().v_max_mv) or 4200
	local hystHigh = tonumber(fc.percent_hyst_high_mv)
	if hystHigh == nil then
		hystHigh = vmax - 80
	end
	local maxStep = tonumber(fc.percent_max_step) or 2
	local pct = rawPct
	if stablePercent == nil then
		stablePercent = pct
		return pct
	end
	if stablePercent >= 100 then
		if cellMv < hystHigh then
			pct = percentFromCellMv(cellMv)
		else
			pct = 100
		end
	elseif rawPct >= 100 and cellMv >= vmax then
		pct = 100
	end
	local diff = pct - stablePercent
	if maxStep > 0 and math.abs(diff) > maxStep then
		if diff > 0 then
			pct = stablePercent + maxStep
		else
			pct = stablePercent - maxStep
		end
	end
	pct = math.floor(pct)
	if pct < 1 then
		pct = 1
	end
	if pct > 100 then
		pct = 100
	end
	stablePercent = pct
	return pct
end
local function updateConsumptionRate(currentPercent)
	local rate = 0
	local now = os.time()
	if lastPercent and lastReadTime then
		local hours = (now - lastReadTime) / 3600
		local diff = lastPercent - currentPercent
		if hours > 0 and diff > 0 then
			rate = math.floor((diff / hours) * 10 + 0.5) / 10
		end
	end
	lastPercent = currentPercent
	lastReadTime = now
	return rate
end
local function exportGlobals(pct, cellMv, rate)
	local rt = _G.APP_RUNTIME
	if not rt then
		return
	end
	rt.battery_percent = pct
	rt.battery_mv = cellMv
	rt.battery_consumption_rate = tostring(rate or 0)
end
local function getChannel()
	local c = getAdcCfg().channel
	if c == nil then
		c = 1
	end
	return c
end
local function applyAdcRange(ad)
	if not ad or not ad.setRange then
		return
	end
	local range = getAdcCfg().range
	if range == nil and ad.ADC_RANGE_MIN then
		range = ad.ADC_RANGE_MIN
	end
	if range ~= nil then
		ad.setRange(range)
	end
end
local function readPinOnce(ad, channel)
	if ad.read then
		local _, mv = ad.read(channel)
		if mv ~= nil and mv >= 0 then
			return mv
		end
	end
	if ad.get then
		local mv = ad.get(channel)
		if mv ~= nil and mv >= 0 then
			return mv
		end
	end
	return nil
end
local function readPinMillivolts(ad, channel)
	local fc = getFilterCfg()
	local count = tonumber(fc.sample_count) or 11
	local spacing = tonumber(fc.sample_spacing_ms) or 20
	local samples = {}
	local i
	for i = 1, count do
		local mv = readPinOnce(ad, channel)
		if mv ~= nil then
			samples[#samples + 1] = mv
		end
		if i < count and spacing > 0 then
			sys.wait(spacing)
		end
	end
	if #samples == 0 then
		return nil
	end
	return trimmedMean(samples)
end
local function batteryTask()
	if not adc or not adc.open then
		return
	end
	local channel = getChannel()
	applyAdcRange(adc)
	adc.open(channel)
	local scale = resolveMvScale()
	while true do
		local pinMv = readPinMillivolts(adc, channel)
		if pinMv then
			local rawMv = pinToCellMv(pinMv, scale)
			local cellMv = smoothCellMv(rawMv)
			local vmax = tonumber(getCellCfg().v_max_mv) or 4200
			if cellMv > vmax then
				cellMv = vmax
			end
			local rawPct = percentFromCellMv(cellMv)
			local pct = smoothPercent(cellMv, rawPct)
			voltageMv = cellMv
			percent = pct
			consumptionRate = updateConsumptionRate(percent)
			exportGlobals(percent, voltageMv, consumptionRate)
			sys.publish("BATTERY_UPDATE", percent, voltageMv, consumptionRate)
		end
		sys.wait(sampleIntervalMs())
	end
end
function start()
	if taskStarted then
		return false
	end
	taskStarted = true
	sys.taskInit(batteryTask)
	return true
end
function getVoltage()
	return voltageMv
end
function getPercent()
	return percent
end
function getConsumptionRate()
	return consumptionRate
end
function getState()
	return {
		started = taskStarted,
		build = BUILD_TAG,
		config = getCfg(),
		sample_ms = sampleIntervalMs(),
		mv_scale = resolveMvScale(),
		voltage = voltageMv,
		percent = percent,
		consumptionRate = consumptionRate,
		filtered_mv = filteredMv,
		stable_percent = stablePercent,
	}
end
return _M
