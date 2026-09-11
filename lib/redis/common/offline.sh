#!/bin/bash
# shellcheck shell=bash

# Redis 镜像离线事务的薄绑定层：公共实现见 lib/common/docker.sh 的
# _ensure_offline_image，本文件只绑定 redis 线的常量——tag 后缀 -alpine
# 与离线库目录名里的裸版本号不同（redis:8-alpine → offline/redis/8/），
# 这正是公共层把"版本"与"镜像 tag"分开传参的原因
_redis_ensure_image() {
  local ver=$1 mode="${2:-install}"
  _ensure_offline_image "redis" "$ver" "redis:${ver}-alpine" "$mode"
}
