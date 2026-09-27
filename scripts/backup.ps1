# 增量备份：先刷新系统配置导出，再对 enabled 源创建快照
# Kopia 内容寻址，重复执行只上传变化块

param(
  [switch]$SkipSystemConfigExport,
  [string[]]$OnlyIds
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$envMap = Get-BackupEnv
Assert-KopiaExe $envMap
$common = Get-KopiaCommon $envMap
$kopia = $envMap['KOPIA_EXE']

$exportScript = Join-Path $PSScriptRoot 'export-system-config.ps1'
if (-not $SkipSystemConfigExport -and (Test-Path $exportScript)) {
  Write-Host '==== 刷新系统配置导出 ===='
  try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exportScript
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "export-system-config 退出码 $LASTEXITCODE ，仍继续快照"
    }
  } catch {
    Write-Warning "export-system-config 失败: $($_.Exception.Message) ，仍继续快照"
  }
  Write-Host ''
}

$items = Get-EnabledSources
if ($OnlyIds -and $OnlyIds.Count -gt 0) {
  $items = @($items | Where-Object { $OnlyIds -contains $_.id })
  if ($items.Count -eq 0) { throw "没有匹配的备份源: $($OnlyIds -join ',')" }
}

$ok = 0; $fail = 0
foreach ($item in $items) {
  $p = $item.path
  if (-not (Test-Path -LiteralPath $p)) {
    Write-Warning "跳过不存在的路径 [$($item.id)]: $p"
    continue
  }
  Write-Host "==== snapshot $($item.id): $p ===="
  & $kopia @common snapshot create -- $p
  if ($LASTEXITCODE -eq 0) { $ok++ } else { $fail++; Write-Warning "失败: $p" }
}

Write-Host ''
Write-Host "Done: ok=$ok fail=$fail （增量：仅上传变化数据块）"
& $kopia @common snapshot list