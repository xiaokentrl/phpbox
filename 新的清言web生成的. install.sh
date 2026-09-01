1. install.sh

#!/bin/bash
set -euo pipefail

echo ">>> 创建目录结构..."
mkdir -p ~/phpbox/{bin,lib,compose/services,config/{php,mysql,nginx/{sites,conf.d}},logs/{nginx,php},backups,state,data}

echo ">>> 复制 CLI 源码..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp -r "$SCRIPT_DIR/bin/phpbox" ~/phpbox/bin/
cp -r "$SCRIPT_DIR/lib/"* ~/phpbox/lib/

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
2. bin/phpbox

#!/bin/bash
set -euo pipefail

BASE_DIR="$HOME/phpbox"
LIB_DIR="$BASE_DIR/lib"

for lib in common php mysql redis nginx site backup; do
    if [ ! -f "$LIB_DIR/$lib.sh" ]; then
        echo "错误：缺少库文件 $LIB_DIR/$lib.sh，请重新运行 install.sh" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$LIB_DIR/$lib.sh"
done

load_env
CMD_NAME="$(basename "$0")"

show_help() {
    cat <<HELPEOF
${CMD_NAME} - 多版本 Docker 开发环境管理

命令:
  php install <版本> [--extensions 扩展列表]  安装 PHP
  php extension add <版本> <扩展>             添加扩展
  php extension remove <版本> <扩展>          移除扩展
  php list                                   列出所有 PHP
  php uninstall <版本> [--purge]             卸载 PHP

  mysql install <版本> [--port 端口]          安装 MySQL
  mysql port set <版本> <新端口>              修改端口
  mysql list                                 列出所有 MySQL
  mysql uninstall <版本> [--purge]           卸载 MySQL

  redis install <版本> [--port 端口]          安装 Redis
  redis port set <版本> <新端口>              修改端口
  redis list                                 列出所有 Redis
  redis uninstall <版本> [--purge]           卸载 Redis

  nginx install [--port 端口]                安装 Nginx (固定使用 nginx:alpine)
  nginx port set <新端口>                     修改 Nginx 端口
  nginx reload                               重载配置
  nginx uninstall                            卸载 Nginx（保留配置）

  site add <域名> --php <版本>                创建站点
  site switch <域名> --php <版本>             切换站点的 PHP 版本
  site list                                  列出所有站点
  site remove <域名>                         删除站点

  hosts add <域名>                           添加 hosts 解析
  hosts remove <域名>                        移除 hosts 解析
  hosts list                                 查看 hosts 状态

  backup                                     备份所有数据
  restore <备份文件> [-y]                     恢复数据（-y 非交互确认）

  list                                       列出所有已安装服务

环境变量 (.env):
  WWW_ROOT        网站根目录（默认 ~/www）
  MYSQL_DATA_ROOT MySQL 数据主目录（默认 $HOME/mysql-data）
  其他变量请查看 .env 文件

示例:
  phpbox php install 8.4 --extensions gd,redis
  phpbox mysql install 8.0 --port 3307
  phpbox nginx install --port 8080
  phpbox site add demo.test --php 8.4
  phpbox hosts add demo.test
  phpbox list
HELPEOF
}

case "${1:-help}" in
    php|mysql|redis|nginx|site|hosts|backup|restore|list)
        subcmd="$1"; shift
        case "$subcmd" in
            php)     cmd_php "$@" ;;
            mysql)   cmd_mysql "$@" ;;
            redis)   cmd_redis "$@" ;;
            nginx)   cmd_nginx "$@" ;;
            site)    cmd_site "$@" ;;
            hosts)   cmd_hosts "$@" ;;
            backup)  cmd_backup "$@" ;;
            restore) cmd_restore "$@" ;;
            list)    cmd_list ;;
        esac
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "未知命令: $1，使用 '$CMD_NAME help' 查看帮助" >&2
        exit 1
        ;;
esac
3. lib/common.sh

#!/bin/bash
# shellcheck shell=bash

# 公共函数与变量定义
BASE_DIR="$HOME/phpbox"
COMPOSE_DIR="$BASE_DIR/compose"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
EXT_DIR="$COMPOSE_DIR/services"
CONFIG_DIR="$BASE_DIR/config"
LOG_DIR="$BASE_DIR/logs"
BACKUP_DIR="$BASE_DIR/backups"
STATE_DIR="$BASE_DIR/state"
ENV_FILE="$BASE_DIR/.env"

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()    { echo -e "${CYAN}[INFO]$*${NC}" >&2; }
success(){ echo -e "${GREEN}[OK]$*${NC}" >&2; }
error()  { echo -e "${RED}[ERR]$*${NC}" >&2; exit 1; }

sed_i() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i "" "$@"
  else
    sed -i "$@"
  fi
}

