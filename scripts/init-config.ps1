# 从 config.example 初始化本地 config/（不覆盖已有文件，除非 -Force）

param(
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$skillRoot = Get-SkillRoot
$exampleDir = Join-Path $skillRoot 'config.example'
$configDir = Get-ConfigDir
Ensure-Dir $configDir

$map = @{
  'repository.env.example' = 'repository.env'
  'sources.json.example'   = 'sources.json'
  'policies.json.example'  = 'policies.json'
}

$created = @(); $skipped = @()
foreach ($k in $map.Keys) {
  $src = Join-Path $exampleDir $k
  $dst = Join-Path $configDir $map[$k]
  if (-not (Test-Path $src)) { throw "缺少模板: $src" }
  if ((Test-Path $dst) -and -not $Force) {
    $skipped += $map[$k]
    continue
  }
  Copy-Item -LiteralPath $src -Destination $dst -Force
  $created += $map[$k]
}

Write-Host "config 目录: $configDir"
if ($created.Count) { Write-Host ("已创建: " + ($created -join ', ')) }
if ($skipped.Count) { Write-Host ("已跳过(已存在): " + ($skipped -join ', ') + "  （覆盖请加 -Force）") }
Write-Host ''
Write-Host '下一步:'
Write-Host '  1. 编辑 config/repository.env（KOPIA_EXE / 仓库路径 / 密码）'
Write-Host '  2. 编辑 config/sources.json（备份源路径）'
Write-Host '  3. 运行 scripts/setup.ps1 创建或连接仓库'