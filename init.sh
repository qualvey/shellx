#!/usr/bin/env bash
set -euo pipefail

# 1. 权限检查
if [ "$EUID" -ne 0 ]; then
    echo "❌ 错误：请以 root 用户运行此脚本！" >&2
    exit 1
fi

source /etc/os-release

# 全局变量定义
SSHD_CONFIG="/etc/ssh/sshd_config"
USERNAME="user"
DEFAULT_PASSWD="passwd"
PubKey='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGa7/v6kzOZ1uLfMQWFruonAHpMSJvYnRwtSIySo6DVy wel@ryugo.org'

case "$ID" in
    ubuntu|debian)
        PKG_INSTALL="apt-get install -y"
        PKG_UPDATE="apt-get update"
        TARGET_GROUPS=("sudo" "adm" "systemd-journal")
        SSH_SERVICE="ssh"
        ;;
    rocky|almalinux|centos|fedora)
        PKG_INSTALL="dnf install -y"
        PKG_UPDATE="dnf makecache"
        TARGET_GROUPS=("wheel" "systemd-journal")
        SSH_SERVICE="sshd"
        ;;
    *)
        echo "❌ 当前系统 ($ID) 暂不支持" >&2
        exit 1
        ;;
esac

echo "检测到系统：$PRETTY_NAME"

# 修改或追加 SSH 配置项
update_config() {
    local key="$1"
    local value="$2"
    if grep -q -E "^[#[:space:]]*${key}\b" "$SSHD_CONFIG"; then
        sed -i -E "s|^[#[:space:]]*${key}\b.*|${key} ${value}|" "$SSHD_CONFIG"
    else
        echo "${key} ${value}" >> "$SSHD_CONFIG"
    fi
}

# 2. 安装基础依赖
echo "📦 正在更新软件源并安装 fail2ban..."
$PKG_UPDATE
$PKG_INSTALL fail2ban
systemctl enable --now fail2ban

# 3. 校验并过滤有效用户组
VALID_GROUPS=()
for grp in "${TARGET_GROUPS[@]}"; do
    if getent group "$grp" >/dev/null 2>&1; then
        VALID_GROUPS+=("$grp")
    else
        echo "⚠️ 提示：组 '$grp' 不存在，已忽略"
    fi
done

GROUP_LIST=$(IFS=,; echo "${VALID_GROUPS[*]}")

# 4. 创建用户并配置组
if id "$USERNAME" >/dev/null 2>&1; then
    echo "ℹ️ 用户 '$USERNAME' 已存在"
    [ -n "$GROUP_LIST" ] && usermod -aG "$GROUP_LIST" "$USERNAME"
else
    echo "👤 正在创建用户 '$USERNAME'..."
    if [ -n "$GROUP_LIST" ]; then
        useradd -m -s /bin/bash -G "$GROUP_LIST" "$USERNAME"
    else
        useradd -m -s /bin/bash "$USERNAME"
    fi
    echo "${USERNAME}:${DEFAULT_PASSWD}" | chpasswd
    echo "✅ 用户 '$USERNAME' 创建成功"
fi

# 5. 配置 SSH 密钥登录
SSH_DIR="/home/${USERNAME}/.ssh"
mkdir -p "$SSH_DIR"
echo "$PubKey" > "$SSH_DIR/authorized_keys"

chmod 700 "$SSH_DIR"
chmod 600 "$SSH_DIR/authorized_keys"
chown -R "${USERNAME}:${USERNAME}" "$SSH_DIR"

# 6. 安全配置 SSHD
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak"
echo "已备份 SSH 配置至 ${SSHD_CONFIG}.bak"

update_config "PermitRootLogin" "no"
update_config "PasswordAuthentication" "no"
update_config "PubkeyAuthentication" "yes"

# 清理 sshd_config.d 中可能覆盖密码认证的子配置
if [ -d "/etc/ssh/sshd_config.d" ]; then
    find /etc/ssh/sshd_config.d/ -type f -name "*.conf" -exec sed -i -E 's|^[#[:space:]]*PasswordAuthentication.*|PasswordAuthentication no|g' {} + 2>/dev/null || true
fi

# 语法验证与服务重启
if ! sshd -t -f "$SSHD_CONFIG"; then
    echo "❌ SSH 配置文件语法错误！正在回滚..." >&2
    cp "${SSHD_CONFIG}.bak" "$SSHD_CONFIG"
    exit 1
fi

systemctl restart "$SSH_SERVICE"
echo "✅ SSH 服务配置完成并重启成功"

# 7. 应用目录权限配置
if [ -d "/etc/sing-box" ]; then
    chown -R "${USERNAME}:${USERNAME}" /etc/sing-box
fi

mkdir -p /srv/configurations
chown -R "${USERNAME}:${USERNAME}" /srv/configurations

echo "🎉 脚本初始化完成！请保持当前窗口，新开终端尝试通过密钥登录 '$USERNAME' 确认连接正常。"