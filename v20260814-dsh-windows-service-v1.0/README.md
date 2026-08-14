# dsh web auto-start (Windows + Linux)

Scripts that make the DeepSeek Harness browser UI (`dsh web`, http://127.0.0.1:3080)
start automatically — without any manual `npx @deepseek-ai/dsh web` at every boot.

## What it does

| Platform | Mechanism | Privilege needed |
| --- | --- | --- |
| Windows | Task Scheduler **"At logon"** task | none (runs as your user) |
| Linux   | **systemd** unit (`dsh-web.service`) | root (script self-elevates via `sudo`) |

Both scripts share the same behavior contract:

- Start `dsh web` on `127.0.0.1:3080` by default (override with `DSH_PORT`/`DSH_HOST` on Linux, `-Port`/`-HostAddr` on Windows).
- **Port collision → leave it alone**: if something already listens on the port, log it and exit cleanly. It never kills a live session.
- **Crash → retry**: Windows task restarts up to 3× (1 min apart); Linux unit `Restart=always` with 5 s delay.
- Logs: Windows → `%LOCALAPPDATA%\dsh-service\dsh-web.log` (+ `dsh-web.stdout.log` / `dsh-web.stderr.log`); Linux → journald (`journalctl -u dsh-web`).

> Why "At logon" and not a real Windows service? `dsh web` binds `127.0.0.1`, so
> only this machine can reach it — a pre-login service has no one to serve. An
> at-logon task runs with your exact environment (`.dsh` credentials, node),
> needs no admin, and needs no stored password.

## Windows

Prerequisites: Node.js on PATH. No admin required.

```powershell
cd v20260814-dsh-windows-service-v1.0

.\install.ps1              # one-time setup (see below) and register the task
.\install.ps1 test-start   # non-destructive smoke test on :3081 (HTTP 200 then stop)
.\install.ps1 status       # task state + port listener + dsh version
.\install.ps1 start        # start now (leaves an existing instance alone)
.\install.ps1 restart      # force restart of the instance on the configured port
.\install.ps1 stop         # stop task + kill the listener
.\install.ps1 uninstall    # remove task + files  (-RemoveGlobalDsh also npm-uninstalls)
```

`install` performs:

1. `npm install -g @deepseek-ai/dsh` — a **global** install so the task never
   depends on the transient `npx` cache (which npm prunes over time).
2. Writes `config.json` + `dsh-web-launcher.ps1` under `%LOCALAPPDATA%\dsh-service`
   (absolute paths to `node.exe` and dsh's `bin.js`, recorded at install time).
3. Registers the scheduled task `dsh-web-autostart`: trigger **At logon** of your
   user, hidden window, restart-on-failure 3×/1 min.

Then `dsh web` comes up automatically at your next logon. To take over an already
running instance, use `.\install.ps1 restart` once.

Customize at install time, e.g.:

```powershell
.\install.ps1 install -Port 8080 -HostAddr 0.0.0.0 -TaskName my-dsh
```

(Note: binding `0.0.0.0` exposes the UI on your LAN — no auth; only do this on a
trusted network.)

## Linux

Prerequisites: systemd, Node.js, and dsh resolvable for the target user
(`npm i -g @deepseek-ai/dsh` is the recommended install method).

```bash
cd v20260814-dsh-windows-service-v1.0
chmod +x install.sh

./install.sh              # detect paths, write unit, systemctl enable --now (self-elevates)
./install.sh status       # systemctl status dsh-web
./install.sh restart
./install.sh uninstall
```

Env overrides: `DSH_PORT`, `DSH_HOST`, `DSH_USER`, `DSH_NODE`, `DSH_BINJS`, `DSH_HOME_DIR`.

The generated unit (`/etc/systemd/system/dsh-web.service`) runs a small wrapper
(`/usr/local/libexec/dsh-web/dsh-web-run.sh`) that leaves an existing listener on
the port alone — same semantics as Windows. Logs go to journald.

## Updating dsh

```powershell
npm i -g @deepseek-ai/dsh@latest
.\install.ps1 restart          # Windows
```

```bash
sudo npm i -g @deepseek-ai/dsh@latest
sudo ./install.sh restart      # Linux
```

## FAQ

- **Task starts but nothing listens?** Check `%LOCALAPPDATA%\dsh-service\dsh-web.log`
  and `dsh-web.stderr.log`; then `.\install.ps1 restart`.
- **Port already in use when the task fires?** It logs and exits — your running
  instance is left untouched by design.
- **After an install you moved/deleted this repo folder?** No problem — the task
  points at `%LOCALAPPDATA%\dsh-service`, not at the repo.
- **Want a real (pre-login) Windows service instead?** Not recommended while the
  UI binds `127.0.0.1`; it would need admin and add nothing reachable before login.
