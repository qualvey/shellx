#!/bin/sh

set -e

version=v1.14.0-alpha.47
name=${version#v}

arch_raw=$(uname -m)
case "$arch_raw" in
  x86_64)  arch=linux-amd64-musl ;;
  aarch64) arch=linux-arm64-musl ;;
  *)       arch=linux-amd64-musl ;;
esac

target="sing-box-${name}-${arch}.tar.gz"
folder="${target%.tar.gz}"
sing_box_url="https://github.com/SagerNet/sing-box/releases/download/${version}/${target}"

case "$arch_raw" in
  x86_64)  nexttrace=nexttrace-tiny_linux_amd64 ;;
  aarch64) nexttrace=nexttrace-tiny_linux_arm64 ;;
  *)       nexttrace=nexttrace-tiny_linux_amd64 ;;
esac
nexttrace_url="https://github.com/nxtrace/NTrace-core/releases/download/v1.7.1/$nexttrace"

# sudo 自动检测
if command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  SUDO=""
fi

PORT=8388
if [ -t 0 ]; then
  read -p "What port used for Shadowsocks (default: 8388): " PORT_INPUT
  if [ -n "$PORT_INPUT" ]; then PORT=$PORT_INPUT; fi
fi

# 随机生成安全密码
PASSWORD=$(head -c 16 /dev/urandom | base64 2>/dev/null | tr -d '\n/' | cut -c1-16)
if [ -z "$PASSWORD" ]; then
  PASSWORD="SecretPass8JCsPssfgS"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cd "$tmp"
echo "Downloading $sing_box_url"

wget "$sing_box_url" -O "$target" &
p1=$!
wget "$nexttrace_url" -O "$nexttrace" &
p2=$!

if wait $p1; then
  echo "sing-box download ok"
else
  echo "sing-box download failed"
  exit 1
fi

if wait $p2; then
  echo "nexttrace download ok"
else
  echo "nexttrace download failed"
fi
tar -xf "$target"

$SUDO install -m 755 "$folder/sing-box" /usr/bin/sing-box &
p3=$!

if [ -f "$nexttrace" ]; then
  $SUDO install -m 755 "$nexttrace" /usr/bin/nexttrace &
  p4=$!
  wait $p4 2>/dev/null || true
fi

wait $p3
rm -rf "$target" "$folder" "$nexttrace"

$SUDO mkdir -p /etc/sing-box
$SUDO mkdir -p /var/lib/sing-box
$SUDO touch /etc/init.d/sing-box

cat <<EOF | $SUDO tee /etc/init.d/sing-box >/dev/null
#!/sbin/openrc-run

name="sing-box"
description="sing-box service"
supervisor="supervise-daemon"
command="/usr/bin/sing-box"
command_args="-D /var/lib/sing-box -C /etc/sing-box run"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
directory="/var/lib/sing-box"
respawn_delay=2

depend() {
    need net
    after network-online
}
EOF

cat <<EOF | $SUDO tee /etc/sing-box/config.json >/dev/null
{
  "log": {
      "timestamp": true,
      "output": "box.log",
      "level": "info"
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": $PORT,
      "method": "chacha20-ietf-poly1305",
      "password": "$PASSWORD"
    }
  ]
}
EOF

$SUDO chmod +x /etc/init.d/sing-box
$SUDO rc-update add sing-box default 2>/dev/null || true
$SUDO rc-service sing-box restart 2>/dev/null || $SUDO rc-service sing-box start 2>/dev/null || true

echo "=========================================="
echo "sing-box 安装与配置完成!"
echo "Shadowsocks 端口: $PORT"
echo "Shadowsocks 加密: chacha20-ietf-poly1305"
echo "Shadowsocks 密码: $PASSWORD"
echo "=========================================="

