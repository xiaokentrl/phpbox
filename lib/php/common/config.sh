#!/bin/bash
# shellcheck shell=bash
# PHP compose 分片与 php.ini/扩展状态生成（搬运自 lib/php.sh 与 lib/nginx.sh，纯迁移无逻辑改动）

_php_generate_compose() {
  local ver=$1
  local svc_key=$(get_service_key "php" "$ver")
  local yml="$EXT_DIR/php-${ver}.yml"
  local exts="$(_php_read_extensions "$ver")"
  # local 与赋值拆开是刻意的：local 会吞掉命令替换的失败状态——镜像构建失败时必须
  # 让 set -e 在写 yml 之前中止，否则会生成 image 为空的坏 yml（compose 报 "image must be a string"）
  local image
  image="$(_php_build_image "$ver" "$exts")"

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

# 从对应版本的 php 镜像拷出 php.ini-production 作为起点
# 【搬运修正】此函数原定义在 lib/nginx.sh（历史错位），按需求文档 §四 分层归位 php 线
_init_php_config() {
  local dir=$1 ver=$2
  docker run --rm -v "$dir":/out "php:${ver}-fpm-alpine" \
    sh -c "cp /usr/local/etc/php/php.ini-production /out/php.ini" || {
    rm -rf "$dir"; error "PHP 配置提取失败"
  }
}
