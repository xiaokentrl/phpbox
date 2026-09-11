#!/bin/bash
# shellcheck shell=bash

# Nginx 镜像离线事务的薄绑定层：公共实现见 lib/common/docker.sh 的
# _ensure_offline_image。nginx 特殊点：版本 tag 是镜像 tag 别名（alpine/1.25），
# 不是数字版本；离线库目录名直接用该 tag（offline/nginx/alpine/nginx-alpine.tar），
# 与 compose yml 的 image: nginx:<tag> 一一对应，避免引入第二套版本映射
_nginx_ensure_image() {
  local tag="${1:-alpine}" mode="${2:-install}"
  _ensure_offline_image "nginx" "$tag" "nginx:$tag" "$mode"
}
