#!/bin/bash
# shellcheck shell=bash
# 站点清单（搬运自 lib/site.sh，纯迁移无逻辑改动）

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
