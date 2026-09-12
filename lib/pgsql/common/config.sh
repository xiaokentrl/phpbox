#!/bin/bash
# shellcheck shell=bash
# PostgreSQL compose 分片与 postgresql.conf 生成

# 每版本生成并挂载本地可编辑配置（与 redis.conf 同一契约）。最小集：
# listen_addresses 必须显式给 '*'——initdb 生成的默认配置只听 localhost，
# 会掐断宿主机端口发布；其余配置项用户可自行追加，重建容器生效
_init_pgsql_config() {
  local dir=$1
  cat > "$dir/postgresql.conf" <<'EOF'
# phpbox local PostgreSQL configuration. Edit this file and recreate the PostgreSQL service to apply changes.
listen_addresses = '*'
max_connections = 100
EOF
}

_pgsql_generate_compose() {
  local ver=$1
  local svc_key=$(get_service_key "pgsql" "$ver")
  local cname=$(get_container_name "pgsql" "$ver")
  local port=$(get_or_set_port "pgsql" "$ver" "5432")
  # 仅确保密码已写入 .env；函数以 echo 返回密码值，裸调用会把密码打印到终端
  get_or_set_password "pgsql" "$ver" > /dev/null
  local data_dir="${PGSQL_DATA_ROOT}/${ver}"
  local yml="$EXT_DIR/pgsql-${ver}.yml"

  mkdir -p "$data_dir"

  # .env 键名规范：PGSQL_<去点版本>_PORT / PGSQL_<去点版本>_ROOT_PASSWORD（如 PGSQL_17_PORT）。
  # yml 里写的是 ${...} 字面量，由 compose 从 .env 现场解析
  cat > "$yml" <<YEOF
services:
  $svc_key:
    image: postgres:${ver}-alpine
    container_name: $cname
    # 外挂可编辑配置必须用 -c config_file 指路（镜像默认读 PGDATA 内 initdb 生成的
    # 那份）；initdb 临时服务器不走此参数，初始化与运行期配置互不干扰
    command: ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]
    ports:
      - "\${PGSQL_${ver//./}_PORT}:5432"
    environment:
      POSTGRES_PASSWORD: "\${PGSQL_${ver//./}_ROOT_PASSWORD}"
    volumes:
      # 挂载点用 /var/lib/postgresql（官方 18 起卷位置上移到这一层）：
      # 17 的 PGDATA=data/ 子目录、18 的 PGDATA=<主版本>/docker 子目录都落在挂载内，
      # 同一份 compose 对两个版本代次都成立。数据文件归容器内 postgres 用户，勿在宿主 chown
      - \${PGSQL_DATA_ROOT}/${ver}:/var/lib/postgresql
      - ./config/pgsql/${ver}/postgresql.conf:/etc/postgresql/postgresql.conf:ro
    networks:
      - net
    restart: unless-stopped
    labels:
      - "${PROJECT_NAME}${LABEL_SEPARATOR}service=pgsql"
      - "${PROJECT_NAME}${LABEL_SEPARATOR}version=${ver}"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
YEOF
}
