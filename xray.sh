#!/bin/sh
set -eu

# 统一入口只负责分发，不包含 Xray 的安装逻辑。
# 当前各平台脚本位于 master；完成版本提交后应改为对应的不可变 commit。
BASE_URL="https://raw.githubusercontent.com/qualvey/shellx/master"

die() {
    echo "错误：$*" >&2
    exit 1
}

command -v uname >/dev/null 2>&1 || die "未找到 uname"

ARCH=$(uname -m)
case "$ARCH" in
    x86_64|aarch64|armv7l)
        ;;
    *)
        die "暂不支持 CPU 架构：$ARCH"
        ;;
esac

if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
else
    die "未找到 /etc/os-release，无法识别操作系统"
fi

# 当前只区分 OpenRC 和 systemd：
# - Alpine 及其他 OpenRC 系统使用 alpine 实现
# - systemd 系统使用 linux 实现
if command -v rc-service >/dev/null 2>&1; then
    TARGET="alpine/xray.sh"
    RUNNER="sh"
    SERVICE_MANAGER="OpenRC"
elif command -v systemctl >/dev/null 2>&1; then
    TARGET="linux/xray.sh"
    RUNNER="bash"
    SERVICE_MANAGER="systemd"
else
    die "未检测到支持的服务管理器（需要 rc-service 或 systemctl）"
fi

command -v "$RUNNER" >/dev/null 2>&1 || die "未找到执行环境：$RUNNER"

if command -v curl >/dev/null 2>&1; then
    FETCH="curl -fsSL"
elif command -v wget >/dev/null 2>&1; then
    FETCH="wget -qO-"
else
    die "需要 curl 或 wget 才能下载远程脚本"
fi

TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t shellx-xray)
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM
SCRIPT_PATH="$TMP_DIR/xray.sh"

echo "检测到系统：${PRETTY_NAME:-${ID:-unknown}}"
echo "服务管理器：$SERVICE_MANAGER"
echo "CPU 架构：$ARCH"
echo "正在加载：$TARGET"

# FETCH 只由上面的固定命令组成，URL 使用双引号传入。
if [ "$FETCH" = "curl -fsSL" ]; then
    curl -fsSL "$BASE_URL/$TARGET" > "$SCRIPT_PATH"
else
    wget -qO- "$BASE_URL/$TARGET" > "$SCRIPT_PATH"
fi

[ -s "$SCRIPT_PATH" ] || die "远程脚本为空：$TARGET"

exec "$RUNNER" "$SCRIPT_PATH" "$@"
