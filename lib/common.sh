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

# 站点配置在容器内的挂载点：刻意与 Nginx 版本解耦——无论用 nginx:alpine 还是其它 tag，
# 站点一律放 config/nginx/sites/，每个站点一个 <域名>.conf，由主配置统一 include
SITES_MOUNT_PATH="/etc/nginx/sites"
SITES_INCLUDE_LINE="include ${SITES_MOUNT_PATH}/*.conf;"

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

# log/success 一律走 stderr：项目里大量函数以 stdout 返回值、调用方用命令替换捕获，
# 日志若混入 stdout 会污染返回值——曾把彩色日志行拼进生成的 compose yml 导致解析失败
log()    { echo -e "${CYAN}[INFO] $*${NC}" >&2; }
success(){ echo -e "${GREEN}[OK]   $*${NC}" >&2; }
# 统一失败出口：打印红色错误到 stderr 后立即退出整个脚本——全项目依赖这一约定
error()  { echo -e "${RED}[ERR]  $*${NC}" >&2; exit 1; }

sed_i() {
  # macOS(BSD) 的 sed 要求 -i 后跟空串参数，Linux(GNU) 不需要——统一封装抹平差异
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i "" "$@"
  else
    sed -i "$@"
  fi
}

# 交互确认：仅在终端可用时提问（回车默认拒绝）；非终端环境直接返回 1（不删除）
confirm_yes() {
  local prompt=$1
  [[ -t 0 ]] || return 1   # -t 0：标准输入是否连着终端；脚本/管道环境一律视为拒绝
  local ans
  read -p "${prompt} (y/N): " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

load_env() {
  if [ -f "$ENV_FILE" ]; then
    # IFS='=' 使 read 按等号拆分：key 取第一段，剩余全部并入 value（密码含 = 也不会截断）
    while IFS='=' read -r key value; do
      [[ "$key" =~ ^[[:space:]]*# ]] && continue   # 注释行（允许行首空白）：跳过
      [[ -z "$key" ]] && continue                  # 空行：跳过
      value="${value%$'\r'}"                       # 去掉行尾 \r，兼容 Windows 换行编辑过的 .env
      export "$key"="$value"                       # 键名以字符串形式给出，逐行导出为环境变量
    done < "$ENV_FILE"
  fi

  PROJECT_NAME="${PROJECT_NAME:-phpbox}"
  NETWORK_NAME="${NETWORK_NAME:-phpboxnet}"
  WWW_ROOT="${WWW_ROOT:-$HOME/www}"
  IMAGE_PREFIX="${IMAGE_PREFIX:-phpbox}"
  # ${VAR:--} 的写法：未设置时默认值为字面量 '-'（冒号后第一个 - 是语法，第二个 - 是默认值本身）
  LABEL_SEPARATOR="${LABEL_SEPARATOR:--}"
  IMAGE_TAG_SEPARATOR="${IMAGE_TAG_SEPARATOR:--}"
  BACKUP_NAME_SEPARATOR="${BACKUP_NAME_SEPARATOR:--}"
  NGINX_PORT="${NGINX_PORT:-80}"
  # Nginx 镜像 tag：默认 alpine。改它即可整体换 Nginx（如 NGINX_VERSION=1.30），
  # 站点目录与配置注入逻辑不随版本变化
  NGINX_VERSION="${NGINX_VERSION:-alpine}"
  CURRENT_UID="${CURRENT_UID:-$(id -u)}"
  CURRENT_GID="${CURRENT_GID:-$(id -g)}"
  MYSQL_DATA_ROOT="${MYSQL_DATA_ROOT:-$HOME/mysql-data}"
  # PHP 缺省安装的扩展集（php install 不带 --extensions 时生效）。
  # curl/openssl/mbstring/pdo/sqlite3/xml/xmlwriter/xmlreader/simplexml/dom/fileinfo
  # 以及 sodium/pcntl/posix 等已编译进 php-fpm-alpine 镜像，无需也不能重复安装；
  # mongodb/memcached/sqlsrv/ldap 等低频扩展按需 extension add，不进默认集。
  # apcu 暂不进默认：pecl 对其最新版（5.1.28）依赖元数据缺失、固定版本（5.1.27）查询
  # 也失败，两条安装路径当前必败；上游恢复后用 extension add 装回并加回此列表
  PHP_DEFAULT_EXTENSIONS="${PHP_DEFAULT_EXTENSIONS:-gd,redis,pdo_mysql,mysqli,pgsql,pdo_pgsql,zip,bcmath,intl,opcache,exif,soap,sockets,imagick,xdebug}"

  export PROJECT_NAME NETWORK_NAME WWW_ROOT IMAGE_PREFIX LABEL_SEPARATOR IMAGE_TAG_SEPARATOR BACKUP_NAME_SEPARATOR NGINX_PORT NGINX_VERSION CURRENT_UID CURRENT_GID MYSQL_DATA_ROOT PHP_DEFAULT_EXTENSIONS
  # SITES_DIR 由 site.sh 定义；仅加载部分库时回退到默认站点目录，确保目录始终存在
  mkdir -p "$WWW_ROOT" "$COMPOSE_DIR" "$EXT_DIR" "$CONFIG_DIR" "$LOG_DIR" "$BACKUP_DIR" "$STATE_DIR" "$MYSQL_DATA_ROOT" "${SITES_DIR:-$CONFIG_DIR/nginx/sites}"

  # 主 compose 文件属于生成物（不入仓）：干净 clone 后首次执行任意命令时自愈生成。
  # 它只定义共享网络，具体服务由 compose/services/*.yml 分片提供
  if [ ! -f "$COMPOSE_FILE" ]; then
    printf 'networks:\n  net:\n    driver: bridge\n    name: ${NETWORK_NAME:-phpboxnet}\n' > "$COMPOSE_FILE"
  fi
}

# 版本号去掉点：8.4 → 84。服务名/容器名/镜像 tag/文件名不允许出现点，统一用无点形式
get_service_key() { echo "${1}${2//./}"; }

# 版本号白名单：仅允许 8.4 / 8.0.35 这类纯数字点分格式。
# 版本号会被拼进文件名、容器名、镜像 tag 和 .env 键名——空格/分号等字符会注入破坏这些位置，
# 甚至写出含空格的 .env 键污染后续所有命令
validate_version() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || error "无效版本号: $1（示例: 8.4、8.0.35）"
}

# 端口在 .env 中的键名：服务名_去点版本_PORT 转大写（如 MYSQL_84_PORT）
port_key() { echo "${1}_${2//./}_PORT" | tr '[:lower:]' '[:upper:]'; }
get_container_name() {
  local svc=$1 ver=$2
  local prefix_var="${svc^^}_SERVICE_PREFIX"   # ${svc^^} 转大写：php → PHP，拼出变量名 PHP_SERVICE_PREFIX
  local prefix="${!prefix_var:-$svc}"          # ${!var} 间接展开：读取该名字变量的值；未设置则回退为服务名本身
  echo "${prefix}${ver//./}"                   # 前缀 + 无点版本号，如 php84 / mysql84
}
get_volume_name() { echo "${PROJECT_NAME}_$(get_service_key "$1" "$2")_data"; }

# 转义 sed 替换文本中的特殊字符：/ 与 |（本项目 sed 替换表达式用的分隔符）、
# &（替换侧代表"整个匹配"，不转义会把原值拼进去）
escape_sed() {
  echo "$1" | sed -e 's/[\/&|]/\\&/g'
}

check_port() {
  local port=$1
  # command -v：判断某个命令是否可用（比 which 可靠）；&>/dev/null：stdout/stderr 全部丢弃，只关心退出码
  if command -v ss &>/dev/null; then
    # 冒号后必须紧跟空白：查 80 端口时才不会误匹配到 8080 的监听行
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
      lsof -i :"$port" -sTCP:LISTEN 2>/dev/null | tail -n +2   # tail -n +2：跳过输出的表头行
    else
      lsof -i :"$port" 2>/dev/null | tail -n +2
    fi
  elif command -v netstat &>/dev/null; then
    netstat -tlnp 2>/dev/null | awk "/:${port}[[:space:]]/"'{print $7}'
  else
    echo "无法获取进程信息（缺少 lsof/netstat）"
  fi
}

check_and_report_port() {
  local port=$1
  if ! check_port "$port"; then
    echo -e "${RED}端口 ${port} 已被占用，占用信息：${NC}" >&2
    show_port_owner "$port" >&2
    echo -e "${CYAN}请手动释放端口，或使用 '--port' 指定其他可用端口。${NC}" >&2
    return 1
  fi
  return 0
}

find_free_port() {
  local start=${1:-80}
  local p=$start
  while ! check_port "$p"; do
    p=$((p+1))
  done
  echo "$p"
}

get_or_set_port() {
  local svc=$1 ver=$2 default=$3
  local key; key=$(port_key "$svc" "$ver")   # 键名如 MYSQL_84_PORT；nginx 固定用 NGINX_PORT
  if [ "$svc" = "nginx" ]; then
    key="NGINX_PORT"
  fi

  # local 与赋值拆开写是刻意的：local 会吞掉命令替换的失败状态，合写会掩盖错误
  local val; val=$(read_env_value "$key" "")
  if [ -z "$val" ]; then
    val=$(find_free_port "$default")   # 从未记录过：自动挑空闲端口并写入 .env
    env_set "$key" "$val"
  else
    if ! check_port "$val"; then
      echo -e "${YELLOW}警告：已配置的端口 ${val} 被占用，正在寻找可用端口...${NC}" >&2
      local new_val; new_val=$(find_free_port "$default")
      log "将使用新端口 ${new_val}，并更新 .env"
      env_set "$key" "$new_val"
      val=$new_val
    fi
  fi
  echo "$val"
}

get_or_set_password() {
  local svc=$1 ver=$2
  # 键名形如 MYSQL_84_ROOT_PASSWORD（服务名_去点版本_ROOT_PASSWORD 转大写）
  local key; key=$(echo "${svc}_${ver//./}_ROOT_PASSWORD" | tr '[:lower:]' '[:upper:]')
  local val; val=$(read_env_value "$key" "")
  if [ -z "$val" ]; then
    command -v openssl &>/dev/null || error "需要 openssl 生成密码，请先安装 openssl"
    val=$(openssl rand -hex 8)
    env_set "$key" "$val"
    success "已生成 ${svc} ${ver} 密码，保存于 .env"
  fi
  echo "$val"
}

# 只读读取 .env 中的值（不产生写副作用），缺失时返回默认值。
# cut 用 -f2- ：值本身可能含 =（如自定义密码），不能在第二个 = 处截断
read_env_value() {
  local key=$1 default=$2
  local val=$(grep "^${key}=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || true)
  echo "${val:-$default}"
}

# 写/更新 .env 键值：已存在则整行替换，不存在则追加。
# 全项目唯一的 .env 写入口，保证格式一致、不产生重复键
env_set() {
  local key=$1 val=$2 escaped_key escaped_val
  escaped_key=$(escape_sed "$key")
  escaped_val=$(escape_sed "$val")
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed_i "s|^${escaped_key}=.*|${escaped_key}=${escaped_val}|" "$ENV_FILE"
  else
    echo "${key}=${val}" >> "$ENV_FILE"
  fi
}

run_compose() {
  local svc=$1 ver=$2; shift 2
  local service_file="$EXT_DIR/${svc}-${ver}.yml"
  if [ ! -f "$service_file" ]; then
    error "未找到服务 ${svc} ${ver} 的 Compose 配置文件"
  fi
  # 注意：不要使用 --remove-orphans——每个版本的服务文件只定义单个服务，
  # 该参数会把同 project 下所有其他服务（其他 PHP 版本/MySQL/Redis/Nginx）当作孤儿删除
  # 注意：Compose 把 yml 中相对路径按第一个 -f 文件所在目录解析，必须显式指定
  # --project-directory="$BASE_DIR"，service yml 中的挂载才能统一用 ./ 前缀
  docker compose -p "$PROJECT_NAME" --project-directory "$BASE_DIR" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -f "$service_file" "$@"
}

# 初始化服务配置：目录非空且含检查文件则跳过；否则清空重建并按服务类型生成
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
  log "初始化 $svc $ver 配置..."
  mkdir -p "$dir"

  case $svc in
    nginx) _init_nginx_config "$dir" "$ver" ;;
    php)   _init_php_config "$dir" "$ver" ;;
    mysql) _init_mysql_config "$dir" "$ver" ;;
  esac

  chown -R "$CURRENT_UID:$CURRENT_GID" "$dir" 2>/dev/null || true
  success "$svc $ver 配置就绪"
}

