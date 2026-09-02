#!/bin/bash
# shellcheck shell=bash

_redis_generate_compose() {
  local ver=$1
  local svc_key=$(get_service_key "redis" "$ver")
  local cname=$(get_container_name "redis" "$ver")
  local vol_name=$(get_volume_name "redis" "$ver")
  local port=$(get_or_set_port "redis" "$ver" "6379")
  local yml="$EXT_DIR/redis-${ver}.yml"

  cat > "$yml" <<YEOF
volumes:
  $vol_name:
    # 显式指定 name，否则 Compose 会加项目名前缀（实际卷名变成 ${PROJECT_NAME}_${vol_name}），
    # 导致 uninstall --purge 用 get_volume_name 的名字删不掉卷
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
  local svc_key=$(get_service_key "redis" "$ver")
  run_compose "redis" "$ver" up -d "$svc_key"
  local cname=$(get_container_name "redis" "$ver")
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

_redis_install() {
  local ver="${1:-}"
  [ -z "$ver" ] && error "用法: phpbox redis install <版本> [--port 端口]"
  shift
  _generic_service_install "redis" "$ver" "6379" "$@"
}

_redis_port_set() {
  local sub="${1:-}"
  local ver="${2:-}"
  local new_port="${3:-}"
  [ "$sub" != "set" ] && error "用法: phpbox redis port set <版本> <新端口>"
  [ -z "$ver" ] && error "请指定版本"
  [ -z "$new_port" ] && error "请指定新端口"
  validate_version "$ver"
  _generic_db_port_set "redis" "$ver" "$new_port" "6379"
}

_redis_show_list() {
  echo "已安装 Redis 版本:"
  for f in "$EXT_DIR"/redis-*.yml; do
    [ -f "$f" ] || continue   # glob 无匹配时保持字面串，靠 -f 过滤掉
    local ver=$(basename "$f" .yml | sed 's/redis-//')
    local cname=$(get_container_name "redis" "$ver")
    local status=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo "不存在")
    local port=$(read_env_value "REDIS_${ver//./}_PORT" "6379")
    printf "  %s  %s  (端口: %s)\n" "$ver" "$status" "$port"
  done
}

# --purge 的数据卷/配置删除确认（非终端环境保留并提示）
_redis_purge() {
  local ver=$1
  local vol_name=$(get_volume_name "redis" "$ver")
  if confirm_yes "确认删除数据卷 ${vol_name} 吗？"; then
    docker volume rm -f "$vol_name" 2>/dev/null || true
  elif ! [[ -t 0 ]]; then
    log "非交互模式，保留数据卷"
  fi
  if confirm_yes "是否删除配置目录 $CONFIG_DIR/redis/$ver ?"; then
    rm -rf "$CONFIG_DIR/redis/$ver"
  fi
}

_redis_uninstall() {
  local ver="${1:-}"
  local purge=false
  [ -z "$ver" ] && error "用法: phpbox redis uninstall <版本> [--purge]"
  shift
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
  stop_and_remove_container "$(get_container_name "redis" "$ver")"
  if $purge; then
    _redis_purge "$ver"
  else
    log "配置和数据卷已保留"
  fi
  rm -f "$EXT_DIR/redis-${ver}.yml"
  success "Redis ${ver} 已卸载"
}

# 仅做分发，实现见各 _redis_* 函数
cmd_redis() {
  case "${1:-help}" in
    install)   shift; _redis_install "$@" ;;
    port)      _redis_port_set "${2:-}" "${3:-}" ;;
    list)      _redis_show_list ;;
    uninstall) shift; _redis_uninstall "$@" ;;
    *) error "未知 redis 操作: ${1:-help} (支持 install, port, list, uninstall)" ;;
  esac
}
