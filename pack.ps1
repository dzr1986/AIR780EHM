# 780EHM_PJ 整包打包（含年月日）
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

$ts = Get-Date -Format 'yyyyMMdd'
$baseName = "780EHM_PJ_$ts"
$zipName = "$baseName.zip"
$zipPath = Join-Path $root $zipName
$n = 2
while (Test-Path $zipPath) {
    $zipName = "${baseName}_$n.zip"
    $zipPath = Join-Path $root $zipName
    $n++
}

Write-Host "========================================"
Write-Host "780EHM_PJ 整包打包"
Write-Host "日期: $(Get-Date -Format 'yyyy-MM-dd') ($ts)"
Write-Host "输出: $zipPath"
Write-Host "========================================"

$items = @(
    (Join-Path $root 'README.md'),
    (Join-Path $root 'luatos.json'),
    (Join-Path $root 'user'),
    (Join-Path $root 'lib'),
    (Join-Path $root 'doc')
)

foreach ($item in $items) {
    if (-not (Test-Path $item)) {
        Write-Error "缺少: $item"
    }
}

Compress-Archive -Path $items -DestinationPath $zipPath

$f = Get-Item $zipPath
Write-Host ""
Write-Host "打包成功"
Write-Host "文件: $($f.FullName)"
Write-Host "大小: $([math]::Round($f.Length / 1KB, 1)) KB"
Write-Host "时间: $($f.LastWriteTime)"
