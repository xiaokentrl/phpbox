#!/bin/bash
# shellcheck shell=bash
# Redis compose 分片与 redis.conf 生成（搬运自 lib/redis.sh，纯迁移无逻辑改动）

_init_redis_config() {
  local dir=$1
  cat > "$dir/redis.conf" <<'EOF'
# phpbox local Redis configuration. Edit this file and recreate the Redis service to apply changes.
appendonly yes
dir /data
protected-mode yes
timeout 0
tcp-keepalive 300
EOF
}

_redis_generate_compose() {
  local ver=$1
  local svc_key=$(get_service_key "redis" "$ver")
  local cname=$(get_container_name "redis" "$ver")
  local vol_name=$(get_volume_name "redis" "$ver")
  local port=$(get_or_set_port "redis" "$ver" "6379")
  local password_key="REDIS_${ver//./}_ROOT_PASSWORD"
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
    command: ["redis-server", "/usr/local/etc/redis/redis.conf", "--requirepass", "\${${password_key}}"]
    ports:
      - "\${REDIS_${ver//./}_PORT}:6379"
    volumes:
      - $vol_name:/data
      - ./config/redis/${ver}/redis.conf:/usr/local/etc/redis/redis.conf:ro
    networks:
      - net
    restart: unless-stopped
    labels:
      - "${PROJECT_NAME}${LABEL_SEPARATOR}service=redis"
      - "${PROJECT_NAME}${LABEL_SEPARATOR}version=${ver}"
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a \${${password_key}} --no-auth-warning ping | grep -q PONG"]
      interval: 10s
      timeout: 5s
      retries: 5
YEOF
}
