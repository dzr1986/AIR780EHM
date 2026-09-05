-- 护栏单测样本：顶层 local 声明晚于使用（赋值落成全局）
local function resetZz()
    zzLateOwner = nil
end
local zzLateOwner = nil
return resetZz
