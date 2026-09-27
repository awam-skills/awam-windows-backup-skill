# 恢复快照到目标目录（默认不覆盖正在使用的用户目录）

param(
  [Parameter(Mandatory = $false)]
  [string]$Snapshot = 'latest',

  [Parameter(Mandatory = $false)]
  [string]$SourcePath = '',

  [Parameter(Mandatory = $false)]
  [string]$Target = '',

  [Parameter(Mandatory = $false)]
  [string]$SubPath = '',

  [switch]$List
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$envMap = Get-BackupEnv
Assert-KopiaExe $envMap
$common = Get-KopiaCommon $envMap
$kopia = $envMap['KOPIA_EXE']

if ($List) {
  & $kopia @common snapshot list
  return
}

if (-not $SourcePath) {
  $first = Get-EnabledSources | Select-Object -First 1
  $SourcePath = $first.path
  Write-Host "未指定 -SourcePath，使用第一个启用源: $SourcePath"
}

if (-not $Target) {
  $leaf = Split-Path -Leaf $SourcePath.TrimEnd('\')
  if (-not $leaf) { $leaf = 'restore' }
  $Target = Join-Path $envMap['RESTORE_TEMP'] $leaf
}

Ensure-Dir (Split-Path -Parent $Target)
Ensure-Dir $Target

$snapArg = $Snapshot
if ($SubPath) {
  $snapArg = "${Snapshot}:${SubPath}"
}

Write-Host "源路径标识: $SourcePath"
Write-Host "快照:       $snapArg"
Write-Host "目标:       $Target"
Write-Host ''

# 列出该源的快照便于确认
& $kopia @common snapshot list -- $SourcePath

Write-Host ''
Write-Host '开始恢复...'
& $kopia @common snapshot restore $snapArg --target $Target
if ($LASTEXITCODE -ne 0) { throw "restore 失败 (exit=$LASTEXITCODE)" }

Write-Host ''
Write-Host "Done. 请检查: $Target"
Write-Host '确认无误后再手工覆盖到真实位置。系统配置请用 import-system-config.ps1 按模块导入。'