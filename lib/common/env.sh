#!/bin/bash
# shellcheck shell=bash
# .env 读取侧与项目路径常量（搬运自 lib/common.sh，纯迁移无逻辑改动）

BASE_DIR="$HOME/phpbox"
COMPOSE_DIR="$BASE_DIR/compose"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
EXT_DIR="$COMPOSE_DIR/services"
CONFIG_DIR="$BASE_DIR/config"
PHP_CONFIG_DIR="$CONFIG_DIR/php"
LOG_DIR="$BASE_DIR/logs"
BACKUP_DIR="$BASE_DIR/backups"
LEGACY_STATE_DIR="$BASE_DIR/state"
ENV_FILE="$BASE_DIR/.env"

# 剥掉值两端成对包裹的单/双引号。.env 惯例允许带引号的值（含空格的 APK_MIRRORS 列表必需），
# 不剥则引号被并入值：load_env 侧首尾 URL 带上引号直接失效，read_env_value 侧端口变成 "8080"
_env_strip_quotes() {
  case "$1" in
    \"*\") echo "${1:1:${#1}-2}" ;;
    \'*\') echo "${1:1:${#1}-2}" ;;
    *)     echo "$1" ;;
  esac
}

# 解析并归一化 Alpine 镜像源列表（结果写入全局 APK_MIRRORS，空格分隔）。
# 合并语义：内置默认源（阿里云主源 + 官方 CDN）始终在前，.env 的 APK_MIRRORS 是
# "最终兜底"——默认源走不通（不可达/缺包）时按序接上，不替换默认链。
# 每个源归一化到以 /alpine 结尾（ICM 等镜像的路径前缀不同），重复源去重保留首个位置；
# 兼容旧变量 APK_MIRROR（并入兜底段）
_load_apk_mirrors() {
  local m normalized=""
  local list="https://mirrors.aliyun.com/alpine https://dl-cdn.alpinelinux.org/alpine"
  [ -n "${APK_MIRROR:-}" ] && list="$list $APK_MIRROR"
  list="$list ${APK_MIRRORS:-}"
  for m in $list; do
    case "$m" in */alpine) : ;; *) m="$m/alpine" ;; esac
    case " $normalized " in *" $m "*) continue ;; esac   # 去重：保留首个出现位置
    normalized="$normalized $m"
  done
  APK_MIRRORS=${normalized# }
}

