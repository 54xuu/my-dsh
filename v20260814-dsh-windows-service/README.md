# dsh web auto-start（Windows 系统服务 + Linux systemd）

让 DeepSeek Harness 浏览器界面（`dsh web`，http://127.0.0.1:3080）开机自动启动，
无需每次手动执行 `npx @deepseek-ai/dsh web`。双平台都是**真正的系统服务**，
可用系统自带工具手动重启。

| 平台 | 机制 | 服务名 | 特权 |
| --- | --- | --- | --- |
| Windows | **NSSM 系统服务**（SCM 注册） | `dsh-web` | 安装时需管理员（脚本自动弹 UAC） |
| Linux | **systemd 单元** | `dsh-web.service` | root（脚本自动 `sudo` 提权） |

共同行为：

- 默认监听 `127.0.0.1:3080`（Linux 可 `DSH_PORT`/`DSH_HOST`，Windows 可 `-Port`/`-HostAddr` 覆盖）
- **开机自启**、**崩溃自动重启**（NSSM 5 秒延迟 / systemd `Restart=always`）
- 日志：Windows → `%LOCALAPPDATA%\dsh-service\logs\`（10MB 轮转）；Linux → journald

## Windows

前置：Node.js 在 PATH 中。安装脚本需要管理员权限（会自动弹 UAC，点击允许即可）。

```powershell
cd v20260814-dsh-windows-service

.\install.ps1          # 一键：停掉 3080 现有实例 → 清理旧计划任务/旧服务 → 装服务 → 启动 → 验证
.\install.ps1 status   # 服务状态 + 端口监听
.\install.ps1 restart  # 手动重启服务
.\install.ps1 stop / start
.\install.ps1 uninstall
```

> ⚠️ `install` 会先**杀掉当前占用 3080 的进程**（包括正在手动运行的 `dsh web`），
> 然后安装并启动服务 —— 期间当前浏览器页面会短暂断连，刷新后会话仍在（会话持久化在磁盘）。

安装脚本执行顺序（按需求）：

1. **停掉 3080 现有实例**（`Get-NetTCPConnection` → `Stop-Process`）
2. 清理：注销旧的「At logon」计划任务 `dsh-web-autostart`；若已存在 `dsh-web` 服务则先删除（可重复安装）
3. 确保全局 `@deepseek-ai/dsh`（缺失则 `npm i -g`）+ 下载 NSSM 2.24（nssm.cc，缓存到 `%LOCALAPPDATA%\dsh-service\bin`）
4. `nssm install dsh-web`：以 **LocalSystem** 运行 `node.exe <bin.js> web --host 127.0.0.1 --port 3080`，
   注入用户环境变量 `USERPROFILE/HOME/DSH_HOME/PATH`（服务因此能找到 `C:\Users\<你>\.dsh` 的配置与凭据）
5. 配置：开机自启（`SERVICE_AUTO_START`）、崩溃 5 秒后自动重启、日志 10MB 轮转
6. `nssm start` 启动服务
7. 轮询 `http://127.0.0.1:3080` 直到返回 200，输出结果

手动重启（任选其一）：

```powershell
net stop dsh-web && net start dsh-web     # 命令行
Restart-Service dsh-web                   # PowerShell
# 或 services.msc 里找到 dsh-web 右键 → 重新启动
```

自定义 / 离线安装：

```powershell
.\install.ps1 install -Port 8080 -HostAddr 0.0.0.0   # 注意 0.0.0.0 会暴露到局域网（无鉴权）
.\install.ps1 install -NssmPath D:\tools\nssm.exe    # 离线时指定已有的 nssm.exe，跳过下载
```

为什么可以用 SYSTEM 账户：`.credentials.yaml` 是明文存储，SYSTEM 可读；
通过注入 `USERPROFILE/HOME/DSH_HOME` 让 dsh 找到你的配置，无需存账户密码。

## Linux

前置：systemd、Node.js，且目标用户可解析 dsh（推荐 `npm i -g @deepseek-ai/dsh`）。

```bash
cd v20260814-dsh-windows-service
chmod +x install.sh

./install.sh              # 探测路径 → 写 unit → systemctl enable --now（自动 sudo）
./install.sh status       # systemctl status dsh-web
./install.sh restart
./install.sh uninstall
```

环境变量覆盖：`DSH_PORT`、`DSH_HOST`、`DSH_USER`、`DSH_NODE`、`DSH_BINJS`、`DSH_HOME_DIR`。

生成的 unit（`/etc/systemd/system/dsh-web.service`）通过小包装脚本
（`/usr/local/libexec/dsh-web/dsh-web-run.sh`）启动，端口被占用时自动让行；日志走 journald。

## 更新 dsh

```powershell
npm i -g @deepseek-ai/dsh@latest
.\install.ps1 restart            # Windows（NSSM 会拉起新版本进程）
```

```bash
sudo npm i -g @deepseek-ai/dsh@latest
sudo ./install.sh restart        # Linux
```

## FAQ

- **安装后 3080 无响应？** 看 `%LOCALAPPDATA%\dsh-service\logs\dsh-web.err.log`，然后 `.\install.ps1 restart`。
- **服务启动了但端口没起来？** `.\install.ps1 status` 看服务状态；若服务反复重启，多半是 node/dsh 路径问题，重跑 install 即可。
- **换 Windows 密码会影响服务吗？** 不会 —— 服务以 SYSTEM 运行，不依赖账户密码。
- **想停用开机自启？** `.\install.ps1 uninstall`（或 services.msc 里把 dsh-web 启动类型改为手动）。
- **NSSM 下载失败（离线）？** 手动下载 nssm-2.24（https://nssm.cc/download），用 `-NssmPath` 传入。
