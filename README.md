# my-dsh

个人工具笔记仓库：以记笔记的方式，记录每天为 DeepSeek Harness (dsh) 写的工具。

## 命名规范

每个工具一个目录，目录名遵循：

```
v<YYYYMMDD>-<工具名>
```

- `v<YYYYMMDD>`：日期版本 —— 记录编写当天（如 `v20260814` = 2026-08-14）
- `<工具名>`：工具名称

工具的**真正版本号不打在目录名里**，而是在发版时用 git tag 标记，如 `v1.0`、`v1.1`。

示例：`v20260814-dsh-windows-service` = 2026-08-14 为 dsh 写的「Windows 系统服务」工具，发版 tag 为 `v1.0`。

## 工具列表

| 目录 | 日期 | 版本(tag) | 平台 | 说明 |
| --- | --- | --- | --- | --- |
| [v20260814-dsh-windows-service](v20260814-dsh-windows-service/) | 2026-08-14 | v1.0 | Windows / Linux | dsh web 开机自动启动工具。Windows 为真正的系统服务（NSSM 封装 node，开机自启、崩溃自动重启、services.msc 可手动重启），Linux 用 systemd 单元；安装脚本自动「停旧 → 装新 → 启动」，日志轮转落盘 |

## 新增工具

1. 新建目录：`v$(date +%Y%m%d)-<工具名>`
2. 工具目录内附 `README.md` 说明用法
3. 更新本文件的工具列表（表格）
4. 发版时打 tag：`git tag v1.0 && git push origin v1.0`
