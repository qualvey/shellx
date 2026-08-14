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

PORT=8388
if [ -t 0 ]; then
  read -p "What port used for Shadowsocks (default: 8388): " PORT_INPUT
  if [ -n "$PORT_INPUT" ]; then PORT=$PORT_INPUT; fi
fi

TUIC_PORT=443

if [ -t 0 ]; then
  read -p "What port used for TUIC (default: 443): " TUIC_PORT_INPUT
  if [ -n "$TUIC_PORT_INPUT" ]; then TUIC_PORT=$TUIC_PORT_INPUT; fi
fi
read -p "Enable TUIC? (y/N): " ENABLE_TUIC
ENABLE_TUIC=${ENABLE_TUIC:-n}

if [ "$ENABLE_TUIC" = "y" ] || [ "$ENABLE_TUIC" = "Y" ]; then
  read -p "tuic uuid (leave empty to auto-generate): " TUIC_UUID
  if [ -z "$TUIC_UUID" ]; then
    if command -v uuidgen >/dev/null 2>&1; then
      TUIC_UUID=$(uuidgen)
    elif command -v sing-box >/dev/null 2>&1; then
      TUIC_UUID=$(sing-box generate uuid )
    elif [ -r /proc/sys/kernel/random/uuid ]; then
      TUIC_UUID=$(cat /proc/sys/kernel/random/uuid)
    elif command -v python3 >/dev/null 2>&1; then
      TUIC_UUID=$(python3 -c 'import uuid;print(uuid.uuid4())')
    elif command -v python >/dev/null 2>&1; then
      TUIC_UUID=$(python -c 'import uuid;print(uuid.uuid4())')
    else
      TUIC_UUID=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-32)
    fi
  fi

  read -p "tuic password (leave empty to auto-generate): " TUIC_PASSWORD
  if [ -z "$TUIC_PASSWORD" ]; then
    TUIC_PASSWORD=$(head -c 16 /dev/urandom | base64 2>/dev/null | tr -d '\n/' | cut -c1-16)
    if [ -z "$TUIC_PASSWORD" ]; then
      TUIC_PASSWORD="SecretTUICPass8JCs"
    fi
  fi
fi

# 随机生成安全密码
PASSWORD=$(head -c 16 /dev/urandom | base64 2>/dev/null | tr -d '\n/' | cut -c1-16)
if [ -z "$PASSWORD" ]; then
  PASSWORD="SecretPass8JCsPssfgS"
fi

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

if [ "$ENABLE_TUIC" = "y" ] || [ "$ENABLE_TUIC" = "Y" ]; then
  echo "TUIC enabled: Let's Encrypt certificate provider is required."
  ENABLE_CERT=y
  # require domain and api token (loop until provided)
  while [ -z "$DOMAIN" ]; do
    read -p "Domain(s) for certificate (enter JSON array items or a single quoted domain, e.g. \"\"example.com\"\" or \"\\\"example.com\\\"\"): " DOMAIN
    if [ -z "$DOMAIN" ]; then
      echo "Domain is required when TUIC is enabled."
    fi
  done
  while [ -z "$CLOUDFLARE_API_TOKEN" ]; do
    read -p "Cloudflare API token: " CLOUDFLARE_API_TOKEN
    if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
      echo "Cloudflare API token is required when TUIC is enabled."
    fi
  done
else
  read -p "Enable Let's Encrypt certificate provider? (y/N): " ENABLE_CERT
  ENABLE_CERT=${ENABLE_CERT:-n}
  if [ "$ENABLE_CERT" = "y" ] || [ "$ENABLE_CERT" = "Y" ]; then
    read -p "Domain(s) for certificate (example: \"example.com\" or JSON array items): " DOMAIN
    read -p "Cloudflare API token: " CLOUDFLARE_API_TOKEN
    if [ -z "$DOMAIN" ] || [ -z "$CLOUDFLARE_API_TOKEN" ]; then
      echo "Domain or Cloudflare API token empty; disabling certificate provider."
      ENABLE_CERT=n
    fi
  fi
fi

$SUDO tee /etc/sing-box/config.json >/dev/null <<EOF
{
  "log": {
      "timestamp": true,
      "output": "box.log",
      "level": "info"
  }
EOF

if [ "$ENABLE_CERT" = "y" ] || [ "$ENABLE_CERT" = "Y" ]; then
  cat <<EOF | $SUDO tee -a /etc/sing-box/config.json >/dev/null
  , "certificate_providers": [
    {
        "type": "acme",
        "tag": "letsencrypt",
        "domain": [
            ${DOMAIN}
        ],
        "email": "mail@ryugo.org",
        "provider": "letsencrypt",
        "dns01_challenge": {
            "provider": "cloudflare",
            "api_token": "$CLOUDFLARE_API_TOKEN"
        }
    }
  ]
EOF
fi

cat <<EOF | $SUDO tee -a /etc/sing-box/config.json >/dev/null
  , "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": $PORT,
      "method": "chacha20-ietf-poly1305",
      "password": "$PASSWORD"
    }
EOF

if [ "$ENABLE_TUIC" = "y" ] || [ "$ENABLE_TUIC" = "Y" ]; then
  cat <<EOF | $SUDO tee -a /etc/sing-box/config.json >/dev/null
    ,
    {
    "type": "tuic",
    "tag": "tuic-in",
    "listen": "::",
    "listen_port": $TUIC_PORT,
    "congestion_control": "bbr",
    "users": [
        {
            "name": "MainUser",
            "uuid": "$TUIC_UUID",
            "password": "$TUIC_PASSWORD"
        }
    ],
    "tls": {
        "enabled": true,
        "alpn": [
            "h3"
        ],
        "certificate_provider": "letsencrypt"
    }
}
EOF
fi

$SUDO tee -a /etc/sing-box/config.json >/dev/null <<'EOF'
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

