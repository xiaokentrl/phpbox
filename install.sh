#phpbox仅用于本地开发环境,一切以本地开发为主
#!/bin/bash
set -euo pipefail

echo ">>> 创建目录结构..."
mkdir -p ~/phpbox/{bin,lib,compose/services,config/{php,mysql,nginx/{sites,conf.d}},logs/{nginx,php},backups,state,data}

echo ">>> 复制 CLI 源码..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$SCRIPT_DIR" = "${HOME%/}/phpbox" ]; then
    echo ">>> 源码目录即安装目标（$SCRIPT_DIR），跳过复制"
else
    cp -r "$SCRIPT_DIR/bin/phpbox" ~/phpbox/bin/
    cp -r "$SCRIPT_DIR/lib/"* ~/phpbox/lib/
fi

chmod +x ~/phpbox/bin/phpbox

echo ">>> 创建主 Compose 文件..."
cat > ~/phpbox/compose/docker-compose.yml <<'EOF'
networks:
  net:
    driver: bridge
    name: ${NETWORK_NAME:-phpboxnet}
EOF

echo ">>> 创建符号链接（需要 sudo 权限）..."
if ! sudo -n true 2>/dev/null; then
    echo "警告：sudo 不可用或需要密码，请手动执行："
    echo "  sudo ln -sf \"$HOME/phpbox/bin/phpbox\" /usr/local/bin/phpbox"
else
    if [ -d /usr/local/bin ]; then
        sudo ln -sf "$HOME/phpbox/bin/phpbox" /usr/local/bin/phpbox
        echo "符号链接已创建：/usr/local/bin/phpbox -> $HOME/phpbox/bin/phpbox"
    else
        echo "错误：/usr/local/bin 不存在，请手动将 phpbox 添加到 PATH"
    fi
fi

echo ">>> 生成默认 .env（如不存在）..."
if [ ! -f ~/phpbox/.env ]; then
    cat > ~/phpbox/.env <<ENVEOF
PROJECT_NAME=phpbox
NETWORK_NAME=phpboxnet
WWW_ROOT=$HOME/www
MYSQL_DATA_ROOT=$HOME/mysql-data
CURRENT_UID=$(id -u)
CURRENT_GID=$(id -g)
NGINX_PORT=80
PHP_SERVICE_PREFIX=php
MYSQL_SERVICE_PREFIX=mysql
REDIS_SERVICE_PREFIX=redis
NGINX_SERVICE_PREFIX=nginx
LABEL_SEPARATOR=-
IMAGE_TAG_SEPARATOR=-
BACKUP_NAME_SEPARATOR=-
IMAGE_PREFIX=phpbox
ENVEOF
    echo "已生成 .env，请根据实际情况调整（如 WWW_ROOT、MYSQL_DATA_ROOT）"
fi

echo "========================================="
echo "  phpbox 部署完成！"
echo "  使用: phpbox php install 8.4"
echo "  查看帮助: phpbox help"
echo "========================================="
