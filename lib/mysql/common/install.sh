#!/bin/bash
# shellcheck shell=bash
# MySQL 安装/卸载/启动/清单生命周期（搬运自 lib/mysql.sh，纯迁移无逻辑改动）

# 清理数据目录中残留的 mysql.sock 符号链接。mysqld 运行时会在数据目录创建指向
# /var/run/mysqld/mysqld.sock 的符号链接，容器异常停止（kill/断电/崩溃）后它不会消失；
# mysql 官方镜像 entrypoint 启动时的 chown -R 在 overlayfs 上 chown 该符号链接会报
# Operation not permitted，容器随即退出，配合 restart: unless-stopped 形成每分钟一轮的
# 崩溃循环。客户端实际使用 /var/run/mysqld/mysqld.sock（镜像 /etc/my.cnf 的 [client]），
# 删除数据目录里的这个链接无副作用
_mysql_clean_stale_sock() {
  local ver=$1
  # 尽力而为：成功安装过一次后数据目录整体归 999，宿主用户对目录无写权限、unlink 必失败；
  # 权威清理在 yml 的 entrypoint 覆盖里（容器内以 root 执行），此处只兜住目录仍可写的场景。
  # 不能让本函数失败：set -e 会把整个安装拦死在权限上
  rm -f "${MYSQL_DATA_ROOT:?}/${ver}/mysql.sock" 2>/dev/null || true
}

_mysql_ensure_running() {
  local ver=$1
  local svc_key=$(get_service_key "mysql" "$ver")
  local cname=$(get_container_name "mysql" "$ver")
  # 容器未运行时先清残留 socket 再 up；运行中则不动（up -d 幂等无操作，链接也无需处理）
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$cname"; then
    _mysql_clean_stale_sock "$ver"
  fi
  run_compose "mysql" "$ver" up -d "$svc_key"
  local timeout=30
  while [ $timeout -gt 0 ]; do
    if docker exec "$cname" mysqladmin ping -h localhost &>/dev/null; then
      return 0
    fi
    sleep 2
    timeout=$((timeout - 2))
  done
  error "MySQL ${ver} 启动超时"
}

_mysql_install() {
  local ver="${1:-}"
  [ -z "$ver" ] && error "用法: phpbox mysql install <版本> [--port 端口]"
  shift
  _generic_service_install "mysql" "$ver" "3306" "$@"
  # 本地开发场景：安装完成直接亮出 root 密码，免翻 .env。
  # 自定义密码：安装前在 .env 预设 MYSQL_<去点版本>_ROOT_PASSWORD，留空则自动生成
  local pass; pass=$(get_or_set_password "mysql" "$ver")
  log "MySQL ${ver} root 密码: ${pass}（已保存于 .env 的 MYSQL_${ver//./}_ROOT_PASSWORD）"
}

_mysql_show_list() {
  echo "已安装 MySQL 版本:"
  for f in "$EXT_DIR"/mysql-*.yml; do
    [ -f "$f" ] || continue   # glob 无匹配时保持字面串，靠 -f 过滤掉
    local ver=$(basename "$f" .yml | sed 's/mysql-//')
    local cname=$(get_container_name "mysql" "$ver")
    local status=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo "不存在")
    local port=$(read_env_value "MYSQL_${ver//./}_PORT" "3306")
    printf "  %s  %s  (端口: %s, 数据目录: %s/%s)\n" "$ver" "$status" "$port" "$MYSQL_DATA_ROOT" "$ver"
  done
}

# --purge 的数据目录/配置删除确认（非终端环境保留并提示）
_mysql_purge() {
  local ver=$1
  local data_dir="${MYSQL_DATA_ROOT}/${ver}"
  if confirm_yes "确认删除数据目录 ${data_dir} 吗？不可恢复！"; then
    _rm_rf_with_docker_fallback "$data_dir"
  elif ! [[ -t 0 ]]; then
    log "非交互模式，保留数据目录"
  fi
  if confirm_yes "是否删除配置目录 $CONFIG_DIR/mysql/$ver ?"; then
    rm -rf "$CONFIG_DIR/mysql/$ver"
  fi
}

_mysql_uninstall() {
  local ver="${1:-}"
  local purge=false
  [ -z "$ver" ] && error "用法: phpbox mysql uninstall <版本> [--purge]"
  shift
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
  stop_and_remove_container "$(get_container_name "mysql" "$ver")"
  if $purge; then
    _mysql_purge "$ver"
  else
    log "数据目录和配置已保留"
  fi
  rm -f "$EXT_DIR/mysql-${ver}.yml"
  success "MySQL ${ver} 已卸载"
}
