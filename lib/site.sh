#!/bin/bash
# shellcheck shell=bash

SITES_DIR="$CONFIG_DIR/nginx/sites"

# 域名校验：支持多级域名（如 demo.test、a.b.example.com），每段以字母数字开头结尾
_valid_domain() {
  [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]
}

# 站点变更失败时回滚到备份（备份为空则移除新配置）
_site_rollback() {
  local site=$1
  local backup_conf="$SITES_DIR/.backup.$site.conf"
  local final_conf="$SITES_DIR/${site}.conf"
  if [ -s "$backup_conf" ]; then
    mv "$backup_conf" "$final_conf"
  else
    rm -f "$final_conf"
  fi
}

# 校验新配置并原子替换，成功后重载 nginx；任一步失败自动回滚
_site_atomic_replace() {
  local site=$1
  local new_conf=$2
  local tmp_conf="$SITES_DIR/.tmp.$site.conf"
  local backup_conf="$SITES_DIR/.backup.$site.conf"
  local final_conf="$SITES_DIR/${site}.conf"

  if [ -f "$final_conf" ]; then
    cp "$final_conf" "$backup_conf"
  else
    touch "$backup_conf"
  fi

  # heredoc 不带引号：会展开变量 $new_conf，即把生成好的配置文本写入临时文件
  cat > "$tmp_conf" <<EOF
$new_conf
EOF

  mv "$tmp_conf" "$final_conf"

  if ! _nginx_validate &>/dev/null; then
    _site_rollback "$site"
    error "Nginx 配置验证失败，站点变更已回滚"
  fi

  if ! docker exec nginx nginx -s reload 2>/dev/null; then
    _site_rollback "$site"
    _nginx_validate >/dev/null
    docker exec nginx nginx -s reload >/dev/null
    error "Nginx 重载失败，站点变更已回滚"
  fi

  rm -f "$backup_conf"
  success "站点 ${site} 配置已应用并重载"
}

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

_site_add() {
  local site="${1:-}"
  [ $# -ge 1 ] && shift

  local php_ver=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --php)
        [ $# -ge 2 ] || error "--php 需要指定 PHP 版本"
        php_ver="$2"; shift 2 ;;
      *)
        if [ -z "$site" ]; then site="$1"
        elif [ -z "$php_ver" ]; then php_ver="$1"
        else error "未知选项: $1"
        fi
        shift ;;
    esac
  done
  [ -z "$site" ] && error "用法: phpbox site add <域名> --php <版本> 或 site add <域名> <版本>"
  [ -z "$php_ver" ] && error "请指定 PHP 版本"

  if ! _valid_domain "$site"; then
    error "无效域名: $site（仅允许字母、数字、短横线、点，且每段以字母数字开头结尾）"
  fi

  if [ ! -f "$EXT_DIR/nginx-default.yml" ]; then
    error "Nginx 未安装，请先执行 'phpbox nginx install'"
  fi
  local php_key=$(get_service_key "php" "$php_ver")
  if ! docker ps --filter "label=${PROJECT_NAME}${LABEL_SEPARATOR}service=php" \
      --filter "label=${PROJECT_NAME}${LABEL_SEPARATOR}version=${php_ver}" --format "{{.Names}}" | grep -q .; then
    error "PHP ${php_ver} 未运行，请先安装并启动"
  fi
  if [ -f "$SITES_DIR/${site}.conf" ]; then
    error "站点 ${site} 已存在"
  fi
  mkdir -p "${WWW_ROOT}/${site}"

  # resolver 127.0.0.11 为 Docker 内嵌 DNS；upstream 用变量形式让 nginx 在请求时
  # 动态解析，PHP 容器重建（extension add/remove）换 IP 后站点不会因 IP 缓存而 502
  local new_conf="server {
    listen 80;
    server_name ${site};
    root /var/www/${site};
    index index.php index.html;
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    location ~ \.php$ {
        resolver 127.0.0.11 valid=10s ipv6=off;
        set \$php_upstream ${php_key}:9000;
        fastcgi_pass \$php_upstream;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}"

  _site_atomic_replace "$site" "$new_conf"

  local port=$(grep "^NGINX_PORT=" "$ENV_FILE" | cut -d= -f2)
  echo -e "${CYAN}站点 ${site} 已创建，访问地址: http://${site}:${port}${NC}"
  if [ "$port" != "80" ]; then
    echo -e "${CYAN}注意：Nginx 监听端口 ${port}，请使用该端口访问${NC}"
  fi
  echo -e "${CYAN}使用 'phpbox hosts add ${site}' 添加域名解析${NC}"
}

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

_site_show_list() {
  echo "站点列表:"
  if [ -z "$(ls -A "$SITES_DIR" 2>/dev/null)" ]; then
    echo "  (无站点)"
    return
  fi
  for f in "$SITES_DIR"/*.conf; do
    [ -f "$f" ] || continue   # glob 无匹配时保持字面串，靠 -f 过滤掉
    local name=$(basename "$f" .conf)
    local php=$(grep -F 'set $php_upstream' "$f" | awk '{print $3}' | cut -d: -f1)
    if [ -z "$php" ]; then
      # 兼容旧版模板
      php=$(grep fastcgi_pass "$f" | awk '{print $2}' | cut -d: -f1)
    fi
    echo "  ${name} -> ${php}"
  done
}

_site_remove() {
  local site="${1:-}"
  [ -z "$site" ] && error "用法: phpbox site remove <域名>"
  local conf="$SITES_DIR/${site}.conf"
  [ -f "$conf" ] || error "站点 ${site} 不存在"

  local backup_conf="$SITES_DIR/.backup.$site.conf"
  cp "$conf" "$backup_conf"
  rm -f "$conf"

  if _nginx_validate &>/dev/null; then
    docker exec nginx nginx -s reload 2>/dev/null || {
      mv "$backup_conf" "$conf"
      error "删除站点后重载失败，已恢复"
    }
    rm -f "$backup_conf"
  else
    mv "$backup_conf" "$conf"
    error "删除站点后配置无效，已恢复"
  fi

  local site_dir="${WWW_ROOT}/${site}"
  if [ -d "$site_dir" ] && confirm_yes "是否删除站点目录 ${site_dir} ?"; then
    rm -rf "$site_dir"
  fi
  success "站点 ${site} 已删除"
  echo -e "${CYAN}如需移除域名解析，请执行 'phpbox hosts remove ${site}'${NC}"
}

# 仅做分发，实现见各 _site_* 函数
cmd_site() {
  case "${1:-help}" in
    add)    shift; _site_add "$@" ;;
    switch) shift; _site_switch "$@" ;;
    list)   _site_show_list ;;
    remove) _site_remove "${2:-}" ;;
    *) error "未知 site 操作: ${1:-help}" ;;
  esac
}