load_env() {
  if [ -f "$ENV_FILE" ]; then
    while IFS='=' read -r key value; do
      [[ "$key" =~ ^[[:space:]]*# ]] && continue
      [[ -z "$key" ]] && continue
      key="${key//[[:space:]]/}"
      # 跳过格式非法的 key，避免 export 失败导致整个脚本中止
      [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
      # 去除值两端的引号（如果有）
      value="${value%$'\r'}"
      value="${value%\"}"
      value="${value#\"}"
      export "$key"="$value"
    done < "$ENV_FILE"
  fi

  PROJECT_NAME="${PROJECT_NAME:-phpbox}"
  NETWORK_NAME="${NETWORK_NAME:-phpboxnet}"
  WWW_ROOT="${WWW_ROOT:-$HOME/www}"
  IMAGE_PREFIX="${IMAGE_PREFIX:-phpbox}"
  LABEL_SEPARATOR="${LABEL_SEPARATOR:--}"
  IMAGE_TAG_SEPARATOR="${IMAGE_TAG_SEPARATOR:--}"
  BACKUP_NAME_SEPARATOR="${BACKUP_NAME_SEPARATOR:--}"
  NGINX_PORT="${NGINX_PORT:-80}"
  CURRENT_UID="${CURRENT_UID:-$(id -u)}"
  CURRENT_GID="${CURRENT_GID:-$(id -g)}"
  MYSQL_DATA_ROOT="${MYSQL_DATA_ROOT:-$HOME/mysql-data}"

  export PROJECT_NAME NETWORK_NAME WWW_ROOT IMAGE_PREFIX LABEL_SEPARATOR IMAGE_TAG_SEPARATOR BACKUP_NAME_SEPARATOR NGINX_PORT CURRENT_UID CURRENT_GID MYSQL_DATA_ROOT
  mkdir -p "$WWW_ROOT" "$COMPOSE_DIR" "$EXT_DIR" "$CONFIG_DIR" "$LOG_DIR" "$BACKUP_DIR" "$STATE_DIR" "$MYSQL_DATA_ROOT"
}

get_service_key() { echo "${1}${2//./}"; }
get_container_name() {
  local svc=$1 ver=$2
  local prefix_var="${svc^^}_SERVICE_PREFIX"
  local prefix="${!prefix_var:-$svc}"
  echo "${prefix}${ver//./}"
}
get_volume_name() { echo "${PROJECT_NAME}_$(get_service_key "$1" "$2")_data"; }

escape_sed() {
  echo "$1" | sed -e 's/[\/&]/\\&/g'
}

# 转义 sed 正则表达式中的特殊字符
escape_sed_regex() {
  echo "$1" | sed 's/[][\/$*.^|+?(){}]/\\&/g'
}

# 统一写入 .env 并同步当前 shell 环境变量（compose 插值时 shell 环境优先于 --env-file）
set_env_value() {
  local key=$1 val=$2 ek ev
  # 转义替换串中的 sed 特殊字符（\ & 以及分隔符 |）
  ev=$(printf '%s' "$val" | sed -e 's/[\\&|]/\\&/g')
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    ek=$(escape_sed "$key")
    sed_i "s|^${ek}=.*|${ek}=${ev}|" "$ENV_FILE"
  else
    echo "${key}=${val}" >> "$ENV_FILE"
  fi
  export "${key}=${val}"
}

check_port() {
  local port=$1
  if command -v ss &>/dev/null; then
    ss -tln | grep -qE ":${port}[[:space:]]" && return 1
  elif command -v lsof &>/dev/null; then
    lsof -i :"$port" -sTCP:LISTEN -t &>/dev/null 2>&1 && return 1
  fi
  return 0
}

show_port_owner() {
  local port=$1
  if command -v lsof &>/dev/null; then
    if lsof -i :"$port" -sTCP:LISTEN &>/dev/null 2>&1; then
      lsof -i :"$port" -sTCP:LISTEN 2>/dev/null | tail -n +2
    else
      lsof -i :"$port" 2>/dev/null | tail -n +2
    fi
  elif command -v netstat &>/dev/null; then
    netstat -tlnp 2>/dev/null | awk "/:${port}[[:space:]]/"'{print$7}'
  else
    echo "无法获取进程信息（缺少 lsof/netstat）" >&2
  fi
}

# 用法: check_and_report_port <端口> [排除的 .env key]
# 排除 key 用于"重装/改回自身端口"场景，避免把自身登记误判为冲突
check_and_report_port() {
  local port=$1
  local exclude_key="${2:-}"
  local used
  if ! check_port "$port"; then
    echo -e "${RED}端口${port} 已被占用，占用信息：${NC}" >&2
    show_port_owner "$port"
    echo -e "${CYAN}请手动释放端口，或使用 '--port' 指定其他可用端口。${NC}" >&2
    return 1
  fi
  if [ -n "$exclude_key" ]; then
    used=$(grep -E '^[A-Z_]+_PORT=' "$ENV_FILE" 2>/dev/null | grep -v "^${exclude_key}=" | cut -d= -f2- | tr '\n' ' ')
  else
    used=$(grep -E '^[A-Z_]+_PORT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr '\n' ' ')
  fi
  # 注意首尾各补一个空格，保证第一个端口也能匹配
  if [[ " $used " == *"$port "* ]]; then
    echo -e "${RED}端口${port} 已被 phpbox 其他服务登记，不能重复分配。${NC}" >&2
    return 1
  fi
  return 0
}

find_free_port() {
  local start=${1:-80}
  local p=$start
  local used
  used=$(grep -E '^[A-Z_]+_PORT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr '\n' ' ')
  while [ "$p" -le 65535 ]; do
    if check_port "$p" && [[ "$used " != *" $p "* ]]; then
      echo "$p"
      return 0
    fi
    p=$((p+1))
  done
  error "无法找到可用端口（已扫描 ${start}-65535）"
}

get_or_set_port() {
  local svc=$1 ver=$2 default=$3
  local key="$(echo${svc}_${ver//./}_PORT | tr '[:lower:]' '[:upper:]')"
  if [ "$svc" = "nginx" ]; then
    key="NGINX_PORT"
  fi

  local val=""
  val=$(grep "^${key}=" "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)
  if [ -z "$val" ]; then
    val=$(find_free_port "$default")
    set_env_value "$key" "$val"
    log "已分配端口 ${val} 给${svc} ${ver}"
  else
    if ! check_port "$val"; then
      echo -e "${YELLOW}警告：已配置的端口${val} 被占用，正在寻找可用端口...${NC}" >&2
      local new_val
      new_val=$(find_free_port "$default")
      log "将使用新端口 ${new_val}，并更新 .env"
      set_env_value "$key" "$new_val"
      val=$new_val
    fi
  fi
  echo "$val"
}

get_or_set_password() {
  local svc=$1 ver=$2
  local key="$(echo${svc}_${ver//./}_ROOT_PASSWORD | tr '[:lower:]' '[:upper:]')"
  local val=""
  val=$(grep "^${key}=" "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)
  if [ -z "$val" ]; then
    command -v openssl &>/dev/null || error "需要 openssl 生成密码，请先安装 openssl"
    val=$(openssl rand -hex 8)
    set_env_value "$key" "$val"
    success "已生成 ${svc}${ver} 密码，保存于 .env"
  fi
  echo "$val"
}

read_env_value() {
  local key=$1 default=$2
  local val=""
  val=$(grep "^${key}=" "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)
  echo "${val:-$default}"
}

run_compose() {
  local svc=$1 ver=$2; shift 2
  local service_file="$EXT_DIR/${svc}-${ver}.yml"
  if [ ! -f "$service_file" ]; then
    error "未找到服务 ${svc}${ver} 的 Compose 配置文件"
  fi
  docker compose -p "$PROJECT_NAME" \
    --project-directory "$BASE_DIR" \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" \
    -f "$service_file" \
    "$@"
}

init_config_files() {
  local svc=$1 ver=$2
  local dir="$CONFIG_DIR/$svc/$ver"
  local check_file=""

  case $svc in
    nginx) check_file="$dir/nginx.conf" ;;
    php)   check_file="$dir/php.ini" ;;
    mysql) check_file="$dir/my.cnf" ;;
  esac

  if [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ] && [ -f "$check_file" ]; then
    return
  fi

  [ -d "$dir" ] && rm -rf "$dir"
  log "初始化 $svc$ver 配置..."
  mkdir -p "$dir"

  case $svc in
    nginx)
      docker run --rm -v "$dir":/out nginx:alpine \
        sh -c "cp -r /etc/nginx/conf.d /out/ && cp /etc/nginx/nginx.conf /out/" || {
        rm -rf "$dir"; error "Nginx 配置提取失败"
      }
      if [ -f "$dir/nginx.conf" ] && ! grep -q 'include /etc/nginx/sites/\*\.conf;' "$dir/nginx.conf"; then
        awk '/http[[:space:]]*{/{print; print "    include /etc/nginx/sites/*.conf;"; next}1' "$dir/nginx.conf" > "$dir/nginx.conf.tmp"
        mv "$dir/nginx.conf.tmp" "$dir/nginx.conf"
      fi
      ;;
    php)
      docker run --rm -v "$dir":/out "php:${ver}-fpm-alpine" \
        sh -c "cp /usr/local/etc/php/php.ini-production /out/php.ini" || {
        rm -rf "$dir"; error "PHP 配置提取失败"
      }
      ;;
    mysql)
      local mysql_major=$(echo "$ver" | cut -d. -f1)
      local mysql_minor=$(echo "$ver" | cut -d. -f2)
      if [[ "$mysql_major" -eq 8 && "$mysql_minor" -ge 4 ]]; then
        # 8.4+：default-authentication-plugin 已移除，用新变量名启用 mysql_native_password
        cat > "$dir/my.cnf" <<'MYEOF'
[mysqld]
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
mysql_native_password=ON
MYEOF
      elif [[ "$mysql_major" -lt 9 ]]; then
        # 5.x/7.x 及 8.0-8.3：旧变量名有效（8.0.27+ 仅弃用警告，不影响启动）
        cat > "$dir/my.cnf" <<'MYEOF'
[mysqld]
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
default-authentication-plugin=mysql_native_password
MYEOF
      else
        # 9.x 及以上：mysql_native_password 已彻底移除，任何相关变量都会导致 mysqld 启动失败
        cat > "$dir/my.cnf" <<'MYEOF'
[mysqld]
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
MYEOF
      fi
      ;;
  esac

  chown -R "$CURRENT_UID:$CURRENT_GID" "$dir" 2>/dev/null || true
  success "$svc$ver 配置就绪"
}

# 通用服务安装（仅用于 MySQL/Redis）
_generic_service_install() {
  local svc=$1 ver=$2 default_port=$3
  shift 3
  if [ -f "$EXT_DIR/${svc}-${ver}.yml" ]; then
    error "${svc}${ver} 已安装"
  fi

  # 解析 --port 参数
  local port=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port)
        [ $# -ge 2 ] || error "--port 需要指定端口号"
        port="${2}"
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
          error "端口号必须是 1-65535 之间的数字"
        fi
        shift 2 ;;
      *)
        error "未知选项: $1" ;;
    esac
  done

  # 获取/设置端口值（唯一入口）
  if [ -n "$port" ]; then
    local key
    key="$(echo${svc}_${ver//./}_PORT | tr '[:lower:]' '[:upper:]')"
    # 排除自身 key 的登记检查，允许卸载后用相同端口重装
    if ! check_and_report_port "$port" "$key"; then
      error "端口 $port 不可用"
    fi
    set_env_value "$key" "$port"
  else
    port=$(get_or_set_port "$svc" "$ver" "$default_port")
  fi

  init_config_files "$svc" "$ver"
  case "$svc" in
    mysql) _mysql_generate_compose "$ver"; _mysql_ensure_running "$ver" ;;
    redis) _redis_generate_compose "$ver"; _redis_ensure_running "$ver" ;;
  esac
  success "${svc}${ver} 安装完成，端口 ${port}"
}

