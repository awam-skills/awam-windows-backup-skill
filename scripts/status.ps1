# 查看仓库状态与快照列表

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$envMap = Get-BackupEnv
Assert-KopiaExe $envMap
$common = Get-KopiaCommon $envMap
$kopia = $envMap['KOPIA_EXE']

Write-Host '==== 配置摘要 ===='
Write-Host "技能目录: $($envMap['_SKILL_ROOT'])"
Write-Host "Kopia:    $($envMap['KOPIA_EXE'])"
Write-Host "仓库:     $($envMap['KOPIA_REPO_PATH'])"
Write-Host "系统配置: $($envMap['SYSTEM_CONFIG_PATH'])"
Write-Host "管理员:   $(Test-IsAdmin)"
Write-Host ''
Write-Host '==== 备份源 ===='
Get-EnabledSources | ForEach-Object {
  $exists = Test-Path -LiteralPath $_.path
  Write-Host ("  [{0}] {1}  exists={2}  {3}" -f $(if ($_.enabled) { 'ON' } else { '--' }), $_.id, $exists, $_.path)
}
Write-Host ''
Write-Host '==== repository status ===='
& $kopia @common repository status
Write-Host ''
Write-Host '==== snapshot list ===='
& $kopia @common snapshot list