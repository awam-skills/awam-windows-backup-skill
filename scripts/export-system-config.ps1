# 导出系统级配置到 SYSTEM_CONFIG_PATH/latest，供增量快照与按模块恢复

param([string]$OutputRoot = '')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

function Export-RegKey {
  param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$OutFile, [string]$Note = '')
  Ensure-Dir (Split-Path -Parent $OutFile)
  $null = & reg.exe export $Key $OutFile /y 2>&1
  if ($LASTEXITCODE -eq 0 -and (Test-Path $OutFile)) {
    return [pscustomobject]@{ ok = $true; key = $Key; file = $OutFile; note = $Note; bytes = (Get-Item $OutFile).Length }
  }
  return [pscustomobject]@{ ok = $false; key = $Key; file = $OutFile; note = $Note; error = "export failed (exit=$LASTEXITCODE)" }
}

function Copy-IfExists {
  param([string]$Source, [string]$DestDir, [string]$Name = '')
  if (-not (Test-Path -LiteralPath $Source)) { return $null }
  Ensure-Dir $DestDir
  $destName = if ($Name) { $Name } else { Split-Path -Leaf $Source }
  $dest = Join-Path $DestDir $destName
  Copy-Item -LiteralPath $Source -Destination $dest -Force
  return $dest
}

$envMap = $null
try { $envMap = Get-BackupEnv } catch {
  # 允许在仅导出场景下用默认路径
  $envMap = @{ SYSTEM_CONFIG_PATH = 'I:\Backup\SystemConfig' }
}
if (-not $OutputRoot) { $OutputRoot = $envMap['SYSTEM_CONFIG_PATH'] }
if (-not $OutputRoot) { $OutputRoot = 'I:\Backup\SystemConfig' }

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$computer = $env:COMPUTERNAME
$user = $env:USERNAME
$isAdmin = Test-IsAdmin

