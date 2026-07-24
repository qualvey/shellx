#!/usr/bin/env sh
set -e
version=v26.7.11
CURRENT_VERSION=$(xray version 2>&1 | awk '/Xray/{print $2}')
version_ge() {
  [ "$2" = "$(printf '%s\n%s' "$1" "$2" | sort -V | head -n1)" ]
}
# 3. 执行判断
if [ -z "$CURRENT_VERSION" ]; then
  # 核心修改：如果不存在，打印提示，直接通过，不执行后面的比较逻辑
  echo "提示：未检测到 Xray 安装，自动跳过版本检查（默认通过）。"

else
  # 如果存在版本号，才进行高低版本的比对
  echo "当前 Xray 版本: $CURRENT_VERSION"
  echo "预期最低版本: $version"

  if version_ge "$CURRENT_VERSION" $(echo "$version" | sed 's/^[vV]//'); then
    echo "验证通过：当前版本符合或高于预期。"
    exit 0 # 版本达标，直接成功结束
  fi

fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

wget https://github.com/XTLS/Xray-core/releases/download/"$version"/Xray-linux-64.zip -O xray.zip
unzip xray.zip -d xray
sudo install -m 755 xray/xray /usr/local/bin/xray

mkdir -p /etc/xray
mkdir -p /var/log/xray
touch /etc/init.d/xray

cat >/etc/init.d/xray <<'EOF'
#!/sbin/openrc-run

name="xray"
description="xray service"

command="/usr/local/bin/xray"
command_args="run -config /etc/xray/config.json"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
directory="/etc/xray"

depend() {
    need net
    after network-online
}
EOF

chmod +x /etc/init.d/xray
rc-update add xray default
