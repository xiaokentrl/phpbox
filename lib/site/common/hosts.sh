#!/bin/bash
# shellcheck shell=bash
# hosts 增删查（搬运自 lib/site.sh，纯迁移无逻辑改动；目标树未列 hosts 文件，
# 按"文件名必须说明职责"补齐，归属判断记录于迁移规范附录 A）

cmd_hosts() {
  local action="${1:-help}"
  local domain="${2:-}"
  local hosts_file="/etc/hosts"

  if [ "$action" != "list" ] && ! sudo -n true 2>/dev/null; then
    error "hosts 操作需要 sudo 权限，请配置 NOPASSWD 或使用 sudo"
  fi

  case "$action" in
    add)    _hosts_add "$domain" "$hosts_file" ;;
    remove) _hosts_remove "$domain" "$hosts_file" ;;
    list)   _hosts_list "$hosts_file" ;;
    *) error "未知 hosts 操作: $action" ;;
  esac
}

_hosts_add() {
  local domain=$1 hosts_file=$2
  [ -z "$domain" ] && error "用法: phpbox hosts add <域名>"
  _valid_domain "$domain" || error "无效域名: $domain"
  if grep -qF "127.0.0.1 ${domain}" "$hosts_file"; then
    log "域名 ${domain} 已存在"
  else
    echo "127.0.0.1 ${domain}" | sudo tee -a "$hosts_file" > /dev/null
    success "已添加: 127.0.0.1 ${domain}"
  fi
}

_hosts_remove() {
  local domain=$1 hosts_file=$2
  [ -z "$domain" ] && error "用法: phpbox hosts remove <域名>"
  _valid_domain "$domain" || error "无效域名: $domain"
  if ! grep -qF "127.0.0.1 ${domain}" "$hosts_file"; then
    log "域名 ${domain} 未找到"
    return
  fi
  # 域名中的点转义为 \. ：它将作为正则交给 sed，未转义的 . 会匹配任意字符
  local escaped_domain="${domain//./\\.}"
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sudo sed -i "" "/^127\.0\.0\.1[[:space:]]\+${escaped_domain}$/d" "$hosts_file"
  else
    sudo sed -i "/^127\.0\.0\.1[[:space:]]\+${escaped_domain}$/d" "$hosts_file"
  fi
  success "已移除: $domain"
}

_hosts_list() {
  local hosts_file=$1
  echo "当前 hosts 状态（phpbox 管理的站点）:"
  if [ -n "$(ls -A "$SITES_DIR" 2>/dev/null)" ]; then
    for f in "$SITES_DIR"/*.conf; do
      [ -f "$f" ] || continue   # glob 无匹配时保持字面串，靠 -f 过滤掉
      local site_name=$(basename "$f" .conf)
      if grep -qF "127.0.0.1 ${site_name}" "$hosts_file"; then
        echo "  [已添加] $site_name"
      else
        echo "  [未添加] $site_name"
      fi
    done
  else
    echo "  (无站点)"
  fi
}