$Root = Join-Path $OutputRoot 'latest'
if (Test-Path $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
Ensure-Dir $Root

$dirs = @{
  registryModules = Join-Path $Root 'registry\modules'
  registryFull    = Join-Path $Root 'registry\full'
  hosts           = Join-Path $Root 'hosts'
  tasks           = Join-Path $Root 'tasks'
  autorun         = Join-Path $Root 'autorun'
  startup         = Join-Path $Root 'startup'
  network         = Join-Path $Root 'network'
  inventory       = Join-Path $Root 'inventory'
  misc            = Join-Path $Root 'misc'
}
$dirs.Values | ForEach-Object { Ensure-Dir $_ }

$manifest = [ordered]@{
  exportedAt  = (Get-Date).ToString('o')
  stamp       = $stamp
  computer    = $computer
  user        = $user
  isAdmin     = $isAdmin
  outputRoot  = $Root
  modules     = @()
  warnings    = @()
  restoreHint = '使用 import-system-config.ps1 -Modules <名称列表> 按模块导入'
}

Write-Host "==== export system config -> $Root (admin=$isAdmin) ===="

$regModules = @(
  @{ id = 'environment-user'; key = 'HKCU\Environment'; note = '用户环境变量'; needAdmin = $false },
  @{ id = 'environment-machine'; key = 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'; note = '系统环境变量(需管理员)'; needAdmin = $true },
  @{ id = 'run-user'; key = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'; note = '用户开机启动 Run'; needAdmin = $false },
  @{ id = 'run-machine'; key = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Run'; note = '系统开机启动 Run(需管理员)'; needAdmin = $true },
  @{ id = 'runonce-user'; key = 'HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce'; note = '用户 RunOnce'; needAdmin = $false },
  @{ id = 'command-processor-user'; key = 'HKCU\Software\Microsoft\Command Processor'; note = 'CMD AutoRun 用户'; needAdmin = $false },
  @{ id = 'command-processor-machine'; key = 'HKLM\Software\Microsoft\Command Processor'; note = 'CMD AutoRun 机器(需管理员)'; needAdmin = $true },
  @{ id = 'explorer-shell-folders'; key = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'; note = '用户壳文件夹重定向'; needAdmin = $false },
  @{ id = 'explorer-shell-folders-fixed'; key = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'; note = 'Shell Folders 对照'; needAdmin = $false },
  @{ id = 'explorer-advanced'; key = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; note = '资源管理器高级选项'; needAdmin = $false },
  @{ id = 'console'; key = 'HKCU\Console'; note = '控制台窗口默认设置'; needAdmin = $false },
  @{ id = 'international'; key = 'HKCU\Control Panel\International'; note = '区域与格式'; needAdmin = $false },
  @{ id = 'input-method'; key = 'HKCU\Keyboard Layout'; note = '键盘布局'; needAdmin = $false }
)

foreach ($m in $regModules) {
  if ($m.needAdmin -and -not $isAdmin) {
    $manifest.warnings += "跳过注册表模块 $($m.id)：需要管理员"
    Write-Warning "Skip $($m.id) (need admin)"
    continue
  }
  $out = Join-Path $dirs.registryModules "$($m.id).reg"
  $r = Export-RegKey -Key $m.key -OutFile $out -Note $m.note
  $entry = [ordered]@{ id = $m.id; type = 'registry'; key = $m.key; file = "registry/modules/$($m.id).reg"; note = $m.note; needAdmin = [bool]$m.needAdmin; ok = $r.ok }
  if (-not $r.ok) { $entry.error = $r.error; $manifest.warnings += "注册表模块失败: $($m.id)" }
  $manifest.modules += $entry
  if ($r.ok) { Write-Host "  reg OK  $($m.id) ($($r.bytes) bytes)" } else { Write-Host "  reg --  $($m.id)" }
}

$hkcuFull = Join-Path $dirs.registryFull 'HKCU.reg'
Write-Host '  exporting full HKCU...'
$null = & reg.exe export HKCU $hkcuFull /y 2>&1
if ($LASTEXITCODE -eq 0 -and (Test-Path $hkcuFull)) {
  $bytes = (Get-Item $hkcuFull).Length
  $manifest.modules += [ordered]@{ id = 'hkcu-full'; type = 'registry-full'; key = 'HKCU'; file = 'registry/full/HKCU.reg'; note = 'HKCU 全量归档，勿默认整包导入'; ok = $true; bytes = $bytes }
  Write-Host "  reg OK  hkcu-full ($([math]::Round($bytes/1MB, 1)) MB)"
} else {
  $manifest.warnings += 'HKCU 全量导出失败'
}

$hostsSrc = "$env:SystemRoot\System32\drivers\etc\hosts"
if (Copy-IfExists $hostsSrc $dirs.hosts 'hosts') {
  $manifest.modules += [ordered]@{ id = 'hosts'; type = 'file'; file = 'hosts/hosts'; note = '系统 hosts'; ok = $true; needAdmin = $true }
  Write-Host '  file OK hosts'
}

$taskCount = 0
Get-ScheduledTask -ErrorAction SilentlyContinue |
  Where-Object { $_.TaskPath -notmatch '\\Microsoft\\' } |
  ForEach-Object {
    try {
      $safePath = ($_.TaskPath.Trim('\') -replace '[\\/:*?"<>|]', '_')
      if (-not $safePath) { $safePath = '_root' }
      $safeName = ($_.TaskName -replace '[\\/:*?"<>|]', '_')
      $sub = Join-Path $dirs.tasks $safePath
      Ensure-Dir $sub
      Export-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath | Out-File -FilePath (Join-Path $sub "$safeName.xml") -Encoding utf8
      $taskCount++
    } catch {
      $manifest.warnings += "计划任务导出失败: $($_.TaskPath)$($_.TaskName)"
    }
  }
$manifest.modules += [ordered]@{ id = 'tasks'; type = 'tasks'; file = 'tasks/'; note = "非 Microsoft 计划任务 ($taskCount)"; ok = $true; count = $taskCount }
Write-Host "  tasks OK ($taskCount)"

$autorunInfo = [ordered]@{ user = $null; machine = $null; copiedScripts = @() }
foreach ($scope in @(
  @{ name = 'user'; ps = 'HKCU:\Software\Microsoft\Command Processor' },
  @{ name = 'machine'; ps = 'HKLM:\Software\Microsoft\Command Processor' }
)) {
  $val = $null
  try {
    $props = Get-ItemProperty -Path $scope.ps -ErrorAction Stop
    if ($null -ne $props.AutoRun) { $val = [string]$props.AutoRun }
  } catch {}
  $autorunInfo[$scope.name] = $val
  if ($val) {
    $candidates = @()
    $m2 = [regex]::Match($val, '"([^"]+)"')
    if ($m2.Success) { $candidates += $m2.Groups[1].Value }
    $candidates += ($val -split '\s+' | Select-Object -First 1)
    foreach ($c in $candidates) {
      if ($c -and (Test-Path -LiteralPath $c)) {
        $copied = Copy-IfExists $c $dirs.autorun
        if ($copied) { $autorunInfo.copiedScripts += $copied }
      }
    }
  }
}
$autorunInfo | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $dirs.autorun 'autorun.json') -Encoding UTF8
$manifest.modules += [ordered]@{ id = 'autorun'; type = 'autorun'; file = 'autorun/'; note = 'CMD AutoRun'; ok = $true; userAutoRun = $autorunInfo.user; machineAutoRun = $autorunInfo.machine }
Write-Host "  autorun OK"

$userStartup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$commonStartup = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp'
$userOut = Join-Path $dirs.startup 'user'; $commonOut = Join-Path $dirs.startup 'common'
Ensure-Dir $userOut; Ensure-Dir $commonOut
$startupCount = 0
foreach ($pair in @(@{src=$userStartup;dst=$userOut}, @{src=$commonStartup;dst=$commonOut})) {
  if (Test-Path $pair.src) {
    Get-ChildItem -LiteralPath $pair.src -Force -ErrorAction SilentlyContinue | ForEach-Object {
      Copy-Item $_.FullName (Join-Path $pair.dst $_.Name) -Force -Recurse
      $startupCount++
    }
  }
}
$manifest.modules += [ordered]@{ id = 'startup-folder'; type = 'startup'; file = 'startup/'; note = "启动文件夹 ($startupCount)"; ok = $true; count = $startupCount }
Write-Host "  startup OK ($startupCount)"

try {
  if ($isAdmin) { $null = & netsh.exe wlan export profile key=clear folder=$($dirs.network) 2>&1 }
  else {
    $null = & netsh.exe wlan export profile folder=$($dirs.network) 2>&1
    $manifest.warnings += 'Wi-Fi 未含密钥(需管理员)'
  }
  $wifiCount = @(Get-ChildItem $dirs.network -Filter '*.xml' -EA SilentlyContinue).Count
  $manifest.modules += [ordered]@{ id = 'wifi'; type = 'network'; file = 'network/'; note = "WLAN ($wifiCount)"; ok = $true; count = $wifiCount }
  Write-Host "  wifi OK ($wifiCount)"
} catch { $manifest.warnings += "Wi-Fi 失败: $($_.Exception.Message)" }

$fwFile = Join-Path $dirs.network 'firewall.wfw'
if ($isAdmin) {
  try {
    $null = & netsh.exe advfirewall export $fwFile 2>&1
    if (Test-Path $fwFile) {
      $manifest.modules += [ordered]@{ id = 'firewall'; type = 'network'; file = 'network/firewall.wfw'; note = '防火墙'; ok = $true; needAdmin = $true }
      Write-Host '  firewall OK'
    }
  } catch { $manifest.warnings += "防火墙失败: $($_.Exception.Message)" }
} else { $manifest.warnings += '跳过防火墙：需管理员' }

try {
  $apps = @()
  foreach ($regPath in @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )) {
    Get-ItemProperty $regPath -EA SilentlyContinue | Where-Object { $_.DisplayName } | ForEach-Object {
      $apps += [pscustomobject]@{ DisplayName=$_.DisplayName; DisplayVersion=$_.DisplayVersion; Publisher=$_.Publisher; InstallLocation=$_.InstallLocation }
    }
  }
  $apps = $apps | Sort-Object DisplayName -Unique
  $apps | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $dirs.inventory 'installed-programs.json') -Encoding UTF8
  $manifest.modules += [ordered]@{ id = 'installed-programs'; type = 'inventory'; file = 'inventory/installed-programs.json'; note = "已装软件清单 ($($apps.Count))"; ok = $true; count = $apps.Count }
  Write-Host "  inventory OK ($($apps.Count))"
} catch { $manifest.warnings += "清单失败: $($_.Exception.Message)" }

try {
  & powercfg.exe /list > (Join-Path $dirs.misc 'powercfg-list.txt') 2>&1
  & powercfg.exe /getactivescheme > (Join-Path $dirs.misc 'powercfg-active.txt') 2>&1
  $guidLine = Get-Content (Join-Path $dirs.misc 'powercfg-active.txt') -Raw
  if ($guidLine -match '([0-9a-fA-F-]{36})') {
    & powercfg.exe /export (Join-Path $dirs.misc 'active-power-scheme.pow') $Matches[1] 2>&1 | Out-Null
  }
  $manifest.modules += [ordered]@{ id = 'powercfg'; type = 'misc'; file = 'misc/'; note = '电源方案'; ok = $true }
} catch { $manifest.warnings += "电源方案失败: $($_.Exception.Message)" }

[pscustomobject]@{
  TimeZone = (Get-TimeZone | Select-Object Id, DisplayName)
  Culture = [System.Globalization.CultureInfo]::CurrentCulture.Name
} | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $dirs.misc 'locale.json') -Encoding UTF8

foreach ($wt in @(
  "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
  "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
)) {
  if (Test-Path $wt) {
    Copy-IfExists $wt $dirs.misc 'windows-terminal-settings.json' | Out-Null
    $manifest.modules += [ordered]@{ id = 'windows-terminal'; type = 'misc'; file = 'misc/windows-terminal-settings.json'; note = 'Windows Terminal'; ok = $true }
    break
  }
}

if (Test-Path "$env:USERPROFILE\.wslconfig") {
  Copy-IfExists "$env:USERPROFILE\.wslconfig" $dirs.misc 'wslconfig' | Out-Null
  $manifest.modules += [ordered]@{ id = 'wslconfig'; type = 'misc'; file = 'misc/wslconfig'; note = '.wslconfig'; ok = $true }
}

($manifest | ConvertTo-Json -Depth 8) | Set-Content (Join-Path $Root 'manifest.json') -Encoding UTF8
$idx = @('# SystemConfig 导出索引', '', "- 时间: $($manifest.exportedAt)", "- 计算机: $computer / $user / admin=$isAdmin", '', '| 模块 | 类型 | 说明 | OK |', '|------|------|------|----|')
foreach ($m in $manifest.modules) { $idx += "| $($m.id) | $($m.type) | $($m.note) | $($m.ok) |" }
if ($manifest.warnings.Count) {
  $idx += ''; $idx += '## 警告'
  foreach ($w in $manifest.warnings) { $idx += "- $w" }
}
$idx -join "`n" | Set-Content (Join-Path $Root 'INDEX.md') -Encoding UTF8
[pscustomobject]@{ stamp = $stamp; latest = $Root; exportedAt = $manifest.exportedAt } |
  ConvertTo-Json | Set-Content (Join-Path $OutputRoot 'LAST_EXPORT.json') -Encoding UTF8

Write-Host ''
Write-Host "Done. modules=$($manifest.modules.Count) warnings=$($manifest.warnings.Count)"