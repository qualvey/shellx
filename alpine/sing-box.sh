#!/bin/sh

set -eu

version=v1.14.0-alpha.47
name=${version#v}
# sudo 自动检测
if command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  SUDO=""
fi
DEPENDENCIES="curl jq"

ALL_DEPS_INSTALLED=true
MISSED_DEPS=""

arch_raw=$(uname -m)
case "$arch_raw" in
  x86_64)  arch=linux-amd64-musl ;;
  aarch64) arch=linux-arm64-musl ;;
  *)       arch=linux-amd64-musl ;;
esac
case "$arch_raw" in
  x86_64)  nexttrace=nexttrace-tiny_linux_amd64 ;;
  aarch64) nexttrace=nexttrace-tiny_linux_arm64 ;;
  *)       nexttrace=nexttrace-tiny_linux_amd64 ;;
esac

for cmd in $DEPENDENCIES; do 
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "$cmd was installed"
    else
        echo "miss $cmd"
        ALL_DEPS_INSTALLED=false
        MISSED_DEPS="$MISSED_DEPS $cmd"
    fi
done 

# 退出或收到中断信号时，终止所有后台子任务
cleanup() {
  # 忽略后续信号避免重复触发，向整个进程组发送 SIGTERM
  trap - SIGINT SIGTERM EXIT
  kill 0 2>/dev/null
}
trap cleanup SIGINT SIGTERM EXIT

install_curl() {
  echo "installing  curl"
  apk add curl
}

