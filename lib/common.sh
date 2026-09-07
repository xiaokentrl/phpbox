#!/bin/bash
# shellcheck shell=bash

# 公共函数与变量定义
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

# 把镜像源域名按预解析 IP 输出为 --add-host 参数（两行：标志与值；解析失败输出空）。
# 容器内 DNS 对国内域名间歇性失败（DNS: transient error）且 apk 连接挂死无重试，跳过 DNS 可根治；
# /etc/hosts 在 buildkit 中只读，必须用 --add-host 而非 RUN echo
_apk_mirror_host_args() {
  local apk_mirror=$1
  local host="${apk_mirror#*://}"; host="${host%%/*}"
  local ip=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}' || true)
  if [ -n "$ip" ]; then echo "--add-host"; echo "$host:$ip"; fi
}

# 容器内 apk 下载器脚本（与 _apk_ranked_fetch_run、_load_apk_mirrors 同属 apk 源管理公共层）：
# 1) 用前测速：逐源下载 main 索引计时（APK_TIMEOUT 秒上限，超时/失败剔除），按最快优先排序；
# 2) 按测速顺序逐源整批下载：索引获取 APK_TIMEOUT 秒超时；下载期间以 /pkgs 增量 + 容器网卡
#    流量为进度双指标，APK_TIMEOUT 秒无增长 = 无响应，杀掉当前下载自动切换下一个源。
# 闭包必须出自同一源：切换源即清空 /pkgs 重来，避免两个源的版本混装。
# 单引号包裹：脚本的 $ 一律为容器运行时展开。调用:
#   sh -c "$_APK_FETCH_SCRIPT" <标签> recursive <包列表...>   # 递归闭包（预取）
#   sh -c "$_APK_FETCH_SCRIPT" <标签> installed               # 全量已装包（基础包同步）
_APK_FETCH_SCRIPT='
cp /etc/apk/repositories /tmp/repos.orig
MODE=$1; shift
APK_TIMEOUT="${APK_TIMEOUT:-30}"
VER="v$(cut -d. -f1,2 /etc/alpine-release 2>/dev/null)"
case "$VER" in
  v) VER=$(sed -n "s|^https://dl-cdn.alpinelinux.org/alpine/||p" /tmp/repos.orig | head -n1 | cut -d/ -f1) ;;
esac
ARCH=$(uname -m)
RANKED=""
echo "== 初始化 apk 下载器（模式: $MODE，架构: $ARCH，超时: ${APK_TIMEOUT}s）=="
echo "== 源测速（APKINDEX 下载耗时，${APK_TIMEOUT}s 上限）=="
for m in $APK_MIRRORS; do
  start=$(cut -d" " -f1 /proc/uptime)
  if timeout $APK_TIMEOUT wget -T $APK_TIMEOUT -q -O /dev/null "$m/$VER/main/$ARCH/APKINDEX.tar.gz" 2>/dev/null; then
    end=$(cut -d" " -f1 /proc/uptime)
    t=$(awk -v a="$end" -v b="$start" "BEGIN{printf \"%.2f\", a-b}")
    echo "  可用 $m  ${t}s"
    RANKED="$RANKED$t $m
"
  else
    echo "  不可用 $m（超时或失败，跳过）"
  fi
done
if [ -n "$RANKED" ]; then
  ORDER=$(printf "%s" "$RANKED" | sort -n | cut -d" " -f2-)
else
  echo "全部源测速失败，退回配置顺序尝试"
  ORDER="$APK_MIRRORS"
