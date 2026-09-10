#!/bin/bash
# shellcheck shell=bash
# Redis 端口修改事务（搬运自 lib/redis.sh，纯迁移无逻辑改动）

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
