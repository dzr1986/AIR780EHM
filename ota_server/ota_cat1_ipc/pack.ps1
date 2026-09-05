# 从当前 ota_server 打一份「只有网站、没有升级数据」的部署包到 ota_cat1_ipc\site
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Dest = Join-Path $PSScriptRoot "site"

if (Test-Path $Dest) {
    Remove-Item -Recurse -Force $Dest
}
New-Item -ItemType Directory -Path $Dest | Out-Null

function Copy-Tree($rel) {
    $src = Join-Path $Root $rel
    $dst = Join-Path $Dest $rel
    if (-not (Test-Path $src)) { return }
    New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
    Copy-Item -Recurse -Force $src $dst
}

Copy-Tree "src"
Copy-Tree "ipc_upgrade\x86demo"
Copy-Item -Force (Join-Path $Root "Dockerfile") (Join-Path $Dest "Dockerfile")
Copy-Item -Force (Join-Path $Root "pom.xml") (Join-Path $Dest "pom.xml")
Copy-Item -Force (Join-Path $PSScriptRoot "docker-compose.yml") (Join-Path $Dest "docker-compose.yml")
Copy-Item -Force (Join-Path $PSScriptRoot ".env.example") (Join-Path $Dest ".env.example")

New-Item -ItemType Directory -Force -Path (Join-Path $Dest "deploy\sql") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Dest "deploy\nginx\certs") | Out-Null
Copy-Item -Force (Join-Path $Root "deploy\sql\schema.sql") (Join-Path $Dest "deploy\sql\schema.sql")
Copy-Item -Force (Join-Path $Root "deploy\nginx\ota.conf") (Join-Path $Dest "deploy\nginx\ota.conf")
if (Test-Path (Join-Path $Root "deploy\maven-settings.xml")) {
    Copy-Item -Force (Join-Path $Root "deploy\maven-settings.xml") (Join-Path $Dest "deploy\maven-settings.xml")
}

foreach ($p in @(
    "firmware",
    "logs",
    "ipc_upgrade\files",
    "ipc_upgrade\slot"
)) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Dest $p) | Out-Null
}
Set-Content -Encoding ascii (Join-Path $Dest "firmware\.gitkeep") ""
Set-Content -Encoding ascii (Join-Path $Dest "ipc_upgrade\files\.gitkeep") ""
Set-Content -Encoding ascii (Join-Path $Dest "ipc_upgrade\slot\.gitkeep") ""
Copy-Item -Force (Join-Path $PSScriptRoot "deploy.sh") (Join-Path $Dest "deploy.sh")

# 不带升级产物
Get-ChildItem -Recurse $Dest -Include *.bin,*.tar,*.log -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
if (Test-Path (Join-Path $Dest "ipc_upgrade\files")) {
    Get-ChildItem (Join-Path $Dest "ipc_upgrade\files") -File | Where-Object { $_.Name -ne ".gitkeep" } | Remove-Item -Force
}

Write-Host "已生成空站目录: $Dest"
Write-Host "不含 firmware .bin / ipc.tar / MySQL 升级数据。下一步: .\deploy.ps1 -PublicHost 新IP"