# 通用端口修改（仅用于 MySQL/Redis）
_generic_db_port_set() {
  local svc=$1 ver=$2 new_port=$3 default_port=$4
  local key="$(echo${svc}_${ver//./}_PORT | tr '[:lower:]' '[:upper:]')"
  local old_port=""
  old_port=$(grep "^${key}=" "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)
  [ -z "$old_port" ] && error "${svc} ${ver} 未安装或端口未记录"

  if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
    error "端口号必须是 1-65535 之间的数字"
  fi

  if [ "$new_port" = "$old_port" ]; then
    log "${svc}${ver} 端口已经是 ${new_port}，无需修改"
    return 0
  fi

  # 排除自身 key 的登记检查
  if ! check_and_report_port "$new_port" "$key"; then
    error "端口 ${new_port} 不可用"
  fi

  local temp_env
  temp_env=$(mktemp) || error "无法创建临时文件"
  cp "$ENV_FILE" "$temp_env"
  set_env_value "$key" "$new_port"

  # 使用 compose 服务 key 而非容器名（自定义 *_SERVICE_PREFIX 时二者不同）
  local svc_key
  svc_key=$(get_service_key "$svc" "$ver")
  if ! run_compose "$svc" "$ver" up -d --force-recreate "$svc_key"; then
    cp "$temp_env" "$ENV_FILE"; rm -f "$temp_env"
    export "${key}=${old_port}"   # 回滚 shell 变量
    error "端口变更失败，已回滚"
  fi

  # 轮询等待服务就绪（verify_service 内部会校验端口映射）
  local timeout=30
  local ok=false
  while [ $timeout -gt 0 ]; do
    if verify_service "$svc" "$ver" "$new_port"; then
      ok=true
      break
    fi
    sleep 2
    timeout=$((timeout - 2))
  done

  if ! $ok; then
    cp "$temp_env" "$ENV_FILE" 2>/dev/null || true
    export "${key}=${old_port}"
    run_compose "$svc" "$ver" up -d --force-recreate "$svc_key" >/dev/null 2>&1 || true
    rm -f "$temp_env"
    error "新端口验证超时，已回滚"
  fi

  rm -f "$temp_env"
  success "${svc}${ver} 端口已改为 ${new_port}"
}

verify_service() {
  local svc=$1 ver=$2 port=$3
  local cname
  cname=$(get_container_name "$svc" "$ver")

  # 先验证宿主机端口映射（如果服务映射了端口）
  if [[ "$svc" == "mysql" || "$svc" == "redis" ]]; then
    local actual
    actual=$(docker port "$cname" 2>/dev/null | awk -v p="$port" '$0 ~ ":"p"$" {print$0}')
    if [ -z "$actual" ]; then
      return 1
    fi
  fi

  case "$svc" in
    mysql)
      local pass
      pass=$(get_or_set_password "$svc" "$ver") || return 1
      docker exec -e MYSQL_PWD="$pass" "$cname" mysqladmin ping -h localhost -u root &>/dev/null
      ;;
    redis)
      docker exec "$cname" redis-cli ping | grep -q PONG
      ;;
    nginx)
      curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port" | grep -qE '200|301|302|404'
      ;;
    *) return 1 ;;
  esac
}

# 全局服务列表
cmd_list() {
  docker ps -a --filter "label=${PROJECT_NAME}${LABEL_SEPARATOR}service" --format \
    'table {{.Names}}\t{{.Label "'"${PROJECT_NAME}${LABEL_SEPARATOR}"'service"}}\t{{.Label "'"${PROJECT_NAME}${LABEL_SEPARATOR}"'version"}}\t{{.Ports}}\t{{.Status}}'
}
4. lib/php.sh

#!/bin/bash
# shellcheck shell=bash

_php_get_extensions_file() {
  local ver=$1
  echo "$STATE_DIR/php-${ver//./}-extensions.env"
}

_php_read_extensions() {
  local ver=$1
  local f="$(_php_get_extensions_file "$ver")"
  if [ -f "$f" ]; then
    grep -v '^#' "$f" | grep -v '^$' | sed 's/^[A-Za-z_][A-Za-z0-9_]*=//' | grep -v '^$' | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//'
  else
    echo ""
  fi
}

_php_write_extensions() {
  local ver=$1 exts=$2
  local f="$(_php_get_extensions_file "$ver")"
  echo "# PHP ${ver} 扩展列表（逗号分隔）" > "$f"
  echo "PHP_EXTENSIONS=${exts}" >> "$f"
}

_php_validate_extensions() {
  local exts="$1"
  local IFS=,
  for ext in $exts; do
    if ! [[ "$ext" =~ ^[a-zA-Z0-9_-]+$ ]]; then
      error "无效扩展名: $ext"
    fi
  done
}

