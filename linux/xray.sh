#!/usr/bin/env bash
set -eu

# sudo 自动检测
if command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  SUDO=""
fi

# 生成 128 bit 随机密码。优先使用 OpenSSL，缺少 OpenSSL 时使用内核
# CSPRNG（/dev/urandom）；不使用可预测的固定回退值。
generate_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  elif command -v od >/dev/null 2>&1 && [ -r /dev/urandom ]; then
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | cut -c1-32
  else
    echo "无法生成安全随机密码：缺少 openssl、od 或 /dev/urandom" >&2
    return 1
  fi
}

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

  command -v curl >/dev/null 2>&1 || {
    echo "未找到 curl，无法执行官方安装脚本。" >&2
    return 1
  }

  echo "正在通过 Xray 官方安装脚本安装/更新 Xray..."
  $SUDO bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

  $SUDO mkdir -p /etc/xray /var/log/xray

  # 官方安装脚本会安装二进制文件；服务配置在这里统一为本项目的目录结构。
  cat <<'EOF' | $SUDO tee /etc/systemd/system/xray.service >/dev/null
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/etc/xray
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  $SUDO systemctl daemon-reload
  $SUDO systemctl enable xray.service >/dev/null

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

      read -p "请输入服务端口 PORT [默认 443，输入 n 禁用 VLESS]: " PORT_INPUT
      PORT_INPUT=$(echo "$PORT_INPUT" | xargs)
      if [ "$PORT_INPUT" = "n" ] || [ "$PORT_INPUT" = "N" ]; then
        VLESS_ENABLED=false
        PORT=""
        echo "VLESS 已禁用。"
      else
        VLESS_ENABLED=true
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
      fi

      read -p "请输入 Shadowsocks 服务端口（留空禁用）: " SS_PORT_INPUT
      SS_ENABLED=false
      if [ -n "$SS_PORT_INPUT" ]; then
        SS_ENABLED=true
        SS_PORT=$(echo "$SS_PORT_INPUT" | xargs)
        read -p "请输入 Shadowsocks 密码（留空自动生成）: " SS_PASSWORD
        SS_PASSWORD=$(printf '%s' "$SS_PASSWORD" | tr -d '\r\n')
        if [ -z "$SS_PASSWORD" ]; then
          SS_PASSWORD=$(generate_password)
        elif ! printf '%s' "$SS_PASSWORD" | grep -Eq '^[A-Za-z0-9._~-]{16,}$'; then
          echo "密码必须至少 16 位，且只能包含字母、数字、点、下划线、波浪线或连字符。" >&2
          return 1
        fi
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
        \"users\": [
          {
            \"id\": \"$UUID\",
            \"email\": \"MasterUser\",
            \"flow\": \"xtls-rprx-vision\"
          }
        ],
        \"decryption\": \"none\"
      },
      \"streamSettings\": {
        \"security\": \"reality\",
        \"realitySettings\": {
          \"show\": true,
          \"target\": \"$TARGET_FULL\",
          \"serverNames\": [\"$REALITY_DOMAIN\"],
          \"privateKey\": \"$PRIVATE_KEY\",
          \"minClientVer\": \"1.1.1\",
          \"shortIds\": [\"22\"]
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
    $SUDO chmod 600 /etc/xray/config.json

    $SUDO rm -f /etc/xray/vless_link.txt
    if [ "$VLESS_ENABLED" = true ]; then
      VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${REALITY_DOMAIN}&sid=22&flow=xtls-rprx-vision#VLESS-REALITY"
      echo "$VLESS_LINK" | $SUDO tee /etc/xray/vless_link.txt >/dev/null
      $SUDO chmod 600 /etc/xray/vless_link.txt
    fi
  fi

  $SUDO systemctl daemon-reload
  $SUDO systemctl restart xray.service 2>/dev/null || $SUDO systemctl start xray.service

  if [ -f /etc/xray/vless_link.txt ]; then
    VLESS_LINK=$(cat /etc/xray/vless_link.txt)
  fi

  echo "=========================================="
  echo "Xray 安装与服务配置完成!"
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

main() {
  if command -v xray >/dev/null 2>&1; then
    CURRENT_VERSION=$(xray version 2>&1 | awk '/Xray/{print $2}' || true)
    if [ -n "$CURRENT_VERSION" ]; then
      echo "当前 Xray 版本: $CURRENT_VERSION"
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

