#!/bin/bash
# shellcheck shell=bash
# PHP 安装/卸载/启动/清单生命周期（搬运自 lib/php.sh，纯迁移无逻辑改动）

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
  [ -z "$ver" ] && error "用法: phpbox php install <版本> [--ext 扩展列表]"
  validate_version "$ver"
  # 版本线守门：php:X-fpm-alpine 官方镜像只发布过 5.x / 7.x / 8.x
  [[ "$ver" == 5.* || "$ver" == 7.* || "$ver" == 8.* ]] || error "PHP 不存在 ${ver%%.*}.x 版本，可用版本线: 5.6 / 7.x / 8.x"
  shift

  local exts=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ext|--extensions)
        [ $# -ge 2 ] || error "--ext 需要指定扩展列表"
        exts="$2"; shift 2 ;;
      *) error "未知选项: $1" ;;
    esac
  done

  require_docker

  if [ -f "$EXT_DIR/php-${ver}.yml" ]; then
    error "PHP ${ver} 已安装，如需修改扩展请使用 'phpbox php extension add/remove'"
  fi
  _install_rollback_begin "php" "$ver"
  # 未指定 --ext 时采用默认扩展集（.env 的 PHP_DEFAULT_EXTENSIONS 可覆盖）
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
  _install_rollback_commit
  success "PHP ${ver} 安装完成"
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
