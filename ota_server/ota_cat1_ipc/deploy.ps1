# 打包空站并可选上传到新机器。
# 用法:
#   .\deploy.ps1 -PublicHost 1.2.3.4
#   .\deploy.ps1 -PublicHost 1.2.3.4 -SshTarget ubuntu@1.2.3.4
param(
    [Parameter(Mandatory = $true)][string]$PublicHost,
    [string]$SshTarget = "",
    [string]$SshKey = "$env:USERPROFILE\.ssh\id_ed25519",
    [string]$RemoteDir = "/home/ubuntu/ota_cat1_ipc"
)
$ErrorActionPreference = "Stop"
$Kit = $PSScriptRoot
Set-Location $Kit
& "$Kit\pack.ps1"

$envFile = Join-Path $Kit "site\.env"
Copy-Item -Force (Join-Path $Kit ".env.example") $envFile
(Get-Content $envFile) -replace '^OTA_PUBLIC_HOST=.*', "OTA_PUBLIC_HOST=$PublicHost" | Set-Content -Encoding ascii $envFile

if (-not $SshTarget) {
    Write-Host "本地包已准备: $Kit\site"
    Write-Host "拷到新机后执行:"
    Write-Host "  scp -i $SshKey -r `"$Kit`" ${PublicHost}:/home/ubuntu/"
    Write-Host "  ssh ... 'cd $RemoteDir/site && chmod +x deploy.sh && ./deploy.sh $PublicHost'"
    return
}

if (-not (Test-Path $SshKey)) {
    throw "找不到 SSH 私钥: $SshKey"
}

Write-Host "上传到 $SshTarget`:$RemoteDir ..."
ssh -i $SshKey $SshTarget "mkdir -p $RemoteDir"
scp -i $SshKey -r "$Kit\site" "${SshTarget}:${RemoteDir}/"
scp -i $SshKey "$Kit\deploy.sh" "${SshTarget}:${RemoteDir}/site/deploy.sh"
ssh -i $SshKey $SshTarget "chmod +x $RemoteDir/site/deploy.sh && cd $RemoteDir/site && ./deploy.sh $PublicHost"
Write-Host "完成: http://$PublicHost/admin.html  http://$PublicHost/ipc.html"