fi
n=0
total=$(printf "%s" "$ORDER" | grep -c .)
for m in $ORDER; do
  n=$((n+1))
  echo "== 尝试源 $n/$total: $m =="
  { echo "$m/$VER/main"; echo "$m/$VER/community"; } > /etc/apk/repositories
  # 索引获取：瞬时失败很常见（间歇性网络），重试 3 次；彻底失败仍不放弃该源——
  # 交给 fetch 解析检验（community 缺索引只影响 community 包，main 包照常解析）
  u=1
  while [ $u -le 3 ]; do
    echo "  获取 apk 索引（第 $u/3 次，最长 ${APK_TIMEOUT}s）..."
    if timeout $APK_TIMEOUT apk update >/dev/null 2>&1; then
      echo "  apk 索引获取完成"
      break
    fi
    u=$((u+1))
    [ $u -le 3 ] && { echo "  索引获取失败，重试 $u/3"; sleep 2; }
  done
  [ $u -gt 3 ] && echo "  警告：部分索引获取失败，仍尝试解析下载"
  # 清空仅在递归闭包模式下发生（换源即重来，闭包必须出自同一源）；
  # installed（基础包同步）是增量补充——曾因清空对两种模式都生效，把预取闭包删得只剩
  # 基础镜像自带包（41 个），离线构建 phpize 报 Cannot find autoconf
  case "$MODE" in
    recursive) rm -f /pkgs/*.apk 2>/dev/null; echo "  开始递归下载构建依赖（目标包: $#，输出目录: /pkgs）"; apk fetch --recursive -o /pkgs shadow curl $PHPIZE_DEPS "$@" & ;;
    installed) echo "  开始同步基础镜像已安装包（输出目录: /pkgs）"; apk fetch -o /pkgs $(apk info -q) & ;;
  esac
  apid=$!
  last="$(du -sk /pkgs 2>/dev/null | cut -f1) $(grep "^ *eth0:" /proc/net/dev | awk "{print \$2}")"
  stall=0
  dead=""
  started=$(cut -d" " -f1 /proc/uptime)
  while kill -0 $apid 2>/dev/null; do
    sleep 5
    cur="$(du -sk /pkgs 2>/dev/null | cut -f1) $(grep "^ *eth0:" /proc/net/dev | awk "{print \$2}")"
    now=$(cut -d" " -f1 /proc/uptime)
    elapsed=$(awk -v a="$now" -v b="$started" "BEGIN{printf \"%.0f\", a-b}")
    echo "  下载进行中：已耗时 ${elapsed}s，文件 ${cur%% *} KiB，网卡接收 ${cur##* } KiB"
    if [ "$cur" = "$last" ]; then
      stall=$((stall+5))
      [ $stall -ge $APK_TIMEOUT ] && { dead=1; break; }
    else
      stall=0; last="$cur"
    fi
  done
  if [ -n "$dead" ]; then
    kill $apid 2>/dev/null
    wait $apid 2>/dev/null
    echo "  ${APK_TIMEOUT} 秒无响应，停止并切换下一个源"
    continue
  fi
  if wait $apid; then
    # apk fetch 可能对"无法解析"静默返回 0 且零下载（实测：community 索引缺失时整单
    # 放弃仍退出 0）——按内容验收：phpize 工具链必须落地，缺失视作该源失败换下一个
    # （与宿主侧 _php_apk_closure_verify 同一套清单，双端把关）
    verify=1
    for t in autoconf gcc g++ make pkgconf re2c musl-dev linux-headers file dpkg; do
      ls /pkgs/$t-*.apk >/dev/null 2>&1 || { verify=0; break; }
    done
    if [ "$verify" = 1 ]; then
      count=$(find /pkgs -maxdepth 1 -name "*.apk" -type f 2>/dev/null | wc -l)
      size=$(du -sh /pkgs 2>/dev/null | cut -f1)
      echo "== 源 $m 下载完成（$count 个包，$size）=="
      OK=1
      break
    fi
    echo "  该源闭包不完整（缺构建工具），换下一个源"
    continue
  fi
  echo "  下载失败，换下一个源"
done
if [ "$OK" = 1 ]; then
  chown -R "$HOST_UID:$HOST_UID" /pkgs 2>/dev/null || true
  exit 0
fi
echo "全部源均失败"
exit 1
'

# 在 alpine 系容器内测速下载 apk 包（公共入口，预取/基础包同步等调用方只做薄封装）。
# 参数: $1=基础镜像(如 php:8.4-fpm-alpine)  $2=容器名（固定名：宿主侧 timeout 杀掉客户端
#       时容器会残留并挂住构建目录，按名强制清理，绝不留孤儿）
#       $3=宿主侧总超时秒  $4=模式(recursive|installed)  $5=包落地目录(挂到 /pkgs)
#       $6+=包列表（仅 recursive 模式）
# 返回: 任一源下载成功 → 0；全部失败 → 1（降级策略由调用方决定）
_apk_ranked_fetch_run() {
  local image=$1 cname=$2 host_timeout=$3 mode=$4 dest=$5
  shift 5
  local addhost=()
  mapfile -t addhost < <(_apk_mirror_host_args "${APK_MIRRORS%% *}")   # 主源 DNS 预解析
  docker rm -f "$cname" 2>/dev/null || true   # 上次残留的同名容器会让 run 直接失败，先清
  log "apk 下载器启动：镜像 $image，容器 $cname，宿主超时 ${host_timeout}s，模式 $mode"
  if ! timeout "$host_timeout" docker run --rm --name "$cname" "${addhost[@]}" \
      -e APK_MIRRORS="$APK_MIRRORS" -e APK_TIMEOUT="$APK_TIMEOUT" -e HOST_UID="${CURRENT_UID:-}" -v "$dest":/pkgs \
      "$image" sh -c "$_APK_FETCH_SCRIPT" phpbox-apk "$mode" "$@" >&2; then
    docker rm -f "$cname" 2>/dev/null || true
    return 1
  fi
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
  # 镜像源网络超时秒数（正整数）：源测速、索引获取、下载"无响应"判定三处共用
  APK_TIMEOUT="${APK_TIMEOUT:-30}"
  if ! [[ "$APK_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    error "无效的 APK_TIMEOUT: $APK_TIMEOUT（应为正整数秒，示例: 30）"
  fi
  _load_apk_mirrors

  export PROJECT_NAME NETWORK_NAME WWW_ROOT IMAGE_PREFIX LABEL_SEPARATOR IMAGE_TAG_SEPARATOR BACKUP_NAME_SEPARATOR NGINX_PORT NGINX_VERSION CURRENT_UID CURRENT_GID MYSQL_DATA_ROOT PHP_DEFAULT_EXTENSIONS APK_MIRROR APK_MIRRORS APK_TIMEOUT BUILD_PROXY OFFLINE_DIR
  # SITES_DIR 由 site.sh 定义；仅加载部分库时回退到默认站点目录，确保目录始终存在
    mkdir -p "$WWW_ROOT" "$COMPOSE_DIR" "$EXT_DIR" "$CONFIG_DIR" "$PHP_CONFIG_DIR" "$LOG_DIR" "$BACKUP_DIR" "$MYSQL_DATA_ROOT" "${SITES_DIR:-$CONFIG_DIR/nginx/sites}"

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

# Docker daemon 预检：所有需要与 daemon 交互的变更类命令必须先过这一关。
# 否则 daemon 未运行时，错误会以"配置验证失败/启动超时"等无关面目出现，极难排查；
# 更糟的是 nginx install 这类流程会先删旧实例、写 yml，失败后留下半安装状态
require_docker() {
  command -v docker &>/dev/null || error "未找到 docker 命令，请先安装 Docker"
  if ! docker info &>/dev/null; then
    error "Docker daemon 未运行（无法连接 docker API）。请先启动后重试：
  Linux:  sudo systemctl start docker
  其他:   service docker start / 打开 Docker Desktop"
  fi
}

# 停止并移除单个服务容器。不能借 compose down 卸载单个服务：down 会连带删除基础
# compose 文件里定义的共享网络——当其余服务的容器恰好都处于停止/崩溃状态时，网络因
# 无 endpoint 而被成功删除，之后所有引用旧网络的已停止容器 docker start 一律报
# "network not found"（重启宿主机也拉不起来），只能逐个 force-recreate 才能恢复。
# 先 docker stop 走优雅停机（MySQL 的 entrypoint 会清理 socket 并干净关库），
# docker rm -f 兜底删除已退出或不存在的容器
stop_and_remove_container() {
  local cname=$1
  docker stop "$cname" &>/dev/null || true
  docker rm -f "$cname" &>/dev/null || true
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
  local val=$(grep "^${key}=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- || true)
  val=$(_env_strip_quotes "$val")
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

# 从 .env 删除键（半安装回滚用）；键不存在时静默。键名仅含字母数字下划线，可安全拼进 sed
env_unset() {
  sed_i "/^${1}=/d" "$ENV_FILE" 2>/dev/null || true
}

# ---- 半安装回滚 ----
# 删除可能已被容器内用户（如 mysql 的 999）接管的目录：宿主 rm 会因权限失败，
# 借容器内 root 兜底（与属主 chown 兜底同一思路）。回滚/卸载清理专用，失败不抛出
_rm_rf_with_docker_fallback() {
  local dir=$1
  rm -rf "$dir" 2>/dev/null && return 0
  [ -d "$dir" ] || return 0   # rm 虽报错但目标已不存在，视为成功
  docker run --rm -v "${dir%/*}":/parent alpine rm -rf "/parent/${dir##*/}" >/dev/null 2>&1 || true
}

