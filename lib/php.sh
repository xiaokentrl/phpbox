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
    # 清洗流水线：去注释行 → 去空行 → 去掉 "KEY=" 前缀 → 再去空行 →
    # 按逗号拆行排序去重 → 重新拼回逗号串（最终输出形如 gd,redis）
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
  local IFS=,   # 把分词符设为逗号：下面的 for 直接按逗号逐项遍历 $exts
  for ext in $exts; do
    # 白名单字符集：扩展名会被拼进 Dockerfile，禁止空格/分号等注入字符。
    # 允许点号：install-php-extensions 的版本钉住语法（如 apcu-5.1.27）需要
    if ! [[ "$ext" =~ ^[a-zA-Z0-9._-]+$ ]]; then
      error "无效扩展名: $ext"
    fi
  done
}

# 探测构建可用的 HTTP 代理。背景：网络受限环境下 pecl.php.net 的 IPv4 被间歇性重置
# （宿主机可能仅 IPv6 可达），而构建容器没有 IPv6 出口，也无法直达宿主 loopback 上的
# 本地代理。关键教训：直连"单次探测通过"不代表构建期间稳定——一次构建会发起大量
# 连接，任一被重置即失败。因此探测策略是代理优先：本地存在能通 pecl 的代理就走代理，
# 只有探测不到代理时才直连（构建失败时由报错信息引导配置 BUILD_PROXY）。
# 输出：代理 URL（stdout）；未探测到输出空串（走直连）
_php_detect_build_proxy() {
  command -v curl &>/dev/null || return 0
  local port attempt
  for port in 10809 7890 8118 1087 1080 8888; do
    # -f：代理返回 4xx/5xx 也视为不可用（如仅 SOCKS 的端口对 HTTP 代理请求会报 400）；
    # 每端口重试一次：探测连接可能与代理上残留的连接竞争而瞬断，单次失败不足以判死
    for attempt in 1 2; do
      if curl -4 -s -f --connect-timeout 3 --max-time 6 -x "http://127.0.0.1:$port" -o /dev/null https://pecl.php.net/channel.xml 2>/dev/null; then
        echo "http://127.0.0.1:$port"
        return 0
      fi
    done
  done
  return 0
}