_php_build_image() {
  local ver=$1 exts=$2
  local img="${IMAGE_PREFIX}php${ver//./}"
  local build_dir="$CONFIG_DIR/php/$ver"
  mkdir -p "$build_dir"

  cat > "$build_dir/Dockerfile" <<DEOF
FROM php:${ver}-fpm-alpine
ARG UID=1000
ARG GID=1000
RUN apk add --no-cache shadow curl
COPY --from=mlocati/php-extension-installer:2 /usr/bin/install-php-extensions /usr/local/bin/
RUN if [ -n "$exts" ]; then install-php-extensions${exts//,/ }; fi
RUN usermod -u \${UID} www-data && groupmod -g \${GID} www-data
DEOF

  # 本函数通过命令替换被调用：所有提示必须走 stderr，stdout 只输出镜像名
  log "构建 PHP ${ver} 自定义镜像（扩展:${exts:-无}）..." >&2
  docker build -q -t "$img" \
    --build-arg UID="$CURRENT_UID" \
    --build-arg GID="$CURRENT_GID" \
    "$build_dir" >&2 || error "PHP 镜像构建失败"

  echo "$img"
}

_php_ensure_running() {
  local ver=$1
  local svc_key
  svc_key=$(get_service_key "php" "$ver")
  local yml="$EXT_DIR/php-${ver}.yml"
  if [ ! -f "$yml" ]; then
    _php_generate_compose "$ver"
  fi
  run_compose "php" "$ver" up -d "$svc_key"
  local cname
  cname=$(get_container_name "php" "$ver")
  local timeout=30
  while [ $timeout -gt 0 ]; do
    if docker exec "$cname" php-fpm -t &>/dev/null; then
      return 0
    fi
    sleep 2
    timeout=$((timeout - 2))
  done
  error "PHP ${ver} 启动超时"
}

_php_generate_compose() {
  local ver=$1
  local svc_key
  svc_key=$(get_service_key "php" "$ver")
  local yml="$EXT_DIR/php-${ver}.yml"
  local exts
  exts="$(_php_read_extensions "$ver")"
  local image
  image=$(_php_build_image "$ver" "$exts") || exit 1

  cat > "$yml" <<YEOF
services:
  $svc_key:
    image: $image
    container_name: $(get_container_name "php" "$ver")
    volumes:
      - \${WWW_ROOT}:/var/www
      - ./config/php/${ver}/php.ini:/usr/local/etc/php/php.ini:ro
      - ./logs/php:/var/log/php:rw
    networks:
      - net
    restart: unless-stopped
    labels:
      - "${PROJECT_NAME}${LABEL_SEPARATOR}service=php"
      - "${PROJECT_NAME}${LABEL_SEPARATOR}version=${ver}"
    healthcheck:
      test: ["CMD-SHELL", "php-fpm -t || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
YEOF
}

_php_cleanup_images() {
  local ver=$1
  local cname
  cname=$(get_container_name "php" "$ver")
  docker rm -f "$cname" 2>/dev/null || true
  local pattern="${IMAGE_PREFIX}php${ver//./}"
  # macOS 兼容：不使用 xargs -r
  docker images --filter "reference=${pattern}" -q 2>/dev/null | while read -r id; do
    [ -n "$id" ] && docker rmi -f "$id" 2>/dev/null || true
  done
  return 0
}

reload_nginx_if_running() {
  if docker ps --filter "label=${PROJECT_NAME}${LABEL_SEPARATOR}service=nginx" --format '{{.Names}}' | grep -q .; then
    if docker exec nginx nginx -s reload 2>/dev/null; then
      log "Nginx 已重载"
    else
      log "Nginx 重载失败（可手动执行 phpbox nginx reload）"
    fi
  fi
  return 0
}

cmd_php() {
  local action="${1:-help}"
  case "$action" in
    install)
      local ver="${2:-}"
      [ -z "$ver" ] && error "用法: phpbox php install <版本> [--extensions 扩展列表]"
      shift 2
      local exts=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --extensions)
            [ $# -ge 2 ] || error "--extensions 需要指定扩展列表"
            exts="${2}"; shift 2 ;;
          *) error "未知选项: $1" ;;
        esac
      done
      if [ -f "$EXT_DIR/php-${ver}.yml" ]; then
        error "PHP ${ver} 已安装，如需修改扩展请使用 'phpbox php extension add/remove'"
      fi
      if [ -n "$exts" ]; then
        _php_validate_extensions "$exts"
        _php_write_extensions "$ver" "$exts"
      fi
      init_config_files "php" "$ver"
      _php_generate_compose "$ver"
      _php_ensure_running "$ver"
      success "PHP ${ver} 安装完成"
      ;;
    extension)
      local sub="${2:-}"
      local ver="${3:-}"
      local ext="${4:-}"
      [ -z "$sub" ] && error "用法: phpbox php extension {add|remove} <版本> <扩展名>"
      [ -z "$ver" ] && error "请指定 PHP 版本"
      [ -z "$ext" ] && error "请指定扩展名"
      _php_validate_extensions "$ext"
      local current
      current="$(_php_read_extensions "$ver")"
      local new_exts=""
      if [ "$sub" = "add" ]; then
        if [[ ",$current," == *",$ext,"* ]]; then
          log "扩展 $ext 已存在"
          return 0
        fi
        new_exts="${current:+$current,}$ext"
      elif [ "$sub" = "remove" ]; then
        if [[ ",$current," != *",$ext,"* ]]; then
          log "扩展 $ext 不存在"
          return 0
        fi
        new_exts=$(echo "$current" | tr ',' '\n' | grep -v "^$ext$" | tr '\n' ',' | sed 's/,$//')
      else
        error "未知扩展操作: $sub (支持 add/remove)"
      fi

      _php_cleanup_images "$ver"
      rm -f "$EXT_DIR/php-${ver}.yml"
      _php_write_extensions "$ver" "$new_exts"
      _php_generate_compose "$ver"
      _php_ensure_running "$ver"
      reload_nginx_if_running
      success "PHP ${ver} 扩展已更新（${sub}: $ext）"
      ;;
    list)
      echo "已安装 PHP 版本:"
      for f in "$EXT_DIR"/php-*.yml; do
        [ -f "$f" ] || continue
        local ver
        ver=$(basename "$f" .yml | sed 's/php-//')
        local cname
        cname=$(get_container_name "php" "$ver")
        local status
        status=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo "不存在")
        local exts
        exts="$(_php_read_extensions "$ver")"
        printf "  %s  %s  (扩展: %s)\n" "$ver" "$status" "${exts:-无}"
      done
      ;;
    uninstall)
      local ver="${2:-}"
      local purge=false
      [ -z "$ver" ] && error "用法: phpbox php uninstall <版本> [--purge]"
      shift 2
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --purge) purge=true ;;
          *) error "未知选项: $1" ;;
        esac
        shift
      done
      if [ ! -f "$EXT_DIR/php-${ver}.yml" ]; then
        error "PHP ${ver} 未安装"
      fi
      log "卸载 PHP ${ver}"
      run_compose "php" "$ver" down 2>/dev/null || true
      _php_cleanup_images "$ver"
      rm -f "$EXT_DIR/php-${ver}.yml"
      rm -f "$(_php_get_extensions_file "$ver")"
      if $purge; then
        if [[ -t 0 ]]; then
          read -p "是否删除配置目录 $CONFIG_DIR/php/$ver ? (y/N): " confirm
          if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            rm -rf "$CONFIG_DIR/php/$ver"
          fi
        fi
      fi
      success "PHP ${ver} 已卸载"
      ;;
    *)
      error "未知 php 操作: $action (支持 install, extension, list, uninstall)"
      ;;
  esac
}
5. lib/mysql.sh

#!/bin/bash
# shellcheck shell=bash

_mysql_generate_compose() {
  local ver=$1
  local svc_key
  svc_key=$(get_service_key "mysql" "$ver")
  local cname
  cname=$(get_container_name "mysql" "$ver")
  # 确保密码已生成（stdout 丢弃，只留副作用）
  get_or_set_password "mysql" "$ver" >/dev/null
  local data_dir="${MYSQL_DATA_ROOT}/${ver}"
  local yml="$EXT_DIR/mysql-${ver}.yml"

  mkdir -p "$data_dir"
  # 使用临时容器以 root 设置权限，避免非 root 失败
  docker run --rm -v "$data_dir":/data alpine chown -R 999:999 /data || \
    log "警告：无法设置数据目录权限，MySQL 可能启动失败" >&2

  cat > "$yml" <<YEOF
services:
  $svc_key:
    image: mysql:${ver}
    container_name: $cname
    ports:
      - "\${MYSQL_${ver//./}_PORT}:3306"
    environment:
      MYSQL_ROOT_PASSWORD: "\${MYSQL_${ver//./}_ROOT_PASSWORD}"
    volumes:
      - \${MYSQL_DATA_ROOT}/${ver}:/var/lib/mysql
      - ./config/mysql/${ver}/my.cnf:/etc/mysql/conf.d/my.cnf:ro
    networks:
      - net
    restart: unless-stopped
    labels:
      - "${PROJECT_NAME}${LABEL_SEPARATOR}service=mysql"
      - "${PROJECT_NAME}${LABEL_SEPARATOR}version=${ver}"
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p\${MYSQL_${ver//./}_ROOT_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 5
YEOF
}

_mysql_ensure_running() {
  local ver=$1
  local svc_key
  svc_key=$(get_service_key "mysql" "$ver")
  run_compose "mysql" "$ver" up -d "$svc_key"
  local cname
  cname=$(get_container_name "mysql" "$ver")
  local pass
  pass=$(get_or_set_password "mysql" "$ver") || exit 1
  local timeout=30
  while [ $timeout -gt 0 ]; do
    if docker exec -e MYSQL_PWD="$pass" "$cname" mysqladmin ping -h localhost -u root &>/dev/null; then
      return 0
    fi
    sleep 2
    timeout=$((timeout - 2))
  done
  error "MySQL ${ver} 启动超时"
}

cmd_mysql() {
  local action="${1:-help}"
  case "$action" in
    install)
      local ver="${2:-}"
      [ -z "$ver" ] && error "用法: phpbox mysql install <版本> [--port 端口]"
      shift 2
      _generic_service_install "mysql" "$ver" "3306" "$@"
      ;;
    port)
      local sub="${2:-}"
      local ver="${3:-}"
      local new_port="${4:-}"
      [ "$sub" != "set" ] && error "用法: phpbox mysql port set <版本> <新端口>"
      [ -z "$ver" ] && error "请指定版本"
      [ -z "$new_port" ] && error "请指定新端口"
      _generic_db_port_set "mysql" "$ver" "$new_port" "3306"
      ;;
    list)
      echo "已安装 MySQL 版本:"
      for f in "$EXT_DIR"/mysql-*.yml; do
        [ -f "$f" ] || continue
        local ver
        ver=$(basename "$f" .yml | sed 's/mysql-//')
        local cname
        cname=$(get_container_name "mysql" "$ver")
        local status
        status=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo "不存在")
        local port
        port=$(read_env_value "MYSQL_${ver//./}_PORT" "3306")
        printf "  %s  %s  (端口: %s, 数据目录: %s/%s)\n" "$ver" "$status" "$port" "$MYSQL_DATA_ROOT" "$ver"
      done
      ;;
    uninstall)
      local ver="${2:-}"
      local purge=false
      [ -z "$ver" ] && error "用法: phpbox mysql uninstall <版本> [--purge]"
      shift 2
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --purge) purge=true ;;
          *) error "未知选项: $1" ;;
        esac
        shift
      done
      if [ ! -f "$EXT_DIR/mysql-${ver}.yml" ]; then
        error "MySQL ${ver} 未安装"
      fi
      log "卸载 MySQL ${ver}"
      run_compose "mysql" "$ver" down 2>/dev/null || true
      if $purge; then
        local data_dir="${MYSQL_DATA_ROOT}/${ver}"
        if [[ -t 0 ]]; then
          read -p "确认删除数据目录 ${data_dir} 吗？不可恢复！(y/N): " confirm
          if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            rm -rf "$data_dir"
          fi
        else
          log "非交互模式，保留数据目录"
        fi
        if [[ -t 0 ]]; then
          read -p "是否删除配置目录 $CONFIG_DIR/mysql/$ver ? (y/N): " del_conf
          if [[ "$del_conf" == "y" || "$del_conf" == "Y" ]]; then
            rm -rf "$CONFIG_DIR/mysql/$ver"
          fi
        fi
      else
        log "数据目录和配置已保留"
      fi
      rm -f "$EXT_DIR/mysql-${ver}.yml"
      success "MySQL ${ver} 已卸载"
      ;;
    *)
      error "未知 mysql 操作: $action (支持 install, port, list, uninstall)"
      ;;
  esac
}
6. lib/redis.sh

