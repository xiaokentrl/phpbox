#!/bin/bash
# shellcheck shell=bash

_mysql_generate_compose() {
  local ver=$1
  local svc_key=$(get_service_key "mysql" "$ver")
  local cname=$(get_container_name "mysql" "$ver")
  local port=$(get_or_set_port "mysql" "$ver" "3306")
  # 仅确保密码已写入 .env；函数以 echo 返回密码值，裸调用会把 root 密码打印到终端
  get_or_set_password "mysql" "$ver" > /dev/null
  local data_dir="${MYSQL_DATA_ROOT}/${ver}"
  local yml="$EXT_DIR/mysql-${ver}.yml"

  # 确保数据目录存在，并设置容器内 mysql 用户可写权限。
  # 普通用户无权 chown，失败时借助容器内 root 兜底（Docker daemon 通常以 root 运行）
  mkdir -p "$data_dir"
  if ! chown -R 999:999 "$data_dir" 2>/dev/null; then
    log "当前用户无法直接 chown 数据目录，尝试通过 Docker 容器设置属主..."
    if docker run --rm -v "$data_dir":/data alpine chown -R 999:999 /data &>/dev/null; then
      log "数据目录属主已通过容器设置为 999:999"
    else
      log "警告：无法将 $data_dir 属主设为 999:999，MySQL 可能因权限问题无法写入；请手动执行: sudo chown -R 999:999 $data_dir"
    fi
  fi

  # .env 键名规范：MYSQL_<去点版本>_PORT / MYSQL_<去点版本>_ROOT_PASSWORD（如 MYSQL_84_PORT）。
  # 环境变量名不允许出现点，版本号统一去点；yml 里写的是 ${...} 字面量，由 compose 从 .env 现场解析
  cat > "$yml" <<YEOF
services:
  $svc_key:
    image: mysql:${ver}
    container_name: $cname
    ports:
      - "\${MYSQL_${ver//./}_PORT}:3306"
    environment:
      MYSQL_ROOT_PASSWORD: "\${MYSQL_${ver//./}_ROOT_PASSWORD}"
    volumes:
      - \${MYSQL_DATA_ROOT}/${ver}:/var/lib/mysql
      - ./config/mysql/${ver}/my.cnf:/etc/mysql/conf.d/my.cnf:ro
    networks:
      - net
    restart: unless-stopped
    labels:
      - "${PROJECT_NAME}${LABEL_SEPARATOR}service=mysql"
      - "${PROJECT_NAME}${LABEL_SEPARATOR}version=${ver}"
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5
YEOF
}

_mysql_ensure_running() {
  local ver=$1
  local svc_key=$(get_service_key "mysql" "$ver")
  run_compose "mysql" "$ver" up -d "$svc_key"
  local cname=$(get_container_name "mysql" "$ver")
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

_mysql_port_set() {
  local sub="${1:-}"
  local ver="${2:-}"
  local new_port="${3:-}"
  [ "$sub" != "set" ] && error "用法: phpbox mysql port set <版本> <新端口>"
  [ -z "$ver" ] && error "请指定版本"
  [ -z "$new_port" ] && error "请指定新端口"
  validate_version "$ver"
  _generic_db_port_set "mysql" "$ver" "$new_port" "3306"
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
    rm -rf "$data_dir"
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
  run_compose "mysql" "$ver" down 2>/dev/null || true
  if $purge; then
    _mysql_purge "$ver"
  else
    log "数据目录和配置已保留"
  fi
  rm -f "$EXT_DIR/mysql-${ver}.yml"
  success "MySQL ${ver} 已卸载"
}

# 仅做分发，实现见各 _mysql_* 函数
cmd_mysql() {
  case "${1:-help}" in
    install)   shift; _mysql_install "$@" ;;
    port)      _mysql_port_set "${2:-}" "${3:-}" ;;
    list)      _mysql_show_list ;;
    uninstall) shift; _mysql_uninstall "$@" ;;
    *) error "未知 mysql 操作: ${1:-help} (支持 install, port, list, uninstall)" ;;
  esac
}