# 幂等地把站点目录 include 写进任意版本的 nginx.conf，保证"多站点共用一个 sites 目录"。
# 1) 先剔除历史注入行（任意缩进、任意 sites 路径写法），否则重复 include 会让每个站点的
#    server 块被加载两次，nginx -t 直接报 duplicate server name；
# 2) 再把唯一权威写法插到 http{} 内：紧跟 conf.d 的 include 之后（保留镜像自带 default
#    server 的优先语义），没有 conf.d 时退回紧跟 http{ ；
# 3) 幂等：对同一份配置反复执行结果不变，切换/重装 Nginx 版本不会累积脏行。
_nginx_inject_sites_include() {
  local conf=$1
  [ -f "$conf" ] || error "Nginx 主配置不存在: $conf"
  local stripped="$conf.pbox.tmp"

  # 清理范围限定在"路径中含 sites 目录"的 include（sites/、sites-enabled/、legacy-sites/…），
  # 不碰 mime.types、conf.d 等无关行；历史写法若不清干净，站点 server 块会被加载两次
  # grep 无匹配时返回 1，set -e 下必须 || true（结果为空文件也是合法的）
  grep -vE '^[[:space:]]*include[[:space:]]+[^;]*sites[^;]*\*\.conf;[[:space:]]*$' "$conf" > "$stripped" || true

  # awk 惯用法：命中锚点行后先原样打印、再追加 include，next 结束本行处理；
  # 末尾的 "1" 是恒真条件，对其余行执行默认动作（打印）——即逐行原样输出。
  # done 标志保证只注入一次（配置里可能出现多行 include）
  if grep -qE '^[[:space:]]*include[[:space:]]+/etc/nginx/conf\.d/[^;]*;' "$stripped"; then
    awk -v inc="    ${SITES_INCLUDE_LINE}" '
      /^[[:space:]]*include[[:space:]]+\/etc\/nginx\/conf\.d\/[^;]*;/ {
        print; if (!done) { print inc; done=1 } next
      }
      1
    ' "$stripped" > "$conf"
  else
    awk -v inc="    ${SITES_INCLUDE_LINE}" '
      /http[[:space:]]*{/ { print; if (!done) { print inc; done=1 } next }
      1
    ' "$stripped" > "$conf"
  fi
  rm -f "$stripped"

  grep -qF "${SITES_INCLUDE_LINE}" "$conf" || error "未能向 $(basename "$conf") 注入站点目录 include"
}

# 从指定版本的 nginx 镜像拷出默认配置，并注入站点目录 include
_init_nginx_config() {
  local dir=$1 ver=$2
  docker run --rm -v "$dir":/out "nginx:${ver}" \
    sh -c "cp -r /etc/nginx/conf.d /out/ && cp /etc/nginx/nginx.conf /out/" || {
    rm -rf "$dir"; error "Nginx 配置提取失败"
  }
  _nginx_inject_sites_include "$dir/nginx.conf"
}

# 从对应版本的 php 镜像拷出 php.ini-production 作为起点
_init_php_config() {
  local dir=$1 ver=$2
  docker run --rm -v "$dir":/out "php:${ver}-fpm-alpine" \
    sh -c "cp /usr/local/etc/php/php.ini-production /out/php.ini" || {
    rm -rf "$dir"; error "PHP 配置提取失败"
  }
}

# MySQL 镜像不带可拷贝的配置模板，按版本生成：
# 8.4 起旧的 default-authentication-plugin 写法已移除，改用 mysql_native_password=ON 启用旧认证插件
_init_mysql_config() {
  local dir=$1 ver=$2
  local mysql_major=$(echo "$ver" | cut -d. -f1)
  local mysql_minor=$(echo "$ver" | cut -d. -f2)
  if [[ "$mysql_major" -ge 8 && "$mysql_minor" -ge 4 ]] || [[ "$mysql_major" -gt 8 ]]; then
    cat > "$dir/my.cnf" <<'MYEOF'
[mysqld]
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
mysql_native_password=ON
MYEOF
  else
    cat > "$dir/my.cnf" <<'MYEOF'
[mysqld]
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
default-authentication-plugin=mysql_native_password
MYEOF
  fi
}

# 通用服务安装（仅用于 MySQL/Redis）
_generic_service_install() {
  local svc=$1 ver=$2 default_port=$3
  shift 3
  validate_version "$ver"
  if [ -f "$EXT_DIR/${svc}-${ver}.yml" ]; then
    error "${svc} ${ver} 已安装"
  fi

  local port=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port)
        [ $# -ge 2 ] || error "--port 需要指定端口号"
        port="${2}"
        shift 2 ;;
      *)
        error "未知选项: $1" ;;
    esac
  done

  if [ -n "$port" ]; then
    if ! check_and_report_port "$port"; then
      error "端口 $port 不可用"
    fi
    env_set "$(port_key "$svc" "$ver")" "$port"   # 用户显式指定的端口直接写入 .env
  else
    get_or_set_port "$svc" "$ver" "$default_port" > /dev/null
  fi

  init_config_files "$svc" "$ver"
  case "$svc" in
    mysql) _mysql_generate_compose "$ver"; _mysql_ensure_running "$ver" ;;
    redis) _redis_generate_compose "$ver"; _redis_ensure_running "$ver" ;;
  esac
  # up 之后端口已定（用户指定或自动挑选时均已写入 .env），只读不再复查：
  # 此时宿主机端口已被刚启动的容器自己监听，复查会被误判为"被占"而改写 .env、报错端口
  local final_port; final_port=$(read_env_value "$(port_key "$svc" "$ver")" "$default_port")
  success "${svc} ${ver} 安装完成，端口 ${final_port}"
}

