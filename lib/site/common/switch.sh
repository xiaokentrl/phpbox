#!/bin/bash
# shellcheck shell=bash
# 站点 PHP 版本切换（搬运自 lib/site.sh，纯迁移无逻辑改动）

_site_switch() {
  local site="${1:-}"
  [ $# -ge 1 ] && shift

  local php_ver=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --php)
        [ $# -ge 2 ] || error "--php 需要指定 PHP 版本"
        php_ver="$2"; shift 2 ;;
      *)
        [ -z "$php_ver" ] || error "未知选项: $1"
        php_ver="$1"; shift ;;
    esac
  done
  [ -z "$site" ] && error "用法: phpbox site switch <域名> --php <版本>"
  [ -z "$php_ver" ] && error "请指定 PHP 版本"

  local conf="$SITES_DIR/${site}.conf"
  [ -f "$conf" ] || error "站点 ${site} 不存在"
  require_docker
  local php_key=$(get_service_key "php" "$php_ver")
  if ! docker ps --filter "label=${PROJECT_NAME}${LABEL_SEPARATOR}service=php" \
      --filter "label=${PROJECT_NAME}${LABEL_SEPARATOR}version=${php_ver}" --format "{{.Names}}" | grep -q .; then
    error "PHP ${php_ver} 未运行"
  fi

  local old_conf=$(cat "$conf")
  # -F：按固定字符串匹配，$ 等字符不做正则解释
  if grep -qF 'set $php_upstream' "$conf"; then
    local new_conf=$(echo "$old_conf" | sed "s|set \$php_upstream [^;]*;|set \$php_upstream ${php_key}:9000;|")
  else
    # 兼容旧版模板（fastcgi_pass 直接写服务名）
    local new_conf=$(echo "$old_conf" | sed "s|fastcgi_pass .*:9000;|fastcgi_pass ${php_key}:9000;|")
  fi
  _site_atomic_replace "$site" "$new_conf"
  success "站点 ${site} 已切换至 PHP ${php_ver}"
}
