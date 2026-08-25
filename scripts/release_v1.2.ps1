# 780EHM_PJ v1.2 打包 + Git 提交 + 标签
# 用法（PowerShell，在仓库根目录）:
#   .\scripts\release_v1.2.ps1
# 若磁盘满，请先删除旧 zip 再执行。

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $Root ".git"))) {
    throw "Not a git repo: $Root"
}
Set-Location $Root
Write-Host "Repo: $Root"

$ZipName = "780EHM_PJ_v1.2_20260602.zip"
$ZipPath = Join-Path $Root $ZipName

# 删除旧备份 zip 释放空间（可选）
Get-ChildItem -Path $Root -Filter "780EHM_PJ_*.zip" -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "Remove old zip:" $_.Name
    Remove-Item $_.FullName -Force
}

$TempDir = Join-Path $env:TEMP "780EHM_PJ_v1.2_pack"
if (Test-Path $TempDir) { Remove-Item $TempDir -Recurse -Force }
New-Item -ItemType Directory -Path $TempDir | Out-Null

$Include = @("user", "lib", "doc", "cat1_host", "luatos.json", "README.md", "scripts")
foreach ($item in $Include) {
    $src = Join-Path $Root $item
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination (Join-Path $TempDir $item) -Recurse -Force
    }
}

if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
Compress-Archive -Path (Join-Path $TempDir "*") -DestinationPath $ZipPath -Force
Remove-Item $TempDir -Recurse -Force
Write-Host "Zip:" $ZipPath "(" ([math]::Round((Get-Item $ZipPath).Length / 1MB, 2)) "MB)"

git add user lib doc cat1_host luatos.json README.md scripts
git add -u
git status --short

$msg = @"
Release v1.2: 蜂窝联通 APN、CAT1-T31 时间同步、电量/USB/T31 逻辑文档。

- lib/cellular_bootstrap.lua: 运营商识别与入网重试
- user/time_sync.lua, host_uart AT+TIMESET/TIME?
- cat1_host time_sync; doc POWER_USB_BATTERY_T31_LOGIC, LOW_BATTERY §9-10
- MQTT 1005 operator 字段; MODULE_FLAGS.cellular
"@

# 使用与历史提交一致的作者（避免本机未配置 git user 时 commit 失败）
$gitUser = "dzr1986"
$gitEmail = "dzr1986@users.noreply.local"
git -c "user.name=$gitUser" -c "user.email=$gitEmail" commit -m $msg
git tag -d v1.2 2>$null
git -c "user.name=$gitUser" -c "user.email=$gitEmail" tag -a v1.2 -m "v1.2 backup: cellular, time-sync, battery-usb-t3x docs"
Write-Host "Done. tag=v1.2"
git log -1 --oneline
git tag -l "v1.2"
