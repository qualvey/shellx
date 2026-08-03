# ShellX - Alpine Linux 一键部署脚本

适用于 Alpine Linux (OpenRC) 的轻量级代理服务一键安装脚本工具包。支持 `x86_64` 与 `aarch64` 架构，支持 `sudo` 环境自适应及服务崩溃自动重启。

---

## 1. 安装 sing-box

默认部署 Shadowsocks 协议（包含 NextTrace 路由追踪工具），自动随机生成安全密码。

```shell
sh <(curl -Ls https://raw.githubusercontent.com/qualvey/shellx/master/alpine/sing-box.sh)
```

**特点：**
- 服务路径：`/usr/bin/sing-box`
- 配置文件：`/etc/sing-box/config.json`
- OpenRC 服务：`rc-service sing-box status|start|stop|restart`
- 自动检测 `sudo` 权限，防止缺失 `sudo` 报错

---

## 2. 安装 Xray

部署最新稳定版 Xray，自动配置 OpenRC 服务守护进程（守护崩溃自动重启）及默认 Shadowsocks 配置。

```shell
sh <(curl -Ls https://raw.githubusercontent.com/qualvey/shellx/master/alpine/xray.sh)
```

**特点：**
- 服务路径：`/usr/local/bin/xray`
- 配置文件：`/etc/xray/config.json`
- OpenRC 服务：`rc-service xray status|start|stop|restart`
- 自动检测版本及 CPU 架构（`x86_64` / `aarch64` / `armv7l`）
