#!/bin/bash
# shellcheck shell=bash
# Redis 安装/卸载/启动/清单生命周期（搬运自 lib/redis.sh，纯迁移无逻辑改动）

# Redis 官方稳定主版本 tag：redis:8-alpine 会跟随 Redis 8 稳定版补丁发布。
_REDIS_DEFAULT_VERSION=8

_redis_ensure_running() {
  local ver=$1
  local svc_key=$(get_service_key "redis" "$ver")
  run_compose "redis" "$ver" up -d "$svc_key"
  local cname=$(get_container_name "redis" "$ver")
  local password_key="REDIS_${ver//./}_ROOT_PASSWORD"
  local password; password=$(read_env_value "$password_key" "")
  local timeout=20
  while [ $timeout -gt 0 ]; do
    if docker exec "$cname" redis-cli -a "$password" --no-auth-warning ping | grep -q PONG; then
      return 0
    fi
    sleep 2
    timeout=$((timeout - 2))
  done
  error "Redis ${ver} 启动或 PING 验证失败"
}

_redis_install() {
  local ver="$_REDIS_DEFAULT_VERSION"
  if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
    ver=$1
    shift
  fi
  # 镜像获取走离线事务（offline/redis/<版本>/ 命中则零网络），
  # 必须在 _generic_service_install 之前：容器启动依赖镜像已在本地
  _redis_ensure_image "$ver" "install"
  _generic_service_install "redis" "$ver" "6379" "$@"
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
