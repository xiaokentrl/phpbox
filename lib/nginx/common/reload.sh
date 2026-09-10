#!/bin/bash
# shellcheck shell=bash
# Nginx 配置验证后的重载与 best-effort 重载（搬运自 lib/nginx.sh，纯迁移无逻辑改动）

nginx_try_reload() {
  # -qx：整行精确匹配容器名，避免误中 "nginx-proxy" 之类的前缀相似名
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'nginx' || return 0
  docker exec nginx nginx -s reload >/dev/null 2>&1 || true
}

_nginx_reload() {
  _nginx_validate || error "配置验证失败"
  if docker exec nginx nginx -s reload 2>/dev/null; then
    success "Nginx 重载成功"
  else
    error "Nginx 重载失败，请检查日志"
  fi
}