#!/bin/bash
# shellcheck shell=bash

_redis_generate_compose() {
  local ver=$1
  local svc_key
  svc_key=$(get_service_key "redis" "$ver")
  local cname
  cname=$(get_container_name "redis" "$ver")
  local vol_name
  vol_name=$(get_volume_name "redis" "$ver")
  local yml="$EXT_DIR/redis-${ver}.yml"

  cat > "$yml" <<YEOF
volumes:
  $vol_name:
    name: $vol_name
    labels:
      - "${PROJECT_NAME}.backup=true"
services:
  $svc_key:
    image: redis:${ver}-alpine
    container_name: $cname
    ports:
      - "\${REDIS_${ver//./}_PORT}:6379"
    volumes:
      - $vol_name:/data
    networks:
      - net
    restart: unless-stopped
    labels:
      - "${PROJECT_NAME}${LABEL_SEPARATOR}service=redis"
      - "${PROJECT_NAME}${LABEL_SEPARATOR}version=${ver}"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
YEOF
}

_redis_ensure_running() {
  local ver=$1
  local svc_key
  svc_key=$(get_service_key "redis" "$ver")
  run_compose "redis" "$ver" up -d "$svc_key"
  local cname
  cname=$(get_container_name "redis" "$ver")
  local timeout=20
  while [ $timeout -gt 0 ]; do
    if docker exec "$cname" redis-cli ping | grep -q PONG; then
      return 0
    fi
    sleep 2
    timeout=$((timeout - 2))
  done
  error "Redis ${ver} 启动或 PING 验证失败"
}

cmd_redis() {
  local action="${1:-help}"
  case "$action" in
    install)
      local ver="${2:-}"
      [ -z "$ver" ] && error "用法: phpbox redis install <版本> [--port 端口]"
      shift 2
      _generic_service_install "redis" "$ver" "6379" "$@"
      ;;
    port)
      local sub="${2:-}"
      local ver="${3:-}"
      local new_port="${4:-}"
      [ "$sub" != "set" ] && error "用法: phpbox redis port set <版本> <新端口>"
      [ -z "$ver" ] && error "请指定版本"
      [ -z "$new_port" ] && error "请指定新端口"
      _generic_db_port_set "redis" "$ver" "$new_port" "6379"
      ;;
    list)
      echo "已安装 Redis 版本:"
      for f in "$EXT_DIR"/redis-*.yml; do
        [ -f "$f" ] || continue
        local ver
        ver=$(basename "$f" .yml | sed 's/redis-//')
        local cname
        cname=$(get_container_name "redis" "$ver")
        local status
        status=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo "不存在")
        local port
        port=$(read_env_value "REDIS_${ver//./}_PORT" "6379")
        printf "  %s  %s  (端口: %s)\n" "$ver" "$status" "$port"
      done
      ;;
    uninstall)
      local ver="${2:-}"
      local purge=false
      [ -z "$ver" ] && error "用法: phpbox redis uninstall <版本> [--purge]"
      shift 2
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --purge) purge=true ;;
          *) error "未知选项: $1" ;;
        esac
        shift
      done
      if [ ! -f "$EXT_DIR/redis-${ver}.yml" ]; then
        error "Redis ${ver} 未安装"
      fi
      log "卸载 Redis ${ver}"
      run_compose "redis" "$ver" down 2>/dev/null || true
      local vol_name
      vol_name=$(get_volume_name "redis" "$ver")
      if $purge; then
        if [[ -t 0 ]]; then
          read -p "确认删除数据卷 ${vol_name} 吗？(y/N): " confirm
          if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            docker volume rm -f "$vol_name" 2>/dev/null || true
          fi
        else
          log "非交互模式，保留数据卷"
        fi
        if [[ -t 0 ]]; then
          read -p "是否删除配置目录 $CONFIG_DIR/redis/$ver ? (y/N): " del_conf
          if [[ "$del_conf" == "y" || "$del_conf" == "Y" ]]; then
            rm -rf "$CONFIG_DIR/redis/$ver"
          fi
        fi
      else
        log "配置和数据卷已保留"
      fi
      rm -f "$EXT_DIR/redis-${ver}.yml"
      success "Redis ${ver} 已卸载"
      ;;
    *)
      error "未知 redis 操作: $action (支持 install, port, list, uninstall)"
      ;;
  esac
}
7. lib/nginx.sh

#!/bin/bash
# shellcheck shell=bash

_nginx_generate_compose() {
  local ver="alpine"
  local yml="$EXT_DIR/nginx-default.yml"

  init_config_files "nginx" "$ver"

  cat > "$yml" <<YEOF
services:
  nginx:
    image: nginx:${ver}
    container_name: nginx
    ports:
      - "\${NGINX_PORT}:80"
    volumes:
      - \${WWW_ROOT}:/var/www:ro
      - ./config/nginx/${ver}/conf.d:/etc/nginx/conf.d:ro
      - ./config/nginx/${ver}/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./config/nginx/sites:/etc/nginx/sites:ro
      - ./logs/nginx:/var/log/nginx:rw
    networks:
      - net
    restart: unless-stopped
    labels:
      - "${PROJECT_NAME}${LABEL_SEPARATOR}service=nginx"
      - "${PROJECT_NAME}${LABEL_SEPARATOR}version=${ver}"
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1/"]
      interval: 10s
      timeout: 5s
      retries: 5
YEOF
}

_nginx_ensure_running() {
  local ver="alpine"
  docker run --rm \
    --user "$CURRENT_UID:$CURRENT_GID" \
    -v "$CONFIG_DIR/nginx/$ver":/etc/nginx:ro \
    -v "$CONFIG_DIR/nginx/sites":/etc/nginx/sites:ro \
    nginx:$ver nginx -t || error "Nginx 配置验证失败"

  run_compose "nginx" "default" up -d "nginx"
  # 启动后只读端口，不调用 get_or_set_port，防止把自身占用误判为冲突而改写 .env
  local port="${NGINX_PORT}"
  local timeout=20
  while [ $timeout -gt 0 ]; do
    if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port" | grep -qE '200|301|302|404'; then
      return 0
    fi
    sleep 2
    timeout=$((timeout - 2))
  done
  error "Nginx 启动或可用性检查失败"
}

_nginx_remove() {
  run_compose "nginx" "default" down 2>/dev/null || true
  docker rm -f nginx 2>/dev/null || true
  rm -f "$EXT_DIR/nginx-default.yml"
}