# 渲染 Dockerfile（独立成函数便于测试断言）。heredoc 内的 $ 分工：
#   $exts / ${exts//,/ }   生成时展开：扩展列表逗号换空格变成多个参数
#   \$APK_MIRROR / \$http_proxy  写入字面量，真正取值发生在 docker build 时（ARG）
#   \${UID}            写入字面量 ${UID}，同上
_php_render_dockerfile() {
  local ver=$1 exts=$2
  cat <<DEOF
FROM php:${ver}-fpm-alpine
ARG UID=1000
ARG GID=1000
# APK_MIRROR：替换 Alpine 官方 CDN（国内网络对其极不稳定），如 https://mirrors.aliyun.com
ARG APK_MIRROR=
RUN if [ -n "\$APK_MIRROR" ]; then sed -i "s|https://dl-cdn.alpinelinux.org|\$APK_MIRROR|g; s|http://dl-cdn.alpinelinux.org|\$APK_MIRROR|g" /etc/apk/repositories; fi
RUN apk add --no-cache shadow curl
COPY --from=mlocati/php-extension-installer:2 /usr/bin/install-php-extensions /usr/local/bin/
# http_proxy 是 Docker 预定义 build arg（自动注入每个 RUN 的环境）；但 PEAR 的下载器
# 只认自己的代理配置而不读环境变量，须显式写入，否则 pecl 源码包下载仍走直连
ARG http_proxy=
RUN if [ -n "\$http_proxy" ]; then pear config-set http_proxy "\$http_proxy" 2>/dev/null || true; fi
# 重试一次兜底：受限网络下连接被重置是随机的，IPE 幂等可安全重跑（已装扩展会跳过）
RUN if [ -n "$exts" ]; then install-php-extensions ${exts//,/ } || install-php-extensions ${exts//,/ }; fi
RUN usermod -u \${UID} www-data && groupmod -g \${GID} www-data
DEOF
}

_php_build_image() {
  local ver=$1 exts=$2
  local img="${IMAGE_PREFIX}php${ver//./}"
  local build_dir="$CONFIG_DIR/php/$ver"
  mkdir -p "$build_dir"
  _php_render_dockerfile "$ver" "$exts" > "$build_dir/Dockerfile"

  # BUILD_PROXY：none=禁用；auto（默认）=探测；其余按显式值（host:port 或完整 URL）
  local proxy="${BUILD_PROXY:-auto}"
  if [ "$proxy" = "auto" ]; then
    proxy=$(_php_detect_build_proxy)
  fi

  local apk_mirror="${APK_MIRROR:-}"
  local build_args=()
  if [ -n "$proxy" ] && [ "$proxy" != "none" ]; then
    case "$proxy" in
      http://*|https://*) : ;;
      *) proxy="http://${proxy}" ;;
    esac
    # 构建容器无法访问宿主 loopback：代理指向本机时改写为 host.docker.internal
    proxy="${proxy//127.0.0.1/host.docker.internal}"
    proxy="${proxy//localhost/host.docker.internal}"
    # 代理在途时 Alpine 官方 CDN 通常同样不通（Fastly 源经代理常被重置），
    # 未显式配置镜像源则回退国内源（阿里源经代理实测可达）
    if [ -z "$apk_mirror" ]; then
      apk_mirror="https://mirrors.aliyun.com"
    fi
    log "检测到可用本地代理，构建流量经代理: ${proxy}"
  fi

  # 镜像源配置后做两件事：
  # 1) --add-host 注入预解析 IP：容器内 Docker Desktop 的内嵌 DNS 对国内域名间歇性
  #    解析失败（报 DNS: transient error），且 apk 连接挂死后无超时重试会让构建卡死；
  #    跳过 DNS 可根治（注意 /etc/hosts 在 buildkit 中只读，必须用 --add-host 而非 RUN echo）
  # 2) 代理路径下把镜像源域名加入 no_proxy：apk 直连国内源（大体积依赖包经代理
  #    会慢到挂死）；仅小体积的 pecl 源码包走代理
  local apk_mirror_host="" apk_mirror_ip=""
  if [ -n "$apk_mirror" ]; then
    apk_mirror_host="${apk_mirror#*://}"; apk_mirror_host="${apk_mirror_host%%/*}"
    apk_mirror_ip=$(getent ahostsv4 "$apk_mirror_host" 2>/dev/null | awk '{print $1; exit}' || true)
    [ -n "$apk_mirror_ip" ] && build_args+=(--add-host "${apk_mirror_host}:${apk_mirror_ip}")
  fi

  if [ -n "$proxy" ] && [ "$proxy" != "none" ]; then
    build_args+=(--build-arg http_proxy="$proxy" --build-arg https_proxy="$proxy" \
                 --build-arg no_proxy="127.0.0.1,localhost${apk_mirror_host:+,$apk_mirror_host}")
  fi

  log "构建 PHP ${ver} 自定义镜像（扩展: ${exts:-无}）..."
  docker build -t "$img" \
    --build-arg UID="$CURRENT_UID" \
    --build-arg GID="$CURRENT_GID" \
    --build-arg APK_MIRROR="$apk_mirror" \
    "${build_args[@]}" \
    "$build_dir" || error "PHP 镜像构建失败（网络受限时可在 .env 配置 BUILD_PROXY 指向本地 HTTP 代理）"

  echo "$img"
}

_php_ensure_running() {
  local ver=$1
  local svc_key=$(get_service_key "php" "$ver")
  local yml="$EXT_DIR/php-${ver}.yml"
  if [ ! -f "$yml" ]; then
    _php_generate_compose "$ver"
  fi
  run_compose "php" "$ver" up -d "$svc_key"
  local cname=$(get_container_name "php" "$ver")
  local timeout=30
  while [ $timeout -gt 0 ]; do
    if docker exec "$cname" php-fpm -t &>/dev/null; then
      # 容器可能被重建（如 extension add/remove），刷新 nginx 的 upstream 连接
      nginx_try_reload
      return 0
    fi
    sleep 2
    timeout=$((timeout - 2))
  done
  error "PHP ${ver} 启动超时"
}

_php_generate_compose() {
  local ver=$1
  local svc_key=$(get_service_key "php" "$ver")
  local yml="$EXT_DIR/php-${ver}.yml"
  local exts="$(_php_read_extensions "$ver")"
  # local 与赋值拆开是刻意的：local 会吞掉命令替换的失败状态——镜像构建失败时必须
  # 让 set -e 在写 yml 之前中止，否则会生成 image 为空的坏 yml（compose 报 "image must be a string"）
  local image
  image="$(_php_build_image "$ver" "$exts")"

  # yml 里两种 $ 的分工：
  #   \${WWW_ROOT}   保留字面量，由 compose 运行时从 .env 解析（改 .env 即生效，无需重新生成）
  #   ./config/...   相对路径以 run_compose 传入的 --project-directory（即 BASE_DIR）为基准
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
  local cname=$(get_container_name "php" "$ver")
  docker rm -f "$cname" 2>/dev/null || true
  local pattern="${IMAGE_PREFIX}php${ver//./}"
  # xargs -r：镜像 ID 列表为空时不执行后面的 rmi（否则 docker rmi 缺参数报错）
  docker images --filter "reference=${pattern}" -q 2>/dev/null | xargs -r docker rmi -f 2>/dev/null || true
}

