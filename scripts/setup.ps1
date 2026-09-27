# 创建或连接 Kopia 仓库，并导入 policies.json

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$envMap = Get-BackupEnv
Assert-KopiaExe $envMap
$common = Get-KopiaCommon $envMap
$kopia = $envMap['KOPIA_EXE']
$repo = $envMap['KOPIA_REPO_PATH']
$cfg = $envMap['KOPIA_CONFIG_PATH']
$policies = Join-Path $envMap['_CONFIG_DIR'] 'policies.json'
$user = $envMap['KOPIA_USERNAME']
$hostName = $envMap['KOPIA_HOSTNAME']

if (-not (Test-Path $policies)) {
  throw "缺少 policies.json: $policies"
}

Ensure-Dir (Split-Path -Parent $cfg)
Ensure-Dir $repo
Ensure-Dir $envMap['SYSTEM_CONFIG_PATH']

Write-Host "仓库: $repo"
Write-Host "配置: $cfg"
Write-Host "尝试创建仓库..."
& $kopia @common repository create filesystem --path $repo --override-username $user --override-hostname $hostName
if ($LASTEXITCODE -ne 0) {
  Write-Host '创建失败，尝试连接已有仓库...'
  & $kopia @common repository connect filesystem --path $repo
  if ($LASTEXITCODE -ne 0) { throw '无法创建或连接仓库' }
}

Write-Host "导入策略: $policies"
& $kopia @common policy import --from-file $policies --allow-unknown-fields
if ($LASTEXITCODE -ne 0) { throw 'policy import 失败' }

Write-Host ''
Write-Host '全局策略:'
& $kopia @common policy show --global
Write-Host ''
Write-Host 'Done. 下一步: 运行 scripts/backup.ps1'