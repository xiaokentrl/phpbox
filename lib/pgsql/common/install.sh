#!/bin/bash
# shellcheck shell=bash
# PostgreSQL 安装/卸载/启动/清单生命周期

_pgsql_ensure_running() {
  local ver=$1
  local svc_key=$(get_service_key "pgsql" "$ver")
  run_compose "pgsql" "$ver" up -d "$svc_key"
  local cname=$(get_container_name "pgsql" "$ver")
  # 首次启动要跑 initdb（建系统目录、生成初始库），比 mysql 的空库启动慢，
  # 轮询放宽到 60s；pg_isready 对 unix socket 探测，无需密码
  local timeout=60
  while [ $timeout -gt 0 ]; do
    if docker exec "$cname" pg_isready -U postgres &>/dev/null; then
      return 0
    fi
    sleep 2
    timeout=$((timeout - 2))
  done
  error "PostgreSQL ${ver} 启动超时"
}

_pgsql_install() {
  local ver="${1:-}"
  [ -z "$ver" ] && error "用法: phpbox pgsql install <版本> [--port 端口]"
  shift
  # 镜像获取走离线事务（offline/pgsql/<版本>/ 命中则零网络），
  # 必须在 _generic_service_install 之前：容器启动依赖镜像已在本地
  _pgsql_ensure_image "$ver" "install" >/dev/null
  _generic_service_install "pgsql" "$ver" "5432" "$@"
  # 本地开发场景：安装完成直接亮出密码，免翻 .env。
  # 自定义密码：安装前在 .env 预设 PGSQL_<去点版本>_ROOT_PASSWORD，留空则自动生成
  local pass; pass=$(get_or_set_password "pgsql" "$ver")
  log "PostgreSQL ${ver} 密码: ${pass}（已保存于 .env 的 PGSQL_${ver//./}_ROOT_PASSWORD）"
}

_pgsql_show_list() {
  echo "已安装 PostgreSQL 版本:"
  for f in "$EXT_DIR"/pgsql-*.yml; do
    [ -f "$f" ] || continue   # glob 无匹配时保持字面串，靠 -f 过滤掉
    local ver=$(basename "$f" .yml | sed 's/pgsql-//')
    local cname=$(get_container_name "pgsql" "$ver")
    local status=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo "不存在")
    local port=$(read_env_value "PGSQL_${ver//./}_PORT" "5432")
    printf "  %s  %s  (端口: %s, 数据目录: %s/%s)\n" "$ver" "$status" "$port" "$PGSQL_DATA_ROOT" "$ver"
  done
}

# --purge 的数据目录/配置删除确认（非终端环境保留并提示）
_pgsql_purge() {
  local ver=$1
  local data_dir="${PGSQL_DATA_ROOT}/${ver}"
  if confirm_yes "确认删除数据目录 ${data_dir} 吗？不可恢复！"; then
    # initdb 后数据文件归容器内 postgres 用户（uid 70），宿主删不动，走容器兜底
    _rm_rf_with_docker_fallback "$data_dir"
  elif ! [[ -t 0 ]]; then
    log "非交互模式，保留数据目录"
  fi
  if confirm_yes "是否删除配置目录 $CONFIG_DIR/pgsql/$ver ?"; then
    rm -rf "$CONFIG_DIR/pgsql/$ver"
  fi
}

_pgsql_uninstall() {
  local ver="${1:-}"
  local purge=false
  [ -z "$ver" ] && error "用法: phpbox pgsql uninstall <版本> [--purge]"
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --purge) purge=true ;;
      *) error "未知选项: $1" ;;
    esac
    shift
  done

  if [ ! -f "$EXT_DIR/pgsql-${ver}.yml" ]; then
    error "PostgreSQL ${ver} 未安装"
  fi

  log "卸载 PostgreSQL ${ver}"
  stop_and_remove_container "$(get_container_name "pgsql" "$ver")"
  if $purge; then
    _pgsql_purge "$ver"
  else
    log "数据目录和配置已保留"
  fi
  rm -f "$EXT_DIR/pgsql-${ver}.yml"
  success "PostgreSQL ${ver} 已卸载"
}
