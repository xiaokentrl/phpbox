#!/bin/bash
# shellcheck shell=bash
# MySQL compose 分片与 my.cnf 生成（搬运自 lib/mysql.sh，纯迁移无逻辑改动）

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
  mkdir -p "$data_dir"
  # 先清残留 socket 再 chown：下面容器内 chown -R 的兜底路径碰它同样会报
  # Operation not permitted，导致属主设置静默失败并留下隐患
  _mysql_clean_stale_sock "$ver"
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
    # 容器每次启动前先清掉数据目录残留的 mysql.sock 符号链接，再进入官方 entrypoint：
    # 异常停机残留的该链接会让 entrypoint 的 chown -R 报 Operation not permitted 而
    # 崩溃循环（restart: unless-stopped 下每分钟重试一次）。exec 保证 docker-entrypoint.sh
    # 仍是 PID 1，优雅停机语义不变；此覆盖同样保护 docker daemon 重启时的自动拉起路径
    # （那时 phpbox 不在场，宿主机侧清理无从执行）
    entrypoint: ["sh", "-c", "rm -f /var/lib/mysql/mysql.sock; exec docker-entrypoint.sh mysqld"]
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

# MySQL 镜像不带可拷贝的配置模板，按版本生成：
# 8.4 起旧的 default-authentication-plugin 写法已移除，改用 mysql_native_password=ON 启用旧认证插件
_init_mysql_config() {
  local dir=$1 ver=$2
  local mysql_major=$(echo "$ver" | cut -d. -f1)
  local mysql_minor=$(echo "$ver" | cut -d. -f2)
  if [[ "$mysql_major" -ge 8 && "$mysql_minor" -ge 4 ]] || [[ "$mysql_major" -gt 8 ]]; then
    cat > "$dir/my.cnf" <<'MYEOF'
[mysqld]
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
mysql_native_password=ON
MYEOF
  else
    cat > "$dir/my.cnf" <<'MYEOF'
[mysqld]
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
default-authentication-plugin=mysql_native_password
MYEOF
  fi
}