# 通用端口修改（仅用于 MySQL/Redis）
_generic_db_port_set() {
  local svc=$1 ver=$2 new_port=$3 default_port=$4
  local key; key=$(port_key "$svc" "$ver")
  local old_port; old_port=$(read_env_value "$key" "")
  [ -z "$old_port" ] && error "${svc} ${ver} 未安装或端口未记录"

  if ! check_and_report_port "$new_port"; then
    error "端口 ${new_port} 不可用"
  fi

  # 流程：备份 .env → 写入新端口 → 重建容器 → 轮询验证 → 任一步失败则回滚 .env 并按旧端口重建
  local temp_env; temp_env=$(mktemp)
  cp "$ENV_FILE" "$temp_env"
  env_set "$key" "$new_port"

  local cname=$(get_container_name "$svc" "$ver")
  if ! run_compose "$svc" "$ver" up -d --force-recreate "$cname"; then
    cp "$temp_env" "$ENV_FILE"; rm -f "$temp_env"
    error "端口变更失败，已回滚"
  fi

  # 容器重建后服务需要数秒就绪（MySQL 尤其慢），轮询验证避免误判回滚
  local verify_timeout=30
  while [ "$verify_timeout" -gt 0 ]; do
    if verify_service "$svc" "$ver" "$new_port"; then
      rm -f "$temp_env"
      success "${svc} ${ver} 端口已改为 ${new_port}"
      return
    fi
    sleep 2
    verify_timeout=$((verify_timeout - 2))
  done

  cp "$temp_env" "$ENV_FILE" 2>/dev/null || true
  run_compose "$svc" "$ver" up -d --force-recreate "$cname" >/dev/null
  rm -f "$temp_env"
  error "新端口验证失败，已回滚"
}

