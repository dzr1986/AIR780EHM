





local _modname = ...
local _G_direct = _ENV
_G_direct[_modname] = _G_direct[_modname] or {}
module(_modname, package.seeall)
_G[_modname] = _M





function mergeTable(target, source)
if type(source) ~= "table" then
return target
end
for key, value in pairs(source) do
if type(value) == "table" and type(target[key]) == "table" then
mergeTable(target[key], value)
elseif value ~= nil then
target[key] = value
end
end
return target
end





function mergeConfig(target, source)
if type(source) ~= "table" then
return target
end
for key, value in pairs(source) do
if value ~= nil then
target[key] = value
end
end
return target
end




function resolve(value)
if type(value) == "function" then
return value()
end
return value
end





function pickTable(value, fallback)
return type(value) == "table" and value or (fallback or {})
end




function pickFirst(...)
local result = {}
local args = {...}
for i = #args, 1, -1 do
local src = args[i]
if type(src) == "table" then
mergeConfig(result, src)
end
end
return result
end

return _M
