#!/bin/sh

set -e

version=v1.14.0-alpha.47
name=${version#v}
arch=linux-amd64-musl
target="sing-box-${name}-${arch}.tar.gz"
folder="${target%.tar.gz}"
sing_box_url="https://github.com/SagerNet/sing-box/releases/download/${version}/${target}"

nexttrace=nexttrace-tiny_linux_amd64
nexttrace_url="https://github.com/nxtrace/NTrace-core/releases/download/v1.7.1/$nexttrace"

read -p "What port used for Shadowsocks: " PORT
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
fi

if wait $p2; then
  echo "nexttrace download ok"
else
  echo "nexttrace download failed"
fi
tar -xf "$target"

install -m 755 "$folder/sing-box" /usr/bin/sing-box &
p3=$!

install -m 755 "$nexttrace" /usr/bin/nexttrace &
p4=$!

wait $p3
wait $p4
rm -rf "$target" "$folder"
rm -rf "$nexttrace"

mkdir -p /etc/sing-box
mkdir -p /var/lib/sing-box
touch /etc/init.d/sing-box

#单引号禁止展开变量
cat >/etc/init.d/sing-box <<'EOF'
#!/sbin/openrc-run

name="sing-box"
description="sing-box service"
supervisor="supervise-daemon"
command="/usr/bin/sing-box"
command_args="-D /var/lib/sing-box -C /etc/sing-box run"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
directory="/var/lib/sing-box"
respawn_delay=2

depend() {
    need net
    after network-online
}
EOF
cat >/etc/sing-box/config.json <<EOF

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
      "password": "8JCsPssfgS8tiRwiMlhARg=="
    }
  ]
}
EOF
chmod +x /etc/init.d/sing-box
rc-update add sing-box default
rc-service sing-box start
