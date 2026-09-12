#!/bin/bash
# phpbox 仅用于本地开发环境：力求代码简单明了、新手一看就懂、适合人类阅读习惯、符合最佳实践。
set -euo pipefail

echo ">>> 创建目录结构..."
# sites 是唯一的站点目录（每个站点一个 <域名>.conf），不随 Nginx 版本变化，故不建 conf.d
mkdir -p ~/phpbox/{bin,lib,compose/services,config/{php,mysql,nginx/sites},logs/{nginx,php},backups,state,cache/go}

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

echo ">>> 安装全局 phpbox 命令（强制覆盖旧版本）..."
if [ -d /usr/local/bin ]; then
    # 直接尝试：sudo 需要密码时会在此刻提示输入。不用 sudo -n 预检——密码缓存
    # 过期时它会静默跳过安装，导致全局命令时有时无
    if sudo ln -sf "$HOME/phpbox/bin/phpbox" /usr/local/bin/phpbox; then
        echo "符号链接已创建：/usr/local/bin/phpbox -> $HOME/phpbox/bin/phpbox"
    else
        echo "警告：创建失败，请手动执行："
        echo "  sudo ln -sf \"$HOME/phpbox/bin/phpbox\" /usr/local/bin/phpbox"
    fi
else
    echo "错误：/usr/local/bin 不存在，请手动将 phpbox 添加到 PATH"
fi

echo ">>> 生成默认 .env（如不存在）..."
if [ ! -f ~/phpbox/.env ]; then
    cat > ~/phpbox/.env <<ENVEOF
PROJECT_NAME=phpbox
NETWORK_NAME=phpboxnet
WWW_ROOT=$HOME/www
MYSQL_DATA_ROOT=$HOME/mysql-data
PGSQL_DATA_ROOT=$HOME/pgsql-data
PGSQL_SERVICE_PREFIX=pg
CURRENT_UID=$(id -u)
CURRENT_GID=$(id -g)
NGINX_PORT=80
NGINX_VERSION=alpine
PHP_SERVICE_PREFIX=php
MYSQL_SERVICE_PREFIX=mysql
REDIS_SERVICE_PREFIX=redis
NGINX_SERVICE_PREFIX=nginx
LABEL_SEPARATOR=-
IMAGE_TAG_SEPARATOR=-
BACKUP_NAME_SEPARATOR=-
IMAGE_PREFIX=phpbox
PHP_DEFAULT_EXTENSIONS=gd,redis,pdo_mysql,mysqli,pgsql,pdo_pgsql,zip,bcmath,intl,opcache,exif,soap,sockets,imagick,xdebug
BUILD_PROXY=auto
GO_PROJECTS_ROOT=$HOME/www
GO_DEFAULT_VERSION=alpine
GO_DEFAULT_PORT=8080
GO_PROXY=https://goproxy.cn,direct
GO_CACHE_ROOT=$HOME/phpbox/cache/go
GO_CGO_ENABLED=0
GO_SERVICE_PREFIX=go
ENVEOF
    echo "已生成 .env，请根据实际情况调整（如 WWW_ROOT、MYSQL_DATA_ROOT）"
fi

echo "========================================="
echo "  phpbox 部署完成！"
echo "  使用: phpbox php install 8.4"
echo "  查看帮助: phpbox help"
echo "========================================="
