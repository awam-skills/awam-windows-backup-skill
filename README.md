# awam-windows-backup

本文件是技能的工程说明；权威行为规范见 [`SKILL.md`](SKILL.md)。

## 简介

Windows 本机 Kopia 增量备份与恢复（用户目录 + 系统配置导出）。 Use when the user asks to backup, restore, snapshot, 备份, 恢复, Kopia, SystemConfig, hosts/环境变量/计划任务备份, or to set up this skill's config.

## 何时使用

参见 `SKILL.md` frontmatter 的 `description` 字段所描述的触发场景。

## 主要章节

- 目录结构
- 快速上手（新机器）
- Agent 强制流程（引导用户）
- 脚本一览
- 配置项（`config/`，不进 Git）
- 安全与边界
- 应用配置（backup 时自动导出到 SystemConfig）
- 更多说明

## 目录结构

```text
SKILL.md           权威技能规范（agent 读取）
README.md          本文件，工程说明
references/        参考文档
assets/            示例与静态资源
expected_outputs/  期望输出样例（golden fixtures）
scripts/           可执行脚本（如存在）
```

> 版本：0.0.3
