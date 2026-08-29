#!/usr/bin/env sh
set -eu

version=v26.7.11

if command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  SUDO=""
fi

install_xray() {
  arch_raw=$(uname -m)
  case "$arch_raw" in
    x86_64) zip_arch="64" ;;
    aarch64) zip_arch="arm64-v8a" ;;
    armv7l) zip_arch="arm32-v7a" ;;
    *) zip_arch="64" ;;
  esac

  # 在 /dev/shm 内存中创建临时目录以绕过小磁盘配额限制
  TMP_DIR="/tmp"
  [ -d "/dev/shm" ] && TMP_DIR="/dev/shm"
  tmp=$(mktemp -d -p "$TMP_DIR")
  trap 'rm -rf "$tmp"' EXIT
  cd "$tmp"

  echo "正在下载 Xray $version ($zip_arch)..."
  wget -q "https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${zip_arch}.zip" -O xray.zip
  
  # 仅解压二进制文件，避免 geoip/geosite 撑爆限额
  unzip -q -o xray.zip xray -d .
  rm -f xray.zip

  $SUDO install -m 755 xray /usr/local/bin/xray
  $SUDO mkdir -p /etc/xray /var/log/xray
  cd /
  rm -rf "$tmp"
  cat <<'EOF' | $SUDO tee /etc/init.d/xray >/dev/null
#!/sbin/openrc-run

name="xray"
description="xray service"
command="/usr/local/bin/xray"
command_args="run -config /etc/xray/config.json"
command_background=true
pidfile="/run/xray.pid"
directory="/etc/xray"

depend() {
    need net
    after network-online
}
EOF

  $SUDO chmod +x /etc/init.d/xray
  $SUDO rc-update add xray default 2>/dev/null || true

  echo "Xray 安装完成。"
}

configure() {
  if ! command -v xray >/dev/null 2>&1; then
    echo "未检测到 Xray，请先执行安装。"
    return 1
  fi

  SERVER_IP=$(curl -s4 --max-time 5 https://api.ipify.org || curl -s4 --max-time 5 https://ifconfig.me || echo "YOUR_SERVER_IP")

  if [ -f /etc/xray/config.json ] && [ -t 0 ]; then
    read -p "检测到已有配置文件 /etc/xray/config.json，是否重新配置？[y/N]: " RECONF_INPUT
    case "$RECONF_INPUT" in
      [yY]|[yY][eE][sS]) $SUDO rm -f /etc/xray/config.json ;;
      *) ;;
    esac
  fi

  if [ ! -f /etc/xray/config.json ]; then
    GEN_UUID=$(/usr/local/bin/xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "c2f9d863-8a3c-4e8a-9f12-0b1a2c3d4e5f")
    KEYPAIR=$(/usr/local/bin/xray x25519 2>/dev/null || true)
    PRIVATE_KEY=$(echo "$KEYPAIR" | awk -F': ' '/[Pp]rivate [Kk]ey/ {print $2}' | tr -d ' \r\n')
    PUBLIC_KEY=$(echo "$KEYPAIR" | awk -F': ' '/[Pp]ublic [Kk]ey|Password \(PublicKey\)/ {print $2}' | tr -d ' \r\n')

    if [ -t 0 ]; then
      echo "=========================================="
      echo "           配置 Xray VLESS REALITY        "
      echo "=========================================="

      read -p "请输入服务端口 PORT [默认 443]: " PORT_INPUT
      PORT=${PORT_INPUT:-443}

      read -p "请输入 UUID [默认: $GEN_UUID]: " UUID_INPUT
      UUID=${UUID_INPUT:-$GEN_UUID}

      TARGET=""
      while [ -z "$TARGET" ]; do
        read -p "请输入 TARGET 目标域名/IP (如 www.apple.com): " TARGET
      done

      REALITY_DOMAIN=""
      while [ -z "$REALITY_DOMAIN" ]; do
        read -p "请输入 REALITY 伪装域名 (如 www.apple.com): " REALITY_DOMAIN
      done

      read -p "请输入 Private Key [默认自动生成]: " PRIVATE_KEY_INPUT
      if [ -n "$PRIVATE_KEY_INPUT" ]; then
        PRIVATE_KEY="$PRIVATE_KEY_INPUT"
        read -p "请输入对应的 Public Key: " PUBLIC_KEY
      fi
    else
      PORT=443
      UUID="$GEN_UUID"
      TARGET="www.apple.com"
      REALITY_DOMAIN="www.apple.com"
    fi

    case "$TARGET" in
      *:*) TARGET_FULL="$TARGET" ;;
      *) TARGET_FULL="${TARGET}:443" ;;
    esac

    cat <<EOF | $SUDO tee /etc/xray/config.json >/dev/null
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "protocol": "vless",
      "port": $PORT,
      "tag": "reality",
      "settings": {
        "users": [
          {
            "id": "$UUID",
            "email": "MasterUser",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "security": "reality",
        "realitySettings": {
          "show": true,
          "target": "$TARGET_FULL",
          "serverNames": [
            "$REALITY_DOMAIN"
          ],
          "privateKey": "$PRIVATE_KEY",
          "minClientVer": "1.1.1",
          "shortIds": [
            "22"
          ]
        }
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

    VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${REALITY_DOMAIN}&sid=22&flow=xtls-rprx-vision#VLESS-REALITY"
    echo "$VLESS_LINK" | $SUDO tee /etc/xray/vless_link.txt >/dev/null
  fi

  $SUDO rc-service xray restart 2>/dev/null || $SUDO rc-service xray start 2>/dev/null || true

  if [ -f /etc/xray/vless_link.txt ]; then
    VLESS_LINK=$(cat /etc/xray/vless_link.txt)
  fi

  echo "=========================================="
  echo "Xray 配置完成!"
  echo "配置路径: /etc/xray/config.json"
  if [ -n "${VLESS_LINK:-}" ]; then
    echo ""
    echo "客户端 VLESS 链接:"
    echo "$VLESS_LINK"
  fi
  echo "=========================================="
}

main() {
  if command -v xray >/dev/null 2>&1; then
    CURRENT_VERSION=$(xray version 2>&1 | awk '/Xray/{print $2}' || true)
    echo "当前 Xray 版本: $CURRENT_VERSION"

    if [ -t 0 ]; then
      read -p "检测到已安装 Xray，是否重新安装/更新？[y/N]: " INSTALL_INPUT
      case "$INSTALL_INPUT" in
        [yY]|[yY][eE][sS]) install_xray ;;
        *) ;;
      esac

      read -p "是否重新执行配置？[y/N]: " CONFIG_INPUT
      case "$CONFIG_INPUT" in
        [yY]|[yY][eE][sS]) configure ;;
        *) ;;
      esac
    else
      configure
    fi
    return 0
  fi

  echo "未检测到 Xray，开始安装..."
  install_xray
  configure
}

main "$@"