cmd_nginx() {
  local action="${1:-help}"
  case "$action" in
    install)
      shift
      local port=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --port)
            [ $# -ge 2 ] || error "--port 需要指定端口号"
            port="${2}"
            if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
              error "端口号必须是 1-65535 之间的数字"
            fi
            shift 2 ;;
          *) error "未知选项: $1" ;;
        esac
      done
      if [ -f "$EXT_DIR/nginx-default.yml" ]; then
        echo -e "${YELLOW}Nginx 已安装 (使用 nginx:alpine)${NC}" >&2
        if [[ -t 0 ]]; then
          read -p "是否安全重装（保留配置和站点）？(y/N): " answer
          if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
            log "取消重装"
            return 0
          fi
        else
          error "非交互模式，取消重装"
        fi
        _nginx_remove
      fi

      if [ -n "$port" ]; then
        # 排除 NGINX_PORT 自身的登记，允许用相同端口重装
        if ! check_and_report_port "$port" "NGINX_PORT"; then
          error "端口 ${port} 不可用"
        fi
        set_env_value "NGINX_PORT" "$port"
      else
        if ! grep -q "^NGINX_PORT=" "$ENV_FILE"; then
          # 不存在才分配，绕开 get_or_set_port 的"已存在仍可能改写"分支
          local free_port
          free_port=$(find_free_port 80)
          set_env_value "NGINX_PORT" "$free_port"
        elif ! check_port "${NGINX_PORT}"; then
          error "NGINX_PORT=${NGINX_PORT} 已被其他进程占用，请执行 'phpbox nginx port set <新端口>' 或编辑 .env 后重试"
        fi
      fi

      _nginx_generate_compose
      _nginx_ensure_running
      success "Nginx 安装完成，端口: ${NGINX_PORT}"
      ;;
    port)
      local sub="${2:-}"
      local new_port="${3:-}"
      [ "$sub" != "set" ] && error "用法: phpbox nginx port set <新端口>"
      [ -z "$new_port" ] && error "请指定新端口"

      if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        error "端口号必须是 1-65535 之间的数字"
      fi

      local old_port
      old_port=$(read_env_value "NGINX_PORT" "")
      if [ -z "$old_port" ]; then
        error "Nginx 端口未记录"
      fi

      if [ "$new_port" = "$old_port" ]; then
        log "Nginx 端口已经是 ${new_port}，无需修改"
        return 0
      fi

      # 排除 NGINX_PORT 自身的登记检查
      if ! check_and_report_port "$new_port" "NGINX_PORT"; then
        error "端口 ${new_port} 不可用"
      fi

      local temp_env
      temp_env=$(mktemp) || error "无法创建临时文件"
      cp "$ENV_FILE" "$temp_env"
      set_env_value "NGINX_PORT" "$new_port"

      if ! run_compose "nginx" "default" up -d --force-recreate nginx 2>&1; then
        cp "$temp_env" "$ENV_FILE"
        export NGINX_PORT="$old_port"
        rm -f "$temp_env"
        error "端口变更失败，已回滚"
      fi

      local timeout=20
      while [ $timeout -gt 0 ]; do
        if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$new_port" | grep -qE '200|301|302|404'; then
          rm -f "$temp_env"
          success "Nginx 端口已改为 ${new_port}"
          return 0
        fi
        sleep 2
        timeout=$((timeout - 2))
      done

      cp "$temp_env" "$ENV_FILE" 2>/dev/null || true
      export NGINX_PORT="$old_port"
      run_compose "nginx" "default" up -d --force-recreate nginx >/dev/null 2>&1 || true
      rm -f "$temp_env"
      error "新端口验证失败，已回滚"
      ;;
    reload)
      local ver="alpine"
      docker run --rm \
        --user "$CURRENT_UID:$CURRENT_GID" \
        -v "$CONFIG_DIR/nginx/$ver":/etc/nginx:ro \
        -v "$CONFIG_DIR/nginx/sites":/etc/nginx/sites:ro \
        nginx:$ver nginx -t || error "配置验证失败"
      if docker exec nginx nginx -s reload 2>/dev/null; then
        success "Nginx 重载成功"
      else
        error "Nginx 重载失败，请检查日志"
      fi
      ;;
    uninstall)
      log "卸载 Nginx（保留配置和站点）"
      _nginx_remove
      success "Nginx 已卸载，配置保留于 config/nginx/"
      ;;
    *)
      error "未知 nginx 操作: $action (支持 install, port, reload, uninstall)"
      ;;
  esac
}
8. lib/site.sh

#!/bin/bash
# shellcheck shell=bash

SITES_DIR="$CONFIG_DIR/nginx/sites"

_valid_domain() {
  [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]
}