# 逐行读取 .env 并导出为环境变量。IFS='=' 使 read 按等号拆分：key 取第一段，剩余全部
# 并入 value（密码含 = 也不会截断）。read 读到"无换行符的末行"时返回非零——循环体会
# 整行跳过，最后一行配置被静默丢弃（实测：末行的 APK_MIRRORS 丢失后回退默认镜像源），
# 故以 || [ -n "$key" ] 收编末行
_env_read_file() {
  [ -f "$ENV_FILE" ] || return 0
  while IFS='=' read -r key value || [ -n "$key" ]; do
    [[ "$key" =~ ^[[:space:]]*# ]] && continue   # 注释行（允许行首空白）：跳过
    [[ -z "$key" ]] && continue                  # 空行：跳过
    value="${value%$'\r'}"                       # 去掉行尾 \r，兼容 Windows 换行编辑过的 .env
    value=$(_env_strip_quotes "$value")          # 剥掉成对包裹的单/双引号
    export "$key"="$value"                       # 键名以字符串形式给出，逐行导出为环境变量
  done < "$ENV_FILE"
}

load_env() {
  _env_read_file

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
  # 站点目录与配置注入逻辑不随版本变化。
  # tag 会被拼进目录名、yml 与 docker 命令，必须白名单校验防注入（允许 alpine/1.30/1.30-alpine）
  NGINX_VERSION="${NGINX_VERSION:-alpine}"
  if ! [[ "$NGINX_VERSION" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
    error "无效的 NGINX_VERSION: $NGINX_VERSION（示例: alpine、1.30、1.30-alpine）"
  fi
  CURRENT_UID="${CURRENT_UID:-$(id -u)}"
  CURRENT_GID="${CURRENT_GID:-$(id -g)}"
  MYSQL_DATA_ROOT="${MYSQL_DATA_ROOT:-$HOME/mysql-data}"
  PGSQL_DATA_ROOT="${PGSQL_DATA_ROOT:-$HOME/pgsql-data}"
  # 离线备份库：pecl 源码包与 apk 依赖闭包的持久备份（按分类/PHP 版本分目录），
  # 命中即离线构建，换机随 phpbox backup 迁移
  OFFLINE_DIR="${OFFLINE_DIR:-$BASE_DIR/offline}"
  if [ "$OFFLINE_DIR" = "~" ]; then
    OFFLINE_DIR="$HOME"
  elif [ "${OFFLINE_DIR:0:2}" = "~/" ]; then
    OFFLINE_DIR="$HOME/${OFFLINE_DIR:2}"
  elif [ "${OFFLINE_DIR:0:2}" = "./" ]; then
    OFFLINE_DIR="$BASE_DIR/${OFFLINE_DIR:2}"
  elif [ "${OFFLINE_DIR:0:1}" != "/" ]; then
    OFFLINE_DIR="$BASE_DIR/$OFFLINE_DIR"
  fi
  # PHP 缺省安装的扩展集（php install 不带 --ext 时生效）。
  # curl/openssl/mbstring/pdo/sqlite3/xml/xmlwriter/xmlreader/simplexml/dom/fileinfo
  # 以及 sodium/pcntl/posix 等已编译进 php-fpm-alpine 镜像，无需也不能重复安装；
  # mongodb/memcached/sqlsrv/ldap 等低频扩展按需 extension add，不进默认集。
  # apcu 暂不进默认：pecl 对其最新版（5.1.28）依赖元数据缺失、固定版本（5.1.27）查询
  # 也失败，两条安装路径当前必败；上游恢复后用 extension add 装回并加回此列表
  PHP_DEFAULT_EXTENSIONS="${PHP_DEFAULT_EXTENSIONS:-gd,redis,pdo_mysql,mysqli,pgsql,pdo_pgsql,zip,bcmath,intl,opcache,exif,soap,sockets,imagick,xdebug}"
  # PHP 镜像构建的网络适配（镜像源列表解析见 _load_apk_mirrors）：
  BUILD_PROXY="${BUILD_PROXY:-auto}"
  GO_PROJECTS_ROOT="${GO_PROJECTS_ROOT:-$HOME/www}"
  GO_DEFAULT_VERSION="${GO_DEFAULT_VERSION:-alpine}"
  GO_DEFAULT_PORT="${GO_DEFAULT_PORT:-8080}"
  GO_PROXY="${GO_PROXY:-https://goproxy.cn,direct}"
  GO_CACHE_ROOT="${GO_CACHE_ROOT:-$BASE_DIR/cache/go}"
  GO_CGO_ENABLED="${GO_CGO_ENABLED:-0}"
  PGSQL_SERVICE_PREFIX="${PGSQL_SERVICE_PREFIX:-pg}"
  GO_SERVICE_PREFIX="${GO_SERVICE_PREFIX:-go}"
  for go_path_var in GO_PROJECTS_ROOT GO_CACHE_ROOT; do
    go_path_value="${!go_path_var}"
    if [ "$go_path_value" = "~" ]; then
      go_path_value="$HOME"
    elif [[ "$go_path_value" == "~/"* ]]; then
      go_path_value="$HOME/${go_path_value:2}"
    elif [[ "$go_path_value" == "./"* ]]; then
      go_path_value="$BASE_DIR/${go_path_value:2}"
    elif [[ "$go_path_value" != "/"* ]]; then
      go_path_value="$BASE_DIR/$go_path_value"
    fi
    printf -v "$go_path_var" '%s' "$go_path_value"
  done
  case "$GO_DEFAULT_VERSION" in
    alpine|latest) : ;;
    *) validate_version "$GO_DEFAULT_VERSION" ;;
  esac
  [[ "$GO_DEFAULT_PORT" =~ ^[1-9][0-9]{0,4}$ && "$GO_DEFAULT_PORT" -le 65535 ]] || error "无效的 GO_DEFAULT_PORT: $GO_DEFAULT_PORT"
  [[ "$GO_CGO_ENABLED" == 0 || "$GO_CGO_ENABLED" == 1 ]] || error "无效的 GO_CGO_ENABLED: $GO_CGO_ENABLED（应为 0 或 1）"
  # 镜像源网络超时秒数（正整数）：源测速、索引获取、下载"无响应"判定三处共用
  APK_TIMEOUT="${APK_TIMEOUT:-30}"
  if ! [[ "$APK_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    error "无效的 APK_TIMEOUT: $APK_TIMEOUT（应为正整数秒，示例: 30）"
  fi
  _load_apk_mirrors

  export PROJECT_NAME NETWORK_NAME WWW_ROOT IMAGE_PREFIX LABEL_SEPARATOR IMAGE_TAG_SEPARATOR BACKUP_NAME_SEPARATOR NGINX_PORT NGINX_VERSION CURRENT_UID CURRENT_GID MYSQL_DATA_ROOT PGSQL_DATA_ROOT PGSQL_SERVICE_PREFIX PHP_DEFAULT_EXTENSIONS APK_MIRROR APK_MIRRORS APK_TIMEOUT BUILD_PROXY OFFLINE_DIR GO_PROJECTS_ROOT GO_DEFAULT_VERSION GO_DEFAULT_PORT GO_PROXY GO_CACHE_ROOT GO_CGO_ENABLED GO_SERVICE_PREFIX
  # SITES_DIR 由 site.sh 定义；仅加载部分库时回退到默认站点目录，确保目录始终存在
    mkdir -p "$WWW_ROOT" "$COMPOSE_DIR" "$EXT_DIR" "$CONFIG_DIR" "$PHP_CONFIG_DIR" "$LOG_DIR" "$BACKUP_DIR" "$MYSQL_DATA_ROOT" "$GO_CACHE_ROOT" "${SITES_DIR:-$CONFIG_DIR/nginx/sites}"

    # 兼容旧版本：扩展清单曾位于顶层 state/，只在新文件不存在时迁移，绝不覆盖已有配置。
    local legacy_file legacy_name compact_version version target_file
    for legacy_file in "$LEGACY_STATE_DIR"/php-*-extensions.env; do
      [ -f "$legacy_file" ] || continue
      legacy_name=$(basename "$legacy_file")
      compact_version=${legacy_name#php-}
      compact_version=${compact_version%-extensions.env}
      if ! [[ "$compact_version" =~ ^[0-9]{2}$ ]]; then
        log "警告：无法自动迁移旧 PHP 扩展状态（版本格式不受支持，文件保留）: $legacy_file"
        continue
      fi
      version="${compact_version:0:1}.${compact_version:1:1}"
      target_file="$PHP_CONFIG_DIR/$version/extensions.env"
      if [ -e "$target_file" ]; then
        log "保留旧扩展状态（新文件已存在，未覆盖）: $legacy_file"
        continue
      fi
      mkdir -p "${target_file%/*}"
      if mv "$legacy_file" "$target_file"; then
        log "已迁移 PHP 扩展状态: $legacy_file -> $target_file"
      else
        error "PHP 扩展状态迁移失败，旧文件保持不变: $legacy_file"
      fi
    done
    rmdir "$LEGACY_STATE_DIR" 2>/dev/null || true

  # 主 compose 文件属于生成物（不入仓）：干净 clone 后首次执行任意命令时自愈生成。
  # 它只定义共享网络，具体服务由 compose/services/*.yml 分片提供
  if [ ! -f "$COMPOSE_FILE" ]; then
    printf 'networks:\n  net:\n    driver: bridge\n    name: ${NETWORK_NAME:-phpboxnet}\n' > "$COMPOSE_FILE"
  fi
}

# 只读读取 .env 中的值（不产生写副作用），缺失时返回默认值。
# cut 用 -f2- ：值本身可能含 =（如自定义密码），不能在第二个 = 处截断
read_env_value() {
  local key=$1 default=$2
  local val=$(grep "^${key}=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- || true)
  val=$(_env_strip_quotes "$val")
  echo "${val:-$default}"
}
