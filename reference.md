# AWAM Windows Backup — 参考

## 增量机制

Kopia 对源路径每次 `snapshot create` 生成可独立恢复的快照点；存储层按内容块去重。同一源重复备份 = **增量**（只上传变化块）。

## 系统配置模块

| id | 说明 | 导入需管理员 |
|----|------|--------------|
| environment-user | 用户环境变量 | 否 |
| environment-machine | 系统环境变量 | 是 |
| hosts | hosts 文件 | 是 |
| tasks | 非 Microsoft 计划任务 XML | 视任务而定 |
| autorun / command-processor-* | CMD AutoRun | 机器级需管理员 |
| run-user / run-machine | 开机 Run 键 | 机器级需管理员 |
| startup-folder | 启动文件夹快捷方式 | 公共目录需管理员 |
| explorer-shell-folders | 壳文件夹重定向 | 否 |
| explorer-advanced | 资源管理器高级选项 | 否 |
| console / international / input-method | 控制台/区域/键盘 | 否 |
| wifi / firewall | WLAN / 防火墙 | 防火墙需管理员 |
| installed-programs | 已装软件清单（只读对照） | — |
| windows-terminal / wslconfig / powercfg | 终端 / WSL / 电源 | 视情况 |
| hkcu-full | HKCU 全量归档 | 默认不导入 |
| potplayer-mini64 / potplayer64 | PotPlayer 注册表 | 否 |
| total-commander-reg | Total Commander 注册表 | 否 |
| netsang / easy-context-menu / potplayer-ini / total-commander / directory-opus / android-studio | 应用活配置（`apps/`） | 用户级可自动；安装目录 ini 需手工 |
| browser-essentials | 覆盖说明（实际随 user-profile） | — |

注册表策略：**功能模块 `.reg` + HKCU 全量归档**；不做 HKLM 整包导出/导入。

## 应用配置与浏览器扩展

- **备份方式**：`export-system-config.ps1` 在每次 `backup.ps1` 前刷新，将活配置拷到 `SYSTEM_CONFIG_PATH\latest\apps\`，并导出 PotPlayer / Total Commander 相关注册表模块。
- **Vimium / 浏览器扩展**：配置在 Chrome/Edge 的 `Local Extension Settings` 与 `Sync Extension Settings`。本机 Vimium id=`dbepggeogbaibhgnhhndojpepiihcmeb`。这些路径落在 `user-profile` 下，且 **policies 未排除**；已额外忽略 `component_crx_cache` / `File System` 等浏览器冗余，避免拖垮增量。
- **不在范围内**：Studio 3T 连接 URI / 连接库。

## 推荐恢复顺序（重装后）

1. `setup.ps1` 连接原仓库  
2. `restore.ps1` 恢复用户目录到临时路径 → 核对 → 拷回  
3. 管理员：`import-system-config.ps1 -Modules environment-user,environment-machine,hosts,tasks,run-user,startup-folder,autorun`  
4. 按需：`wifi`、`firewall`、`windows-terminal`、`netsang`、`directory-opus`、`android-studio`、`potplayer-mini64`  
5. 手工：Easy Context Menu / Total Commander / PotPlayer 的安装目录 ini（见 `apps/` 与 INDEX）

## 与旧路径的关系

本技能把脚本与配置收拢到技能目录；仓库数据仍可指向原有 `KopiaRepo`。若本机已有 `I:\Software\kopia-...\config\`，可将路径填进本技能 `config/repository.env`，共用同一仓库。