_php_install() {
  local ver="${1:-}"
  [ -z "$ver" ] && error "用法: phpbox php install <版本> [--extensions 扩展列表]"
  validate_version "$ver"
  shift

  local exts=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --extensions)
        [ $# -ge 2 ] || error "--extensions 需要指定扩展列表"
        exts="$2"; shift 2 ;;
      *) error "未知选项: $1" ;;
    esac
  done

  require_docker

  if [ -f "$EXT_DIR/php-${ver}.yml" ]; then
    error "PHP ${ver} 已安装，如需修改扩展请使用 'phpbox php extension add/remove'"
  fi
  # 未指定 --extensions 时采用默认扩展集（.env 的 PHP_DEFAULT_EXTENSIONS 可覆盖）
  if [ -z "$exts" ]; then
    exts="$PHP_DEFAULT_EXTENSIONS"
  fi
  if [ -n "$exts" ]; then
    _php_validate_extensions "$exts"
    _php_write_extensions "$ver" "$exts"
  fi
  init_config_files "php" "$ver"
  _php_generate_compose "$ver"
  _php_ensure_running "$ver"
  success "PHP ${ver} 安装完成"
}

_php_extension_op() {
  local sub="${1:-}"
  local ver="${2:-}"
  local ext="${3:-}"
  [ -z "$sub" ] && error "用法: phpbox php extension {add|remove} <版本> <扩展名>"
  [ -z "$ver" ] && error "请指定 PHP 版本"
  [ -z "$ext" ] && error "请指定扩展名"
  validate_version "$ver"
  _php_validate_extensions "$ext"

  # 幂等短路在前：已存在/不存在的扩展直接返回，不需要 daemon
  local current="$(_php_read_extensions "$ver")"
  local new_exts=""
  if [ "$sub" = "add" ]; then
    # 两端补逗号做整项匹配：查 "gd" 才不会误命中 "xgdx"
    if [[ ",$current," == *",$ext,"* ]]; then
      log "扩展 $ext 已存在"
      return
    fi
    new_exts="${current:+$current,}$ext"   # ${var:+x}：current 非空时展开为 "current内容,"，空则不加逗号
  elif [ "$sub" = "remove" ]; then
    # 同上整项匹配，此处 != 表示"列表里不存在该项"
    if [[ ",$current," != *",$ext,"* ]]; then
      log "扩展 $ext 不存在"
      return
    fi
    new_exts=$(echo "$current" | tr ',' '\n' | grep -v "^$ext$" | tr '\n' ',' | sed 's/,$//')
  else
    error "未知扩展操作: $sub (支持 add/remove)"
  fi

  require_docker

  _php_cleanup_images "$ver"
  rm -f "$EXT_DIR/php-${ver}.yml"
  _php_write_extensions "$ver" "$new_exts"
  _php_generate_compose "$ver"
  _php_ensure_running "$ver"
  success "PHP ${ver} 扩展已更新（${sub}: $ext）"
}

_php_show_list() {
  echo "已安装 PHP 版本:"
  for f in "$EXT_DIR"/php-*.yml; do
    [ -f "$f" ] || continue   # glob 无匹配时保持字面串，靠 -f 过滤掉
    local ver=$(basename "$f" .yml | sed 's/php-//')
    local cname=$(get_container_name "php" "$ver")
    local status=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo "不存在")
    local exts="$(_php_read_extensions "$ver")"
    printf "  %s  %s  (扩展: %s)\n" "$ver" "$status" "${exts:-无}"
  done
}

_php_uninstall() {
  local ver="${1:-}"
  local purge=false
  [ -z "$ver" ] && error "用法: phpbox php uninstall <版本> [--purge]"
  shift
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
  stop_and_remove_container "$(get_container_name "php" "$ver")"
  _php_cleanup_images "$ver"
  rm -f "$EXT_DIR/php-${ver}.yml"
  rm -f "$(_php_get_extensions_file "$ver")"
  if $purge && confirm_yes "是否删除配置目录 $CONFIG_DIR/php/$ver ?"; then
    rm -rf "$CONFIG_DIR/php/$ver"
  fi
  success "PHP ${ver} 已卸载"
}

# 仅做分发，实现见各 _php_* 函数
cmd_php() {
  case "${1:-help}" in
    install)   shift; _php_install "$@" ;;
    extension) shift; _php_extension_op "$@" ;;
    list)      _php_show_list ;;
    uninstall) shift; _php_uninstall "$@" ;;
    *) error "未知 php 操作: ${1:-help} (支持 install, extension, list, uninstall)" ;;
  esac
}
