# 技能脚本公共函数：定位技能根目录、读写 config

$ErrorActionPreference = 'Stop'

function Get-SkillRoot {
  # scripts/ 的上一级
  return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Get-ConfigDir {
  return (Join-Path (Get-SkillRoot) 'config')
}

function Read-DotEnv([string]$Path) {
  $map = @{}
  if (-not (Test-Path $Path)) { return $map }
  Get-Content $Path -Encoding UTF8 | ForEach-Object {
    $line = $_.Trim()
    if (-not $line -or $line.StartsWith('#')) { return }
    $i = $line.IndexOf('=')
    if ($i -lt 1) { return }
    $map[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim()
  }
  return $map
}

function Get-DefaultDataDir {
  # 未配置时的默认数据落点：技能根 _data（不写死个人盘符）
  return (Join-Path (Get-SkillRoot) '_data')
}

function Get-ExtraProgramDirs([hashtable]$EnvMap) {
  # 自定义 Program Files 根目录（分号分隔），用于探测装在非 C 盘的应用
  if ($EnvMap -and $EnvMap['EXTRA_PROGRAM_DIRS']) {
    return @($EnvMap['EXTRA_PROGRAM_DIRS'] -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  }
  return @()
}

function Get-BackupEnv {
  $configDir = Get-ConfigDir
  $envFile = Join-Path $configDir 'repository.env'
  if (-not (Test-Path $envFile)) {
    throw "缺少配置: $envFile`n请先运行: powershell -File scripts/init-config.ps1 并编辑 config/repository.env"
  }
  $map = Read-DotEnv $envFile
  foreach ($req in @('KOPIA_EXE', 'KOPIA_REPO_PATH', 'KOPIA_PASSWORD', 'KOPIA_CONFIG_PATH')) {
    if (-not $map[$req] -or $map[$req] -match '^(changeme|CHANGEME)') {
      throw "请在 config/repository.env 中设置有效的 $req"
    }
  }
  if (-not $map['SYSTEM_CONFIG_PATH']) { $map['SYSTEM_CONFIG_PATH'] = Join-Path (Get-DefaultDataDir) 'SystemConfig' }
  if (-not $map['RESTORE_TEMP']) { $map['RESTORE_TEMP'] = Join-Path (Get-DefaultDataDir) 'RestoreTemp' }
  if (-not $map['KOPIA_USERNAME']) { $map['KOPIA_USERNAME'] = $env:USERNAME }
  if (-not $map['KOPIA_HOSTNAME']) { $map['KOPIA_HOSTNAME'] = $env:COMPUTERNAME }
  $map['_CONFIG_DIR'] = $configDir
  $map['_SKILL_ROOT'] = Get-SkillRoot
  return $map
}

function Get-KopiaCommon([hashtable]$EnvMap) {
  $env:KOPIA_PASSWORD = $EnvMap['KOPIA_PASSWORD']
  return @('--config-file', $EnvMap['KOPIA_CONFIG_PATH'], '--password', $EnvMap['KOPIA_PASSWORD'])
}

function Assert-KopiaExe([hashtable]$EnvMap) {
  if (-not (Test-Path -LiteralPath $EnvMap['KOPIA_EXE'])) {
    throw "找不到 kopia.exe: $($EnvMap['KOPIA_EXE'])`n请在 config/repository.env 中修正 KOPIA_EXE"
  }
}

function Get-EnabledSources {
  $sourcesFile = Join-Path (Get-ConfigDir) 'sources.json'
  if (-not (Test-Path $sourcesFile)) {
    throw "缺少配置: $sourcesFile`n请先运行 scripts/init-config.ps1"
  }
  $src = Get-Content $sourcesFile -Raw -Encoding UTF8 | ConvertFrom-Json
  $items = @($src.sources | Where-Object { $_.enabled })
  if (-not $items -or $items.Count -eq 0) {
    throw "sources.json 中没有 enabled=true 的备份源"
  }
  return $items
}

function Test-IsAdmin {
  return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Dir([string]$Path) {
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Remove-TreeFast {
  # 比 Remove-Item -Recurse 更快：先改名释放路径，再用 rmdir /s /q 删除
  param(
    [Parameter(Mandatory)][string]$Path,
    [string]$Label = ''
  )
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }

  $parent = Split-Path -Parent $Path
  if (-not $parent) { throw "拒绝删除无父路径: $Path" }
  $trashName = '.trash_' + [guid]::NewGuid().ToString('N')
  $trash = Join-Path $parent $trashName
  $tag = if ($Label) { $Label } else { Split-Path -Leaf $Path }

  Write-Host "  清理 $tag ..."
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    Move-Item -LiteralPath $Path -Destination $trash -Force
  } catch {
    Write-Warning "  无法改名 $Path，直接删除: $($_.Exception.Message)"
    $trash = $Path
  }

  $null = cmd.exe /c "rmdir /s /q `"$trash`"" 2>&1
  if (Test-Path -LiteralPath $trash) {
    try {
      [System.IO.Directory]::Delete($trash, $true)
    } catch {
      Write-Warning "  清理未完成，残留: $trash — $($_.Exception.Message)"
      return
    }
  }
  Write-Host ("  清理完成 {0} ({1:N1}s)" -f $tag, $sw.Elapsed.TotalSeconds)
}

function Switch-ExportLatest {
  # 将 staging 目录原子切换为 latest；旧 latest 先改名为 previous 再快速删除
  param(
    [Parameter(Mandatory)][string]$OutputRoot,
    [Parameter(Mandatory)][string]$StagingRoot,
    [switch]$KeepPrevious
  )
  $latest = Join-Path $OutputRoot 'latest'
  $previous = Join-Path $OutputRoot 'previous'

  if (-not (Test-Path -LiteralPath $StagingRoot)) {
    throw "staging 不存在，无法切换: $StagingRoot"
  }

  if ((Test-Path -LiteralPath $previous) -and -not $KeepPrevious) {
    Remove-TreeFast -Path $previous -Label 'previous(旧)'
  } elseif ((Test-Path -LiteralPath $previous) -and $KeepPrevious) {
    $archived = Join-Path $OutputRoot ('previous_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Move-Item -LiteralPath $previous -Destination $archived -Force
    Write-Host "  保留上一版 -> $archived"
  }

  if (Test-Path -LiteralPath $latest) {
    Move-Item -LiteralPath $latest -Destination $previous -Force
    Write-Host '  latest -> previous'
  }

  Move-Item -LiteralPath $StagingRoot -Destination $latest -Force
  Write-Host "  staging -> latest ($latest)"

  if (-not $KeepPrevious -and (Test-Path -LiteralPath $previous)) {
    Remove-TreeFast -Path $previous -Label 'previous'
  }

  return $latest
}

function Clear-StaleExportDirs {
  # 清理中断残留的 .staging_* / .trash_*
  param([Parameter(Mandatory)][string]$OutputRoot)
  if (-not (Test-Path -LiteralPath $OutputRoot)) { return }
  Get-ChildItem -LiteralPath $OutputRoot -Force -Directory -EA SilentlyContinue |
    Where-Object { $_.Name -like '.staging_*' -or $_.Name -like '.trash_*' } |
    ForEach-Object {
      Write-Host "  发现残留 $($_.Name)，清理中"
      Remove-TreeFast -Path $_.FullName -Label $_.Name
    }
}

function Test-SystemConfigFresh {
  # latest/manifest.json 在指定小时内则视为新鲜
  param(
    [Parameter(Mandatory)][string]$OutputRoot,
    [double]$Hours
  )
  if ($Hours -le 0) { return $false }
  $manifestPath = Join-Path $OutputRoot 'latest\manifest.json'
  if (-not (Test-Path -LiteralPath $manifestPath)) { return $false }
  $age = (Get-Date) - (Get-Item -LiteralPath $manifestPath).LastWriteTime
  return ($age.TotalHours -lt $Hours)
}