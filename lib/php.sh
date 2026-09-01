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
    # 白名单字符集：扩展名会被拼进镜像 tag 和 Dockerfile，禁止空格/分号等注入字符
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

  # heredoc 内两处特殊展开：
  #   ${exts//,/ }  生成时展开：gd,redis → "gd redis"（逗号换空格，变成多个参数）
  #   \${UID}       写入字面量 ${UID}，真正取值发生在 docker build 时（ARG）
  cat > "$build_dir/Dockerfile" <<DEOF
FROM php:${ver}-fpm-alpine
ARG UID=1000
ARG GID=1000
RUN apk add --no-cache shadow curl
COPY --from=mlocati/php-extension-installer:2 /usr/bin/install-php-extensions /usr/local/bin/
RUN if [ -n "$exts" ]; then install-php-extensions ${exts//,/ }; fi
RUN usermod -u \${UID} www-data && groupmod -g \${GID} www-data
DEOF

  log "构建 PHP ${ver} 自定义镜像（扩展: ${exts:-无}）..."
  docker build -t "$img" \
    --build-arg UID="$CURRENT_UID" \
    --build-arg GID="$CURRENT_GID" \
    "$build_dir" || error "PHP 镜像构建失败"

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
  local image="$(_php_build_image "$ver" "$exts")"

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
  run_compose "php" "$ver" down 2>/dev/null || true
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
