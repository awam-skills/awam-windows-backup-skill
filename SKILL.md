---
name: awam-windows-backup
version: 0.0.1
description: >-
  Windows 本机 Kopia 增量备份与恢复（用户目录 + 系统配置导出）。
  Use when the user asks to backup, restore, snapshot, 备份, 恢复, Kopia,
  SystemConfig, hosts/环境变量/计划任务备份, or to set up this skill's config.
---

# AWAM Windows Backup（Kopia）

基于 **Kopia** 的本机增量备份技能：用户目录快照 + 系统配置模块化导出。重复备份只上传变化块。

## 目录结构

| 路径 | 说明 |
|------|------|
| `config/` | **本地配置（不进 Git）**：路径、密码、备份源 |
| `config.example/` | 可提交的模板 |
| `scripts/` | 可程序化执行的脚本 |

## Agent 强制流程（引导用户）

每次使用本技能时，**先判断意图**，再逐步引导，不要跳步闷头执行。

### 0. 意图分流

问清用户要做哪一类（可多选）：

1. **首次配置 / 改配置**
2. **备份（增量）**
3. **查看状态 / 快照列表**
4. **恢复用户文件**
5. **恢复系统配置（按模块）**

### 1. 检查配置是否就绪

```powershell
$skill = "<本技能根目录绝对路径>"
Test-Path "$skill\config\repository.env"
Test-Path "$skill\config\sources.json"
```

- **缺失** → 引导运行 `scripts/init-config.ps1`，然后让用户确认/修改：
  - `KOPIA_EXE`：kopia.exe 路径
  - `KOPIA_REPO_PATH`：仓库目标路径
  - `KOPIA_PASSWORD`：仓库密码
  - `sources.json`：备份源路径
- **已存在** → 用 `scripts/status.ps1` 或读配置，向用户复述将使用的源/目标，**征求确认**后再动。

### 2. 仓库连接

若从未 setup，或 `repository status` 失败：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\setup.ps1"
```

向用户说明：会 create 或 connect 到 `KOPIA_REPO_PATH`，并导入 `policies.json`。

### 3. 备份（增量）

确认后执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\backup.ps1"
```

可选：

- `-SkipSystemConfigExport`：跳过系统配置刷新
- `-OnlyIds user-profile,system-config`：只备指定源

备份前向用户说明：

- 会先导出 hosts / 环境变量 / 计划任务等 → `SYSTEM_CONFIG_PATH\latest`
- 再对 `sources.json` 中 enabled 源做 **snapshot create**（增量）
- 建议管理员运行（VSS、HKLM、防火墙、Wi-Fi 密钥）

结束后展示 `Done: ok=N fail=M` 与 snapshot list。

### 4. 查看状态

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\status.ps1"
```

### 5. 恢复用户文件（引导）

1. 先 list：`scripts/restore.ps1 -List`
2. 与用户确认：**快照**（`latest` 或 ID）、**源路径**、**目标目录**
3. **默认恢复到 `RESTORE_TEMP`，禁止直接覆盖正在使用的用户目录**，除非用户明确要求
4. 执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\restore.ps1" `
  -Snapshot latest `
  -SourcePath "C:\Users\Administrator" `
  -Target "I:\Backup\RestoreTemp\Administrator"
```

子路径示例：`-SubPath Downloads`

恢复后提醒：检查临时目录 → 关闭相关软件 → 再手工拷回。

### 6. 恢复系统配置（引导）

1. `import-system-config.ps1 -List` 展示模块
2. 让用户选定模块（推荐起步集）：
   `environment-user,hosts,tasks,autorun,startup-folder,run-user`
3. `environment-machine` / `hosts` / `firewall` 需**管理员**
4. 执行导入；`hkcu-full` 默认跳过（需显式 `-AllowFullHkcu`）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\import-system-config.ps1" `
  -Modules environment-user,hosts,tasks,autorun,startup-folder,run-user
```

## 脚本一览

| 脚本 | 作用 |
|------|------|
| `scripts/init-config.ps1` | 从 example 生成 `config/` |
| `scripts/setup.ps1` | 创建/连接仓库 + 导入策略 |
| `scripts/backup.ps1` | 导出系统配置 + 增量快照 |
| `scripts/status.ps1` | 状态与快照列表 |
| `scripts/restore.ps1` | 恢复快照到目标目录 |
| `scripts/export-system-config.ps1` | 仅导出系统配置 |
| `scripts/import-system-config.ps1` | 按模块导入系统配置 |

所有脚本工作目录无关：用**脚本绝对路径**调用即可。

## 配置项（`config/`，不进 Git）

| 文件 | 内容 |
|------|------|
| `repository.env` | `KOPIA_EXE`、`KOPIA_REPO_PATH`、`KOPIA_PASSWORD`、`KOPIA_CONFIG_PATH`、`SYSTEM_CONFIG_PATH`、`RESTORE_TEMP`、用户名/主机名 |
| `sources.json` | 备份源：`id` / `path` / `enabled` |
| `policies.json` | 忽略规则、保留策略、压缩、VSS |

初始化：`scripts/init-config.ps1`（已存在不覆盖，除非 `-Force`）。

## 安全与边界

- 密码在 `config/repository.env`，勿提交、勿贴到公开日志
- 不自动导入整份 HKLM；不默认整包导入 `hkcu-full`
- 本技能不处理 Program Files **软件本体**；但会导出若干安装目录内的**配置文件**（如 Easy Context Menu ini、PotPlayer ini）到 `SystemConfig/latest/apps`
- 不处理微信聊天、>1GB 单文件（由 policy 排除）；不备份 Studio 3T
- 可程序化步骤一律走 `scripts/`，不要手写临时 one-liner 替代主流程（排障除外）

## 应用配置（backup 时自动导出到 SystemConfig）

| 模块 id | 来源 | 说明 |
|---------|------|------|
| netsang | `Documents\NetSarang Computer` | Xshell/Xftp 会话与密钥（活配置） |
| easy-context-menu | 安装目录 `Files\*.ini` | 自动探测常见路径（含 `S:\Program Files\...`） |
| potplayer-mini64 / potplayer64 / potplayer-ini | HKCU + 安装目录 `.ini` | 注册表 + ini，替代手工 `.reg` 导出 |
| total-commander / total-commander-reg | 注册表 IniFileName + 安装目录 | 拷贝 `wincmd.ini` / `wcx_ftp.ini`（若存在） |
| directory-opus | `%AppData%\GPSoftware\Directory Opus` | 替代 `.ocb` |
| android-studio | `%AppData%\Google\AndroidStudio*` | 替代 `settings.jar`（不含 Local 缓存） |
| browser-essentials | 随 `user-profile` | Vimium 等在 `Local/Sync Extension Settings`，policies 保留这些路径 |

恢复用户级应用：`import-system-config.ps1 -Modules netsang,directory-opus,android-studio`（Program Files 侧 ini 需手工拷回）。

## 更多说明

模块清单、注册表策略、命令细节见 [reference.md](reference.md)。