# 安装类命令：_install_rollback_begin → 写配置/起容器 → 成功 _install_rollback_commit。
# 中途任何一步 error() 退出都会触发 EXIT trap，由 _install_rollback_run 清掉"本次新增"的
# yml/配置目录/数据目录/扩展状态文件与 .env 键——只清理本次新增的（先快照存在性），不碰历史残留
_ROLLBACK_PENDING=false
_ROLLBACK_SVC="" ; _ROLLBACK_VER=""
_ROLLBACK_CONFIG_EXISTED=false ; _ROLLBACK_DATA_EXISTED=false ; _ROLLBACK_STATE_EXISTED=false
_ROLLBACK_PORT_EXISTED=false ; _ROLLBACK_PASS_EXISTED=false

_install_rollback_begin() {
  local svc=$1 ver=$2 key
  _ROLLBACK_PENDING=true ; _ROLLBACK_SVC=$svc ; _ROLLBACK_VER=$ver
  if [ -d "$CONFIG_DIR/$svc/$ver" ]; then _ROLLBACK_CONFIG_EXISTED=true; fi
  if [ -d "$MYSQL_DATA_ROOT/$ver" ]; then _ROLLBACK_DATA_EXISTED=true; fi
  if [ -f "$PHP_CONFIG_DIR/$ver/extensions.env" ]; then _ROLLBACK_STATE_EXISTED=true; fi
  key=$(port_key "$svc" "$ver")
  if [ -n "$(read_env_value "$key" "")" ]; then _ROLLBACK_PORT_EXISTED=true; fi
  key="${svc^^}_${ver//./}_ROOT_PASSWORD"
  if [ -n "$(read_env_value "$key" "")" ]; then _ROLLBACK_PASS_EXISTED=true; fi
}