install_sing_box() {
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  cd "$tmp"

  target="sing-box-${name}-${arch}.tar.gz"
  folder="${target%.tar.gz}"
  sing_box_url="https://github.com/SagerNet/sing-box/releases/download/${version}/${target}"
  echo "Downloading $sing_box_url"

  wget "$sing_box_url" -O "$target" &
  p1=$!
  if wait $p1; then
  echo "sing-box download ok"
  else
    echo "sing-box download failed"
    exit 1
  fi

  tar -xf "$target"

  $SUDO install -m 755 "$folder/sing-box" /usr/bin/sing-box &
  p3=$!
  wait $p3
  rm -rf "$target" "$folder"

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

  echo "$CONFIG" | jq . | $SUDO tee /etc/sing-box/config.json >/dev/null

  $SUDO chmod +x /etc/init.d/sing-box
  $SUDO rc-update add sing-box default 2>/dev/null || true

  # 初始基础结构
CONFIG=$(jq -n '{
  log: { timestamp: true, output: "box.log", level: "info" },
  inbounds: []
}')
SS_ENABLED=false
TUIC_ENABLED=false

if [ -t 0 ]; then
  read -p "What port used for Shadowsocks (Leave empty to disable shadowsocks): " PORT_INPUT
  if [ -n "$PORT_INPUT" ]; then PORT=$PORT_INPUT; SS_ENABLED=true; fi
  if [ "$SS_ENABLED" = true ]; then
    echo "Shadowsocks will be enabled on port $PORT"
    read -p "Shadowsocks password (Leave empty to auto-generate): " PASSWORD
    if [ -z "$PASSWORD" ]; then
      PASSWORD=$(head -c 16 /dev/urandom | base64 2>/dev/null | tr -d '\n/' | cut -c1-16)
      if [ -z "$PASSWORD" ]; then
        PASSWORD="SecretPass8JCs"
      fi
    fi
    PORT=$(echo "$PORT" | xargs)
    PASSWORD=$(echo "$PASSWORD" | xargs)

    CONFIG=$(echo "$CONFIG" | jq \
    --argjson port "$PORT" \
    --arg password "$PASSWORD" \
    '.inbounds+=[
    {"type": "shadowsocks",
    "tag": "ss-in",
    "listen": "::",
    "listen_port": $port,
    "method": "chacha20-ietf-poly1305",
    "password": $password
      }
    ]')
  else
    echo "Shadowsocks will be disabled"
  fi
fi

read -p "Enable TUIC? (Y/n): " ENABLE_TUIC
ENABLE_TUIC=${ENABLE_TUIC:-y}

if [ -t 0 ] && { [ "$ENABLE_TUIC" = "y" ] || [ "$ENABLE_TUIC" = "Y" ]; }; then
  TUIC_ENABLED=true
  # 1. 端口
  read -p "What port used for TUIC (default: 443): " TUIC_PORT_INPUT
  TUIC_PORT=${TUIC_PORT_INPUT:-443}

  read -p "tuic uuid (leave empty to auto-generate): " TUIC_UUID
  if [ -z "$TUIC_UUID" ]; then
    if command -v sing-box >/dev/null 2>&1; then
      TUIC_UUID=$(sing-box generate uuid)
    elif [ -f /proc/sys/kernel/random/uuid ]; then
      TUIC_UUID=$(cat /proc/sys/kernel/random/uuid)
    else
      echo "Cannot generate UUID (sing-box not installed). Please specify manually."
      exit 1
    fi
  fi

  read -p "tuic password (leave empty to auto-generate): " TUIC_PASSWORD
  if [ -z "$TUIC_PASSWORD" ]; then
    TUIC_PASSWORD=$(head -c 32 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 16)
    [ -z "$TUIC_PASSWORD" ] && TUIC_PASSWORD="SecretTUICPass8JCs"
  fi


  read -p "Domain for certificate (e.g. example.com): " DOMAIN
  read -p "Cloudflare API token: " CLOUDFLARE_API_TOKEN
  if [ -z "$DOMAIN" ] || [ -z "$CLOUDFLARE_API_TOKEN" ]; then
    echo "Error: Domain and Cloudflare API token are required."
    exit 1
  fi
  #去除空格
  TUIC_PORT=$(echo "$TUIC_PORT" | xargs)
  TUIC_UUID=$(echo "$TUIC_UUID" | xargs)
  TUIC_PASSWORD=$(echo "$TUIC_PASSWORD" | xargs)
  DOMAIN=$(echo "$DOMAIN" | xargs)
  CLOUDFLARE_API_TOKEN=$(echo "$CLOUDFLARE_API_TOKEN" | xargs)
  # 5. 单次 jq 合并注入（同时追加 inbounds 与 certificate_providers）
  CONFIG=$(echo "$CONFIG" | jq \
    --argjson tuic_port "$TUIC_PORT" \
    --arg tuic_uuid "$TUIC_UUID" \
    --arg tuic_password "$TUIC_PASSWORD" \
    --arg domain "$DOMAIN" \
    --arg cf_token "$CLOUDFLARE_API_TOKEN" \
    '
    .inbounds += [{
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": $tuic_port,
      "congestion_control": "bbr",
      "users": [
        {
          "name": "MainUser",
          "uuid": $tuic_uuid,
          "password": $tuic_password
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_provider": "letsencrypt"
      }
    }]
    |
    .certificate_providers = ((.certificate_providers // []) + [{
      "type": "acme",
      "tag": "letsencrypt",
      "domain": [$domain],
      "email": "wel@ryugo.org",
      "provider": "letsencrypt",
      "dns01_challenge": {
        "provider": "cloudflare",
        "api_token": $cf_token
      }
    }])
    ')
fi
}

install_nexttrace() {
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  cd "$tmp"
  nexttrace_url="https://github.com/nxtrace/NTrace-core/releases/download/v1.7.1/$nexttrace"
  wget "$nexttrace_url" -O "$nexttrace" &
  p2=$!

  if wait $p2; then
    echo "nexttrace download ok"
  else
    echo "nexttrace download failed"
  fi

  if [ -f "$nexttrace" ]; then
    $SUDO install -m 755 "$nexttrace" /usr/bin/nexttrace &
    p4=$!
    wait $p4 2>/dev/null || true
  fi
  rm -rf $nexttrace

}

install_jq() {
  $SUOD apk add jq
}

for dep in $MISSED_DEPS; do 
    fn="install_${dep}"

  if declare -f "$fn" >/dev/null 2>&1; then
    "$fn"
  else
    echo "-->> warn: func "$fn" not declared"
  fi
done

install_sing_box

$SUDO rc-service sing-box restart 2>/dev/null || $SUDO rc-service sing-box start 2>/dev/null || true

if [ "$SS_ENABLED" = true ]; then
echo "=========================================="
echo "sing-box 安装与配置完成!"
echo "Shadowsocks 端口: $PORT"
echo "Shadowsocks 加密: chacha20-ietf-poly1305"
echo "Shadowsocks 密码: $PASSWORD"
echo "=========================================="
fi

if [ "$TUIC_ENABLED" = true ]; then
echo "=========================================="
echo "tuic如下"
echo "端口 : $TUIC_PORT" 
echo "uuid: $TUIC_UUID" 
echo "password: $TUIC_PASSWORD" 
echo "SNI : $DOMAIN"
echo "=========================================="
fi