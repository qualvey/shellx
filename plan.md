# ShellX 实现计划

## 1. xray.sh 增强
- [x] 检查是否有 sudo，无 sudo 时直接运行命令。
- [x] 为 OpenRC 服务脚本添加 `supervisor="supervise-daemon"` 和 `respawn_delay=2`（进程崩溃自动重启）。
- [x] 增加默认 `/etc/xray/config.json` 配置文件自动生成与端口/密码设置。
- [x] 脚本安装完成后自动启动/重启 `rc-service xray start`。
- [x] 增加 x86_64 / aarch64 多 CPU 架构自动检测与下载。

## 2. sing-box.sh 优化
- [x] 检查是否有 sudo，无 sudo 时直接运行命令。
- [x] 将硬编码的 Shadowsocks 密码改为动态随机生成（并支持交互式输入/自定义）。
- [x] 增加 x86_64 / aarch64 多 CPU 架构自动检测与下载。
- [x] 增加版本检测与更完善的进程守护管理。

## 3. 文档更新
- [x] 更新 `readme.md` 包含部署后参数说明及架构要求。
