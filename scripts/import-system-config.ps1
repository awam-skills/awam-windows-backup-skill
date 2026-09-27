# 按模块从 SYSTEM_CONFIG_PATH/latest 恢复系统配置

param(
  [string]$InputRoot = '',
  [string]$Modules = '',
  [switch]$List,
  [switch]$WhatIf,
  [switch]$AllowFullHkcu
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$envMap = $null
try { $envMap = Get-BackupEnv } catch { $envMap = @{ SYSTEM_CONFIG_PATH = 'I:\Backup\SystemConfig' } }
if (-not $InputRoot) { $InputRoot = $envMap['SYSTEM_CONFIG_PATH'] }
if (-not $InputRoot) { $InputRoot = 'I:\Backup\SystemConfig' }

$Root = Join-Path $InputRoot 'latest'
$manifestPath = Join-Path $Root 'manifest.json'
if (-not (Test-Path $manifestPath)) { throw "找不到 manifest: $manifestPath 。请先 backup 或 export-system-config。" }
$manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$isAdmin = Test-IsAdmin

if ($List -or -not $Modules) {
  Write-Host "可用模块 (来自 $($manifest.exportedAt)):"
  Write-Host ''
  foreach ($m in $manifest.modules) {
    $flag = if ($m.ok) { 'OK' } else { '--' }
    Write-Host ("  [{0}] {1,-28} {2}" -f $flag, $m.id, $m.note)
  }
  Write-Host ''
  Write-Host '示例: -Modules environment-user,hosts,tasks,autorun,startup-folder,run-user'
  if (-not $Modules) { return }
}

$requested = @()
if ($Modules.Trim() -eq '*') {
  $requested = @($manifest.modules | Where-Object { $_.ok -and $_.id -ne 'hkcu-full' -and $_.type -ne 'inventory' } | ForEach-Object { $_.id })
} else {
  $requested = @($Modules.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

$byId = @{}
foreach ($m in $manifest.modules) { $byId[$m.id] = $m }
$ok = 0; $fail = 0; $skip = 0

foreach ($id in $requested) {
  if (-not $byId.ContainsKey($id)) { Write-Warning "未知模块: $id"; $fail++; continue }
  $m = $byId[$id]
  Write-Host "==== import $id ($($m.note)) ===="
  if ($id -eq 'hkcu-full' -and -not $AllowFullHkcu) { Write-Warning '跳过 hkcu-full（需 -AllowFullHkcu）'; $skip++; continue }
  if ($m.type -eq 'inventory') { Write-Host '  清单无需导入'; $skip++; continue }

  switch ($m.type) {
    'registry' {
      $regFile = Join-Path $Root $m.file
      if (-not (Test-Path $regFile)) { Write-Warning "缺文件 $regFile"; $fail++; break }
      if ($m.needAdmin -and -not $isAdmin) { Write-Warning "需管理员: $id"; $fail++; break }
      if ($WhatIf) { Write-Host "  WhatIf: reg import $regFile"; $ok++; break }
      $null = & reg.exe import $regFile 2>&1
      if ($LASTEXITCODE -eq 0) { Write-Host '  OK'; $ok++ } else { Write-Warning 'reg import 失败'; $fail++ }
    }
    'registry-full' {
      $regFile = Join-Path $Root $m.file
      if ($WhatIf) { Write-Host "  WhatIf: FULL HKCU import"; $ok++; break }
      $null = & reg.exe import $regFile 2>&1
      if ($LASTEXITCODE -eq 0) { Write-Host '  OK'; $ok++ } else { Write-Warning '失败'; $fail++ }
    }
    'file' {
      if ($id -eq 'hosts') {
        $src = Join-Path $Root 'hosts\hosts'
        $dst = "$env:SystemRoot\System32\drivers\etc\hosts"
        if (-not $isAdmin) { Write-Warning 'hosts 需管理员'; $fail++; break }
        if ($WhatIf) { Write-Host "  WhatIf: copy hosts"; $ok++; break }
        Copy-Item -LiteralPath $src -Destination $dst -Force
        Write-Host "  OK -> $dst"; $ok++
      }
    }
    'tasks' {
      $taskRoot = Join-Path $Root 'tasks'
      Get-ChildItem $taskRoot -Recurse -Filter '*.xml' -EA SilentlyContinue | ForEach-Object {
        $rel = $_.FullName.Substring($taskRoot.Length).TrimStart('\')
        $parts = $rel -split '\\'
        $taskName = [IO.Path]::GetFileNameWithoutExtension($parts[-1])
        $taskPath = '\'
        if ($parts.Length -gt 1) {
          $folder = ($parts[0..($parts.Length-2)] -join '\')
          if ($folder -and $folder -ne '_root') { $taskPath = '\' + ($folder -replace '_','\') + '\' }
        }
        if ($WhatIf) { Write-Host "  WhatIf: task $taskPath$taskName"; return }
        try {
          $existing = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -EA SilentlyContinue
          if ($existing) { Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false }
          Register-ScheduledTask -Xml (Get-Content $_.FullName -Raw) -TaskName $taskName -TaskPath $taskPath -Force | Out-Null
          Write-Host "  OK $taskPath$taskName"
        } catch { Write-Warning "任务失败 $taskName : $($_.Exception.Message)"; $fail++ }
      }
      $ok++
    }
    'autorun' {
      $info = Get-Content (Join-Path $Root 'autorun\autorun.json') -Raw -Encoding UTF8 | ConvertFrom-Json
      Get-ChildItem (Join-Path $Root 'autorun') -File -EA SilentlyContinue | Where-Object { $_.Name -ne 'autorun.json' } | ForEach-Object {
        $dest = Join-Path $env:USERPROFILE $_.Name
        if ($WhatIf) { Write-Host "  WhatIf: copy $($_.Name)"; return }
        Copy-Item $_.FullName $dest -Force
      }
      if ($info.user -and -not $WhatIf) {
        New-Item -Path 'HKCU:\Software\Microsoft\Command Processor' -Force | Out-Null
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Command Processor' -Name AutoRun -Value $info.user -Type String
        Write-Host '  OK user AutoRun'
      }
      $ok++
    }
    'startup' {
      $userSrc = Join-Path $Root 'startup\user'
      $userDst = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
      if (Test-Path $userSrc) {
        Get-ChildItem $userSrc -Force | ForEach-Object {
          if ($WhatIf) { Write-Host "  WhatIf: $($_.Name)"; return }
          Copy-Item $_.FullName (Join-Path $userDst $_.Name) -Force -Recurse
        }
      }
      $ok++
    }
    'network' {
      if ($id -eq 'firewall') {
        if (-not $isAdmin) { Write-Warning '防火墙需管理员'; $fail++; break }
        $fw = Join-Path $Root 'network\firewall.wfw'
        if ($WhatIf) { Write-Host '  WhatIf: firewall'; $ok++; break }
        $null = & netsh.exe advfirewall import $fw 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Host '  OK'; $ok++ } else { $fail++ }
      } elseif ($id -eq 'wifi') {
        Get-ChildItem (Join-Path $Root 'network') -Filter '*.xml' -EA SilentlyContinue | ForEach-Object {
          if ($WhatIf) { Write-Host "  WhatIf: $($_.Name)"; return }
          $null = & netsh.exe wlan add profile filename="$($_.FullName)" user=current 2>&1
        }
        $ok++
      }
    }
    'misc' {
      if ($id -eq 'windows-terminal') {
        $src = Join-Path $Root 'misc\windows-terminal-settings.json'
        $dstDir = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState"
        if (-not (Test-Path $dstDir)) { $dstDir = "$env:LOCALAPPDATA\Microsoft\Windows Terminal" }
        Ensure-Dir $dstDir
        if (-not $WhatIf) { Copy-Item $src (Join-Path $dstDir 'settings.json') -Force }
        Write-Host '  OK terminal'; $ok++
      } elseif ($id -eq 'wslconfig') {
        if (-not $WhatIf) { Copy-Item (Join-Path $Root 'misc\wslconfig') (Join-Path $env:USERPROFILE '.wslconfig') -Force }
        Write-Host '  OK wslconfig'; $ok++
      } else { Write-Host '  请手工处理'; $skip++ }
    }
    'apps' {
      $appSrc = Join-Path $Root $m.file
      switch ($id) {
        'netsang' {
          $src = Join-Path $Root 'apps\netsang\Documents-NetSarang-Computer'
          $dst = Join-Path $env:USERPROFILE 'Documents\NetSarang Computer'
          if (-not (Test-Path $src)) { Write-Warning "缺目录 $src"; $fail++; break }
          if ($WhatIf) { Write-Host "  WhatIf: copy -> $dst"; $ok++; break }
          Ensure-Dir $dst
          & robocopy.exe $src $dst /E /R:1 /W:1 /NFL /NDL /NJH /NJS | Out-Null
          Write-Host "  OK -> $dst"; $ok++
        }
        'directory-opus' {
          $src = Join-Path $Root 'apps\directory-opus'
          $dst = Join-Path $env:APPDATA 'GPSoftware\Directory Opus'
          if (-not (Test-Path $src)) { Write-Warning "缺目录 $src"; $fail++; break }
          if ($WhatIf) { Write-Host "  WhatIf: copy -> $dst"; $ok++; break }
          Ensure-Dir $dst
          & robocopy.exe $src $dst /E /R:1 /W:1 /NFL /NDL /NJH /NJS | Out-Null
          Write-Host "  OK -> $dst"; $ok++
        }
        'android-studio' {
          $srcRoot = Join-Path $Root 'apps\android-studio'
          $dstRoot = Join-Path $env:APPDATA 'Google'
          if (-not (Test-Path $srcRoot)) { Write-Warning "缺目录 $srcRoot"; $fail++; break }
          Get-ChildItem $srcRoot -Directory -EA SilentlyContinue | ForEach-Object {
            $dst = Join-Path $dstRoot $_.Name
            if ($WhatIf) { Write-Host "  WhatIf: $($_.Name)"; return }
            Ensure-Dir $dst
            & robocopy.exe $_.FullName $dst /E /R:1 /W:1 /NFL /NDL /NJH /NJS | Out-Null
            Write-Host "  OK $($_.Name)"
          }
          $ok++
        }
        'easy-context-menu' {
          Write-Host "  请将 $appSrc 中的 EcMenu.ini / Items.ini 拷回 Easy Context Menu\Files\"; $skip++
        }
        'potplayer-ini' {
          Write-Host "  PotPlayer：先 import potplayer-mini64 / potplayer64 注册表，再按需拷回 $appSrc 的 .ini"; $skip++
        }
        'total-commander' {
          Write-Host "  请将 $appSrc 中的 wincmd.ini / wcx_ftp.ini 拷到 TC 使用的路径（见注册表 IniFileName），并 import total-commander-reg"; $skip++
        }
        'browser-essentials' {
          Write-Host '  浏览器扩展随 user-profile 恢复，无需单独导入'; $skip++
        }
        default {
          Write-Host "  请手工从 $appSrc 恢复"; $skip++
        }
      }
    }
    default { Write-Warning "未实现: $($m.type)"; $skip++ }
  }
}

Write-Host ''
Write-Host "Done: ok=$ok fail=$fail skip=$skip"