# 本地健康探测：绕过任何代理、固定 IPv4、单次限时。否则会话里的代理变量、
# localhost 解析到 IPv6 或挂起的连接都会让轮询循环整体超时误判
# （且 curl -s 连错误信息都吞掉，失败时看不到任何线索）
http_probe_ok() {
  curl -s --noproxy '*' --max-time 3 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$1" | grep -qE '200|301|302|404'
}

verify_service() {
  local svc=$1 ver=$2 port=$3
  local cname=$(get_container_name "$svc" "$ver")
  case "$svc" in
    mysql)
      local pass=$(get_or_set_password "$svc" "$ver")
      docker exec -e MYSQL_PWD="$pass" "$cname" mysqladmin ping -h localhost -u root &>/dev/null
      ;;
    redis)
      docker exec "$cname" redis-cli ping | grep -q PONG
      ;;
    nginx)
      http_probe_ok "$port"
      ;;
    *) return 1 ;;
  esac
}

# 全局服务列表
cmd_list() {
  # docker --format 里要嵌 Shell 变量，用的是"关引号-插值-再开引号"拼接：
  # 单引号段是字面模板；中间 "'"${VAR}"'" 处引号临时关闭、插入变量值、再恢复单引号。
  # {{.Names}}/{{.Label}} 是 Go 模板占位符，\t 是制表符分列
  docker ps -a --filter "label=${PROJECT_NAME}${LABEL_SEPARATOR}service" --format \
    'table {{.Names}}\t{{.Label "'"${PROJECT_NAME}${LABEL_SEPARATOR}"'service"}}\t{{.Label "'"${PROJECT_NAME}${LABEL_SEPARATOR}"'version"}}\t{{.Ports}}\t{{.Status}}'
}
