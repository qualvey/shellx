#!/usr/bin/env sh
set -e

version=v26.7.11
CURRENT_VERSION=$(xray version 2>&1 | awk '/Xray/{print $2}')
version_ge() {
  [ "$2" = "$(printf '%s\n%s' "$1" "$2" | sort -V | head -n1)" ]
}

if [ -n "$CURRENT_VERSION" ]; then
  echo "当前 Xray 版本: $CURRENT_VERSION"
  echo "预期最低版本: $version"

  if version_ge "$CURRENT_VERSION" $(echo "$version" | sed 's/^[vV]//'); then
    echo "验证通过：当前版本符合或高于预期。"
    exit 0
  fi
else
  echo "提示：未检测到 Xray 安装，自动跳过版本检查（默认通过）。"
fi

# sudo 自动检测
if command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  SUDO=""
fi

arch_raw=$(uname -m)
case "$arch_raw" in
  x86_64)  zip_arch="64" ;;
  aarch64) zip_arch="arm64-v8a" ;;
  armv7l)  zip_arch="arm32-v7a" ;;
  *)       zip_arch="64" ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

echo "正在下载 Xray $version ($zip_arch)..."
wget https://github.com/XTLS/Xray-core/releases/download/"$version"/Xray-linux-"$zip_arch".zip -O xray.zip
unzip xray.zip -d xray
$SUDO install -m 755 xray/xray /usr/local/bin/xray

$SUDO mkdir -p /etc/xray
$SUDO mkdir -p /var/log/xray
$SUDO touch /etc/init.d/xray

cat <<EOF | $SUDO tee /etc/init.d/xray >/dev/null
#!/sbin/openrc-run

name="xray"
description="xray service"
supervisor="supervise-daemon"
command="/usr/local/bin/xray"
command_args="run -config /etc/xray/config.json"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
directory="/etc/xray"
respawn_delay=2

depend() {
    need net
    after network-online
}
EOF

PORT=10808
PASSWORD=$(head -c 16 /dev/urandom | base64 2>/dev/null | tr -d '\n/' | cut -c1-16)
if [ -z "$PASSWORD" ]; then PASSWORD="SecretXrayPass123"; fi

if [ ! -f /etc/xray/config.json ]; then
  if [ -t 0 ]; then
    read -p "What port used for Xray Shadowsocks (default: 10808): " PORT_INPUT
    if [ -n "$PORT_INPUT" ]; then PORT=$PORT_INPUT; fi
  fi

cat <<EOF | $SUDO tee /etc/xray/config.json >/dev/null
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "shadowsocks",
      "settings": {
        "method": "chacha20-ietf-poly1305",
        "password": "$PASSWORD",
        "network": "tcp,udp"
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF
fi

$SUDO chmod +x /etc/init.d/xray
$SUDO rc-update add xray default 2>/dev/null || true
$SUDO rc-service xray restart 2>/dev/null || $SUDO rc-service xray start 2>/dev/null || true

echo "=========================================="
echo "Xray 安装与服务配置完成!"
echo "配置路径: /etc/xray/config.json"
echo "Shadowsocks 端口: $PORT"
echo "Shadowsocks 密码: $PASSWORD"
echo "=========================================="