cmd_hosts() {
  local action="${1:-help}"
  local domain="${2:-}"
  local hosts_file="/etc/hosts"

  if [ "$action" != "list" ]; then
    if ! sudo -n true 2>/dev/null; then
      error "hosts 操作需要 sudo 权限，请配置 NOPASSWD 或使用 sudo"
    fi
  fi

  case "$action" in
    add)
      [ -z "$domain" ] && error "用法: phpbox hosts add <域名>"
      _valid_domain "$domain" || error "无效域名:$domain"
      local ed
      ed=$(escape_sed_regex "$domain")
      # 锚定整行匹配，避免子串误判（如 demo.test 误判 demo.test.local）
      if grep -qE "^127\.0\.0\.1[[:space:]]+${ed}([[:space:]]|$)" "$hosts_file"; then
        log "域名 ${domain} 已存在"
      else
        echo "127.0.0.1 ${domain}" | sudo tee -a "$hosts_file" > /dev/null
        success "已添加: 127.0.0.1 ${domain}"
      fi
      ;;
    remove)
      [ -z "$domain" ] && error "用法: phpbox hosts remove <域名>"
      _valid_domain "$domain" || error "无效域名:$domain"
      local ed
      ed=$(escape_sed_regex "$domain")
      if grep -qE "^127\.0\.0\.1[[:space:]]+${ed}([[:space:]]|$)" "$hosts_file"; then
        # [[:space:]][[:space:]]* 兼容 macOS BSD sed（\+ 不被支持）
        if [[ "$OSTYPE" == "darwin"* ]]; then
          sudo sed -i "" "/^127\.0\.0\.1[[:space:]][[:space:]]*${ed}\$/d" "$hosts_file"
        else
          sudo sed -i "/^127\.0\.0\.1[[:space:]][[:space:]]*${ed}\$/d" "$hosts_file"
        fi
        success "已移除: $domain"
      else
        log "域名 ${domain} 未找到"
      fi
      ;;
    list)
      echo "当前 hosts 状态（phpbox 管理的站点）:"
      if [ -z "$(ls -A "$SITES_DIR" 2>/dev/null)" ]; then
        echo "  (无站点)"
      else
        for f in "$SITES_DIR"/*.conf; do
          [ -f "$f" ] || continue
          local site_name
          site_name=$(basename "$f" .conf)
          local ed
          ed=$(escape_sed_regex "$site_name")
          if grep -qE "^127\.0\.0\.1[[:space:]]+${ed}([[:space:]]|$)" "$hosts_file"; then
            echo "  [已添加] $site_name"
          else
            echo "  [未添加] $site_name"
          fi
        done
      fi
      ;;
    *) error "未知 hosts 操作: $action" ;;
  esac
}

_site_atomic_replace() {
  local site=$1
  local new_conf=$2
  local tmp_conf="$SITES_DIR/.tmp.$site.conf"
  local backup_conf="$SITES_DIR/.backup.$site.conf"
  local final_conf="$SITES_DIR/${site}.conf"

  if [ -f "$final_conf" ]; then
    cp "$final_conf" "$backup_conf"
  else
    touch "$backup_conf"
  fi

  cat > "$tmp_conf" <<EOF$new_conf
EOF

  mv "$tmp_conf" "$final_conf"

  local ver="alpine"
  if ! docker run --rm \
        --user "$CURRENT_UID:$CURRENT_GID" \
        -v "$CONFIG_DIR/nginx/$ver":/etc/nginx:ro \
        -v "$CONFIG_DIR/nginx/sites":/etc/nginx/sites:ro \
        nginx:$ver nginx -t &>/dev/null; then
    if [ -s "$backup_conf" ]; then
      mv "$backup_conf" "$final_conf"
    else
      rm -f "$final_conf"
    fi
    error "Nginx 配置验证失败，站点变更已回滚"
  fi

  if ! docker exec nginx nginx -s reload 2>/dev/null; then
    if [ -s "$backup_conf" ]; then
      mv "$backup_conf" "$final_conf"
    else
      rm -f "$final_conf"
    fi
    docker run --rm \
      --user "$CURRENT_UID:$CURRENT_GID" \
      -v "$CONFIG_DIR/nginx/$ver":/etc/nginx:ro \
      -v "$CONFIG_DIR/nginx/sites":/etc/nginx/sites:ro \
      nginx:$ver nginx -t >/dev/null
    if docker exec nginx nginx -s reload >/dev/null; then
      :
    fi
    error "Nginx 重载失败，站点变更已回滚"
  fi

  rm -f "$backup_conf"
  success "站点 ${site} 配置已应用并重载"
}

cmd_site() {
  local action="${1:-help}"
  case "$action" in
    add)
      # 跳过动作名 "add"
      shift
      if [ $# -lt 1 ]; then
        error "用法: phpbox site add <域名> --php <版本> 或 site add <域名> <版本>"
      fi
      local site="$1"; shift
      local php_ver=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --php)
            [ $# -ge 2 ] || error "--php 需要指定版本"
            php_ver="${2}"; shift 2 ;;
          *)
            if [ -z "$php_ver" ]; then
              php_ver="$1"; shift
            else
              error "未知选项: $1"
            fi
            ;;
        esac
      done
      [ -z "$php_ver" ] && error "请指定 PHP 版本"

      if ! _valid_domain "$site"; then
        error "无效域名: $site（仅允许字母、数字、短横线、点，且每段以字母数字开头结尾）"
      fi

      if [ ! -f "$EXT_DIR/nginx-default.yml" ]; then
        error "Nginx 未安装，请先执行 'phpbox nginx install'"
      fi
      local php_key
      php_key=$(get_service_key "php" "$php_ver")
      if ! docker ps --filter "label=${PROJECT_NAME}${LABEL_SEPARATOR}service=php" \
                --filter "label=${PROJECT_NAME}${LABEL_SEPARATOR}version=${php_ver}" --format "{{.Names}}" | grep -q .; then
        error "PHP ${php_ver} 未运行，请先安装并启动"
      fi
      if [ -f "$SITES_DIR/${site}.conf" ]; then
        error "站点 ${site} 已存在"
      fi
      mkdir -p "${WWW_ROOT}/${site}"
      local new_conf="server {
    listen 80;
    server_name ${site};
    root /var/www/${site};
    index index.php index.html;
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    location ~ \.php$ {
        fastcgi_pass ${php_key}:9000;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}"
      _site_atomic_replace "$site" "$new_conf"
      local port
      port=$(read_env_value "NGINX_PORT" "80")
      echo -e "${CYAN}站点${site} 已创建，访问地址: http://${site}:${port}${NC}"
      if [ "$port" != "80" ]; then
        echo -e "${CYAN}注意：Nginx 监听端口${port}，请使用该端口访问${NC}"
      fi
      echo -e "${CYAN}使用 'phpbox hosts add${site}' 添加域名解析${NC}"
      ;;
    switch)
      # 跳过动作名 "switch"
      shift
      if [ $# -lt 1 ]; then
        error "用法: phpbox site switch <域名> --php <版本>"
      fi
      local site="$1"; shift
      local php_ver=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --php)
            [ $# -ge 2 ] || error "--php 需要指定版本"
            php_ver="${2}"; shift 2 ;;
          *)
            if [ -z "$php_ver" ]; then
              php_ver="$1"; shift
            else
              error "未知选项: $1"
            fi
            ;;
        esac
      done
      [ -z "$php_ver" ] && error "请指定 PHP 版本"
      local conf="$SITES_DIR/${site}.conf"
      [ -f "$conf" ] || error "站点${site} 不存在"
      local php_key
      php_key=$(get_service_key "php" "$php_ver")
      if ! docker ps --filter "label=${PROJECT_NAME}${LABEL_SEPARATOR}service=php" \
                --filter "label=${PROJECT_NAME}${LABEL_SEPARATOR}version=${php_ver}" --format "{{.Names}}" | grep -q .; then
        error "PHP ${php_ver} 未运行"
      fi
      local old_conf
      old_conf=$(cat "$conf")
      local new_conf
      new_conf=$(echo "$old_conf" | sed "s|fastcgi_pass .*:9000;|fastcgi_pass ${php_key}:9000;|")
      _site_atomic_replace "$site" "$new_conf"
      success "站点 ${site} 已切换至 PHP${php_ver}"
      ;;
    list)
      echo "站点列表:"
      if [ -z "$(ls -A "$SITES_DIR" 2>/dev/null)" ]; then
        echo "  (无站点)"
      else
        for f in "$SITES_DIR"/*.conf; do
          [ -f "$f" ] || continue
          local name
          name=$(basename "$f" .conf)
          local php
          php=$(grep fastcgi_pass "$f" | awk '{print $2}' | cut -d: -f1)
          echo "  ${name} ->${php}"
        done
      fi
      ;;
    remove)
      local site="${2:-}"
      [ -z "$site" ] && error "用法: phpbox site remove <域名>"
      local conf="$SITES_DIR/${site}.conf"
      [ -f "$conf" ] || error "站点${site} 不存在"
      local backup_conf="$SITES_DIR/.backup.$site.conf"
      cp "$conf" "$backup_conf"
      rm -f "$conf"
      local ver="alpine"
      if docker run --rm \
           --user "$CURRENT_UID:$CURRENT_GID" \
           -v "$CONFIG_DIR/nginx/$ver":/etc/nginx:ro \
           -v "$CONFIG_DIR/nginx/sites":/etc/nginx/sites:ro \
           nginx:$ver nginx -t &>/dev/null; then
        if docker exec nginx nginx -s reload 2>/dev/null; then
          :
        else
          mv "$backup_conf" "$conf"
          error "删除站点后重载失败，已恢复"
        fi
        rm -f "$backup_conf"
      else
        mv "$backup_conf" "$conf"
        error "删除站点后配置无效，已恢复"
      fi
      local site_dir="${WWW_ROOT}/${site}"
      if [ -d "$site_dir" ]; then
        if [[ -t 0 ]]; then
          read -p "是否删除站点目录 ${site_dir} ? (y/N): " del_ans
          if [[ "$del_ans" == "y" || "$del_ans" == "Y" ]]; then
            rm -rf "$site_dir"
          fi
        fi
      fi
      success "站点 ${site} 已删除"
      echo -e "${CYAN}如需移除域名解析，请执行 'phpbox hosts remove${site}'${NC}"
      ;;
    *)
      error "未知 site 操作: $action"
      ;;
  esac
}
9. lib/backup.sh

#!/bin/bash
# shellcheck shell=bash

_get_abs_path() {
  local path=$1
  if command -v realpath &>/dev/null && realpath -m "$path" &>/dev/null; then
    realpath -m "$path"
  else
    python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$path" 2>/dev/null || echo "$path"
  fi
}

PHPBOX_STOPPED=()
_phpbox_stop_svc() {
  local svc=$1 f ver cname
  for f in "$EXT_DIR"/${svc}-*.yml; do
    [ -f "$f" ] || continue
    ver=$(basename "$f" .yml | sed "s/${svc}-//")
    cname=$(get_container_name "$svc" "$ver")
    if docker inspect -f '{{.State.Running}}' "$cname" 2>/dev/null | grep -q '^true$'; then
      docker stop "$cname" >/dev/null 2>&1 || true
      PHPBOX_STOPPED+=("$cname")
    fi
  done
}

_phpbox_start_stopped() {
  local cname
  for cname in "${PHPBOX_STOPPED[@]+"${PHPBOX_STOPPED[@]}"}"; do
    [ -n "$cname" ] && docker start "$cname" >/dev/null 2>&1 || true
  done
}

cmd_backup() {
  local timestamp
  timestamp=$(date +%Y-%m-%d${BACKUP_NAME_SEPARATOR}%H-%M)
  local f="$BACKUP_DIR/backup${timestamp}.tar.gz"
  local tmpd
  tmpd=$(mktemp -d) || error "无法创建临时目录"
  local vol_files=()
  PHPBOX_STOPPED=()

  trap 'rm -rf "$tmpd"; for vf in "${vol_files[@]+"${vol_files[@]}"}"; do rm -f "$BACKUP_DIR/$vf"; done; _phpbox_start_stopped' EXIT

  log "备份进行中..."
  log "暂停 MySQL/Redis 容器以保证数据一致性..."
  _phpbox_stop_svc mysql
  _phpbox_stop_svc redis

  while IFS= read -r -d '' vol; do
    docker run --rm -v "$vol":/source:ro -v "$tmpd":/backup alpine tar czf "/backup/${vol}.tar.gz" -C /source .
  done < <(docker volume ls --filter "label=${PROJECT_NAME}.backup=true" --format '{{.Name}}' | tr '\n' '\0' || true)

  local backup_items=()
  backup_items+=("$ENV_FILE")
  backup_items+=("$CONFIG_DIR")
  backup_items+=("$STATE_DIR")
  backup_items+=("$COMPOSE_DIR")  # 包含主 compose 文件和 services 目录
  if [ -d "$WWW_ROOT" ]; then
    backup_items+=("$WWW_ROOT")
  fi
  if [ -d "$MYSQL_DATA_ROOT" ]; then
    backup_items+=("$MYSQL_DATA_ROOT")
  fi

  for vf in "$tmpd"/*.tar.gz; do
    [ -f "$vf" ] || continue
    cp "$vf" "$BACKUP_DIR/"
    vol_files+=("$(basename "$vf")")
    backup_items+=("$BACKUP_DIR/$(basename "$vf")")
  done

  (cd / && tar -czf "$f" "${backup_items[@]#/}") || error "备份打包失败"

  rm -rf "$tmpd"
  for vf in "${vol_files[@]+"${vol_files[@]}"}"; do
    rm -f "$BACKUP_DIR/$vf"
  done
  _phpbox_start_stopped
  trap - EXIT

  success "备份完成: $f"
}

cmd_restore() {
  local f="${1:-}"
  [ -z "$f" ] && error "用法: phpbox restore <备份文件> [-y]"
  local auto_yes=false
  case "${2:-}" in
    "") ;;
    -y) auto_yes=true ;;
    *) error "未知选项: ${2}" ;;
  esac
  [ -f "$f" ] || error "备份文件不存在:$f"

  local content
  content=$(tar -tzf "$f" | head -n 20)
  if ! $auto_yes; then
    echo -e "${YELLOW}恢复操作将覆盖以下路径（相对根目录）：${NC}" >&2
    echo "$content" | sed 's/^/  /' >&2
    if [[ -t 0 ]]; then
      read -p "确认恢复到原始绝对路径？(y/N): " ans
      if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
        error "已取消恢复"
      fi
    else
      error "非交互模式，请使用 -y 参数确认"
    fi
  fi

  local vol_files=()
  while IFS= read -r line; do
    if [[ "$line" =~${PROJECT_NAME}_.*\.tar\.gz$ ]]; then
      vol_files+=("$(basename "$line")")
    fi
  done < <(tar -tzf "$f")

  local invalid_paths=()
  while IFS= read -r path; do
    # 先拒绝任何包含 .. 的路径（文件或目录），目录条目不得绕过该检查
    if [[ "$path" == *".."* ]]; then
      invalid_paths+=("$path")
      continue
    fi
    # 再跳过目录条目（tar 归档必然包含父目录，如 home/、home/user/）
    [[ "$path" == */ ]] && continue
    local abs_path
    if [[ "$path" == /* ]]; then
      abs_path=$(_get_abs_path "$path")
    else
      abs_path=$(_get_abs_path "/$path")
    fi
    if [[ "$abs_path" != "$BASE_DIR"/* && "$abs_path" != "$BASE_DIR" && \
          "$abs_path" != "$WWW_ROOT"/* && "$abs_path" != "$WWW_ROOT" && \
          "$abs_path" != "$MYSQL_DATA_ROOT"/* && "$abs_path" != "$MYSQL_DATA_ROOT" ]]; then
      invalid_paths+=("$path")
    fi
  done < <(tar -tzf "$f")
  if [ ${#invalid_paths[@]} -gt 0 ]; then
    error "归档包含非法路径: ${invalid_paths[*]}"
  fi

  log "停止 MySQL/Redis 容器以便安全恢复..."
  PHPBOX_STOPPED=()
  trap '_phpbox_start_stopped' EXIT
  _phpbox_stop_svc mysql
  _phpbox_stop_svc redis

  log "恢复备份..."
  (cd / && tar -xzPf "$f" --no-same-owner --no-same-permissions)

  for vf in "${vol_files[@]+"${vol_files[@]}"}"; do
    local vname
    vname=$(basename "$vf" .tar.gz)
    log "恢复卷: $vname"
    if ! $auto_yes && [[ -t 0 ]]; then
      read -p "覆盖卷 ${vname}? (y/N): " confirm
      if [[ "$confirm" != "y" ]]; then
        log "跳过"
        continue
      fi
    fi
    # 卷已存在时先删除旧卷，避免 tar 解入旧数据造成混杂
    if docker volume inspect "$vname" &>/dev/null; then
      if ! $auto_yes && [[ -t 0 ]]; then
        read -p "卷 ${vname} 已存在，是否删除旧卷后恢复？(y/N): " del_vol
        if [[ "$del_vol" == "y" || "$del_vol" == "Y" ]]; then
          docker volume rm -f "$vname" >/dev/null 2>&1 || true
        else
          log "跳过卷 ${vname}"
          continue
        fi
      else
        docker volume rm -f "$vname" >/dev/null 2>&1 || true
      fi
    fi
    docker volume create "$vname" >/dev/null 2>&1 || true
    docker run --rm -v "$vname":/target -v "$BACKUP_DIR":/backup alpine tar xzPf "/backup/$vf" -C /target --no-same-owner --no-same-permissions
    rm -f "$BACKUP_DIR/$vf"
  done

  _phpbox_start_stopped
  trap - EXIT

  reload_nginx_if_running
  log "恢复完成。若服务配置有变化，请执行 'phpbox <服务> install' 或手动强制重建容器" >&2
  success "恢复完成，已自动重启被暂停的服务；如启动异常请查看 docker logs"
}
10. .env.example

PROJECT_NAME=phpbox
NETWORK_NAME=phpboxnet
WWW_ROOT=/home/user/www
MYSQL_DATA_ROOT=/home/user/mysql-data
CURRENT_UID=1000
CURRENT_GID=1000
NGINX_PORT=80
PHP_SERVICE_PREFIX=php
MYSQL_SERVICE_PREFIX=mysql
REDIS_SERVICE_PREFIX=redis
NGINX_SERVICE_PREFIX=nginx
LABEL_SEPARATOR=-
IMAGE_TAG_SEPARATOR=-
BACKUP_NAME_SEPARATOR=-
IMAGE_PREFIX=phpbox
粘贴后必跑的验证

# 1) 语法全过（关键防线：若复制吃空白，这里会当场报错）
for f in ~/phpbox/bin/phpbox ~/phpbox/lib/*.sh; do bash -n "$f" && echo "OK:$f"; done

# 2) 历史坏模式必须全部无输出
grep -rnF -e '<<EOF$new_conf' -e 'echo${' -e 'install-php-extensions${' \
           -e '=~${' -e '"$used "' -e '站点${' -e 'hosts add${' ~/phpbox/lib/

# 3) 本轮 MySQL 修复点正向确认（应命中 "-lt 9"）
grep -n 'mysql_major" -lt 9' ~/phpbox/lib/common.sh

# 4) 功能验证
phpbox mysql install 8.0 && cat ~/phpbox/config/mysql/8.0/my.cnf
# 应包含 default-authentication-plugin=mysql_native_password

phpbox php install 8.4 --extensions gd,redis && phpbox php list
phpbox site add demo.test --php 8.4 && phpbox site list    # 应显示 demo.test -> php84
phpbox nginx uninstall && phpbox nginx install             # 同端口重装应成功
phpbox mysql port set 8.0 3307 && docker port mysql80      # 应显示 3307