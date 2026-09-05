-- 护栏单测样本：读未定义全局（拼写错误形态）
local function zz(r)
    return tonumber(r.x) or LIMITMO_SHARED_ZZ.missThreshold
end