_install_rollback_commit() { _ROLLBACK_PENDING=false; }

_install_rollback_run() {
  $_ROLLBACK_PENDING || return 0
  local svc=$_ROLLBACK_SVC ver=$_ROLLBACK_VER key
  log "安装失败，自动清理 ${svc} ${ver} 的半安装状态..."
  rm -f "$EXT_DIR/${svc}-${ver}.yml"
  if ! $_ROLLBACK_CONFIG_EXISTED; then rm -rf "$CONFIG_DIR/$svc/$ver"; fi
  case "$svc" in
    mysql)
      if ! $_ROLLBACK_DATA_EXISTED; then _rm_rf_with_docker_fallback "$MYSQL_DATA_ROOT/$ver"; fi ;;
    redis)
      docker volume rm -f "$(get_volume_name redis "$ver")" &>/dev/null || true ;;
    php)
      if ! $_ROLLBACK_STATE_EXISTED; then rm -f "$PHP_CONFIG_DIR/$ver/extensions.env"; fi
      _php_cleanup_images "$ver" ;;
  esac
  if ! $_ROLLBACK_PORT_EXISTED; then
    key=$(port_key "$svc" "$ver"); env_unset "$key"
  fi
  if ! $_ROLLBACK_PASS_EXISTED; then
    env_unset "${svc^^}_${ver//./}_ROOT_PASSWORD"
  fi
  _ROLLBACK_PENDING=false
}
trap '_install_rollback_run' EXIT

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

# 各服务的配置模板生成器（_init_nginx/php/mysql_config）已归位各服务模块，
# init_config_files 统一分发调用。nginx 的站点挂载常量 SITES_* 亦随迁 nginx.sh
_generic_service_install() {
  local svc=$1 ver=$2 default_port=$3
  shift 3
  validate_version "$ver"
  # 版本线守门：官方镜像没有的大版本直接拒绝（MySQL 5.7 之后没有 6.x/7.x）。
  # 不拦的话要走到拉取阶段才报一句 "denied"，前面的配置/属主设置全白做
  case "$svc" in
    mysql) [[ "$ver" == 5.* || "$ver" == 8.* || "$ver" == 9.* ]] || error "MySQL 不存在 ${ver%%.*}.x 版本（5.7 之后直接是 8.0），可用版本线: 5.7 / 8.0 / 8.4 / 9.x" ;;
    redis) [[ "$ver" == [4-9].* ]] || error "Redis 可用版本线: 4.x / 5.x / 6.x / 7.x / 8.x" ;;
  esac
  if [ -f "$EXT_DIR/${svc}-${ver}.yml" ]; then
    error "${svc} ${ver} 已安装"
  fi
  _install_rollback_begin "$svc" "$ver"

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

  require_docker

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
  _install_rollback_commit
  success "${svc} ${ver} 安装完成，端口 ${final_port}"
}

# 通用端口修改（仅用于 MySQL/Redis）
_generic_db_port_set() {
  local svc=$1 ver=$2 new_port=$3 default_port=$4
  local key; key=$(port_key "$svc" "$ver")
  local old_port; old_port=$(read_env_value "$key" "")
  [ -z "$old_port" ] && error "${svc} ${ver} 未安装或端口未记录"

  require_docker

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
