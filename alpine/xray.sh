#!/usr/bin/env sh
set -eu

version=v26.7.11

version_ge() {
  [ "$2" = "$(printf '%s\n%s' "$1" "$2" | sort -V | head -n1)" ]
}

# sudo 自动检测
if command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  SUDO=""
fi

install() {
  if command -v xray >/dev/null 2>&1; then
    echo "检测到已安装 Xray：$(xray version 2>&1 | awk '/Xray/{print $2}')"
    if [ -t 0 ]; then
      read -p "是否重新安装 Xray？[y/N]: " REINSTALL_INPUT
      case "$REINSTALL_INPUT" in
        [yY]|[yY][eE][sS]) REINSTALL="y" ;;
        *) REINSTALL="n" ;;
      esac
    else
      REINSTALL="n"
    fi

    if [ "$REINSTALL" != "y" ]; then
      echo "跳过安装。"
      return 0
    fi
  fi

  arch_raw=$(uname -m)
  case "$arch_raw" in
    x86_64) zip_arch="64" ;;
    aarch64) zip_arch="arm64-v8a" ;;
    armv7l) zip_arch="arm32-v7a" ;;
    *) zip_arch="64" ;;
  esac

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  cd "$tmp"

  echo "正在下载 Xray $version ($zip_arch)..."
  wget "https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${zip_arch}.zip" -O xray.zip
  unzip xray.zip -d xray
  $SUDO install -m 755 xray/xray /usr/local/bin/xray

  $SUDO mkdir -p /etc/xray
  $SUDO mkdir -p /var/log/xray
  $SUDO touch /etc/init.d/xray

  cat <<'EOF' | $SUDO tee /etc/init.d/xray >/dev/null
#!/sbin/openrc-run

name="xray"
description="xray service"
supervisor="supervise-daemon"
command="/usr/local/bin/xray"
command_args="run -config /etc/xray/config.json"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
directory="/etc/xray"
respawn_delay=2

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
    echo "未检测到 Xray，先执行 install() 后再配置。"
    return 1
  fi

  SERVER_IP=$(curl -s4 --max-time 5 https://api.ipify.org || curl -s4 --max-time 5 https://ifconfig.me || wget -qO- -t 1 -T 5 https://api.ipify.org 2>/dev/null || echo "YOUR_SERVER_IP")

  if [ -f /etc/xray/config.json ] && [ -t 0 ]; then
    read -p "检测到已有配置文件 /etc/xray/config.json，是否重新配置？[y/N]: " RECONF_INPUT
    case "$RECONF_INPUT" in
      [yY]|[yY][eE][sS]) $SUDO rm -f /etc/xray/config.json ;;
      *) ;;
    esac
  fi

  if [ ! -f /etc/xray/config.json ]; then
    GEN_UUID=$(/usr/local/bin/xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || true)
    if [ -z "$GEN_UUID" ]; then
      GEN_UUID=$(hexdump -n 16 -e '4/1 "%02x" "-" 2/1 "%02x" "-" 2/1 "%02x" "-" 2/1 "%02x" "-" 6/1 "%02x"' /dev/urandom 2>/dev/null || echo "c2f9d863-8a3c-4e8a-9f12-0b1a2c3d4e5f")
    fi

    KEYPAIR=$(/usr/local/bin/xray x25519 2>/dev/null || true)
    PRIVATE_KEY=$(echo "$KEYPAIR" | sed -n -e 's/.*Private[kK]ey: *\([^ ]*\).*/\1/p' -e 's/.*Private key: *\([^ ]*\).*/\1/p' | head -n1)
    PUBLIC_KEY=$(echo "$KEYPAIR" | sed -n -e 's/.*Password (PublicKey): *\([^ ]*\).*/\1/p' -e 's/.*Public[kK]ey: *\([^ ]*\).*/\1/p' -e 's/.*Public key: *\([^ ]*\).*/\1/p' | head -n1)

    if [ -t 0 ]; then
      echo "=========================================="
      echo "       配置 Xray VLESS REALITY           "
      echo "=========================================="

      read -p "请输入服务端口 PORT [默认 443]: " PORT_INPUT
      PORT=${PORT_INPUT:-443}

      read -p "请输入 UUID [默认随机生成: $GEN_UUID]: " UUID_INPUT
      UUID=${UUID_INPUT:-$GEN_UUID}

      TARGET=""
      while [ -z "$TARGET" ]; do
        read -p "请输入 TARGET 目标域名/IP (必填, 如 www.apple.com): " TARGET
      done

      REALITY_DOMAIN=""
      while [ -z "$REALITY_DOMAIN" ]; do
        read -p "请输入 REALITY 伪装域名 REALITYDomain (必填, 如 www.apple.com): " REALITY_DOMAIN
      done

      read -p "请输入 Private Key [默认随机生成]: " PRIVATE_KEY_INPUT
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
  echo "Xray 安装与服务配置完成!"
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
    if [ -n "$CURRENT_VERSION" ]; then
      echo "当前 Xray 版本: $CURRENT_VERSION"
      echo "预期最低版本: $version"

      if version_ge "$CURRENT_VERSION" "$(echo "$version" | sed 's/^[vV]//')"; then
        echo "验证通过：当前版本符合或高于预期。"
      else
        echo "当前版本低于预期，建议更新。"
      fi
    fi

    if [ -t 0 ]; then
      read -p "是否执行安装/升级？[y/N]: " INSTALL_INPUT
      case "$INSTALL_INPUT" in
        [yY]|[yY][eE][sS]) install ;;
        *) ;;
      esac
    fi

    if [ -t 0 ]; then
      read -p "是否执行配置？[y/N]: " CONFIG_INPUT
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
  install
  configure
}

main "$@"

