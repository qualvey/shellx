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
  # 提取 Private Key
  PRIVATE_KEY=$(echo "$KEYPAIR" | awk '{for(i=1;i<=NF;i++) if($i=="PrivateKey:") print $(i+1)}')

  # 提取 Public Key
  PUBLIC_KEY=$(echo "$KEYPAIR" | awk '{for(i=1;i<=NF;i++) if($i=="(PublicKey):") print $(i+1)}')

    if [ -t 0 ]; then
      echo "=========================================="
      echo "           配置 Xray VLESS REALITY        "
      echo "=========================================="

      read -p "请输入服务端口 PORT [默认 443，输入 n 禁用 VLESS]: " PORT_INPUT
      PORT_INPUT=$(echo "$PORT_INPUT" | xargs)
      if [ "$PORT_INPUT" = "n" ] || [ "$PORT_INPUT" = "N" ]; then
        VLESS_ENABLED=false
        PORT=""
        echo "VLESS 已禁用。"
      else
        VLESS_ENABLED=true
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
      fi

      read -p "请输入 Shadowsocks 服务端口（留空禁用）: " SS_PORT_INPUT
      SS_ENABLED=false
      if [ -n "$SS_PORT_INPUT" ]; then
        SS_ENABLED=true
        SS_PORT=$(echo "$SS_PORT_INPUT" | xargs)
        read -p "请输入 Shadowsocks 密码（留空自动生成）: " SS_PASSWORD
        if [ -z "$SS_PASSWORD" ]; then
          SS_PASSWORD=$(head -c 16 /dev/urandom | base64 2>/dev/null | tr -d '\n/' | cut -c1-16)
          [ -z "$SS_PASSWORD" ] && SS_PASSWORD="SecretPass8JCs"
        fi
        SS_PASSWORD=$(echo "$SS_PASSWORD" | xargs)
      fi
    else
      PORT=443
      VLESS_ENABLED=true
      UUID="$GEN_UUID"
      TARGET="www.apple.com"
      REALITY_DOMAIN="www.apple.com"
      SS_ENABLED=false
    fi

    if [ "$VLESS_ENABLED" = true ]; then
      case "$TARGET" in
        *:*) TARGET_FULL="$TARGET" ;;
        *) TARGET_FULL="${TARGET}:443" ;;
      esac
    fi

    VLESS_INBOUND=""
    if [ "$VLESS_ENABLED" = true ]; then
      VLESS_INBOUND="{
      \"protocol\": \"vless\",
      \"port\": $PORT,
      \"tag\": \"reality\",
      \"settings\": {
        \"users\": [{\"id\": \"$UUID\", \"email\": \"MasterUser\", \"flow\": \"xtls-rprx-vision\"}],
        \"decryption\": \"none\"
      },
      \"streamSettings\": {
        \"security\": \"reality\",
        \"realitySettings\": {
          \"show\": true, \"target\": \"$TARGET_FULL\", \"serverNames\": [\"$REALITY_DOMAIN\"],
          \"privateKey\": \"$PRIVATE_KEY\", \"minClientVer\": \"1.1.1\", \"shortIds\": [\"22\"]
        }
      }
    }"
    fi

    SS_INBOUND=""
    if [ "$SS_ENABLED" = true ]; then
      if [ "$VLESS_ENABLED" = true ]; then
        SS_INBOUND=",
    "
      else
        SS_INBOUND=""
      fi
    SS_INBOUND="${SS_INBOUND}{
      \"listen\": \"::\",
      \"port\": $SS_PORT,
      \"tag\": \"ss-in\",
      \"sniffing\": {
        \"enabled\": true
      },
      \"protocol\": \"shadowsocks\",
      \"settings\": {
        \"network\": \"tcp,udp\",
        \"method\": \"chacha20-ietf-poly1305\",
        \"password\": \"$SS_PASSWORD\"
      }
    }"
    fi

    cat <<EOF | $SUDO tee /etc/xray/config.json >/dev/null
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    $VLESS_INBOUND$SS_INBOUND
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

    $SUDO rm -f /etc/xray/vless_link.txt
    if [ "$VLESS_ENABLED" = true ]; then
      VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${REALITY_DOMAIN}&sid=22&flow=xtls-rprx-vision#VLESS-REALITY"
      echo "$VLESS_LINK" | $SUDO tee /etc/xray/vless_link.txt >/dev/null
    fi
  fi

  $SUDO rc-service xray restart 2>/dev/null || $SUDO rc-service xray start 2>/dev/null || true

  if [ -f /etc/xray/vless_link.txt ]; then
    VLESS_LINK=$(cat /etc/xray/vless_link.txt)
  fi

  echo "=========================================="
  echo "Xray 配置完成!"
  echo "配置路径: /etc/xray/config.json"
  if [ "${SS_ENABLED:-false}" = true ]; then
    echo "Shadowsocks 端口: $SS_PORT"
    echo "Shadowsocks 加密: chacha20-ietf-poly1305"
    echo "Shadowsocks 密码: $SS_PASSWORD"
  fi
  if [ -n "${VLESS_LINK:-}" ]; then
    echo ""
    echo "客户端 VLESS 链接:"
    echo "$VLESS_LINK"
  fi
  echo "=========================================="
}

shadowsocks() {
  if command -v xray >/dev/null 2>&1; then
    echo "检测到 Xray 已安装，跳过 Shadowsocks 安装。"
    return 0
  fi

  echo "正在安装 Shadowsocks..."
  $SUDO apk add --no-cache shadowsocks-libev
  echo "Shadowsocks 安装完成。"
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
