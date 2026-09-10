#!/bin/bash
# shellcheck shell=bash
# 备份工具集：路径解析与服务停启（搬运自 lib/backup.sh，纯迁移无逻辑改动）

# 把路径规整为绝对路径（消解 ../ 与符号链接）；-m 允许目标尚不存在；无 realpath 命令时退回 python3
_get_abs_path() {
  local path=$1
  if command -v realpath &>/dev/null && realpath -m "$path" &>/dev/null; then
    realpath -m "$path"
  else
    python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$path" 2>/dev/null || echo "$path"
  fi
}

# 停止某类服务所有运行中的容器并记录（备份/恢复期间保证数据一致性，结束后自动重启）
PHPBOX_STOPPED=()
_phpbox_stop_svc() {
  local svc=$1 f ver cname
  for f in "$EXT_DIR"/${svc}-*.yml; do
    [ -f "$f" ] || continue   # glob 无匹配时保持字面串，靠 -f 过滤掉
    ver=$(basename "$f" .yml | sed "s/${svc}-//")
    cname=$(get_container_name "$svc" "$ver")
    if docker inspect -f '{{.State.Running}}' "$cname" 2>/dev/null | grep -q '^true$'; then
      docker stop "$cname" >/dev/null 2>&1 || true
      PHPBOX_STOPPED+=("$cname")
    fi
  done
}

_phpbox_start_stopped() {
  local cname
  # ${arr[@]:-}：数组可能为空，给空默认值防止旧版 bash 在 set -u 下报 unbound variable
  for cname in "${PHPBOX_STOPPED[@]:-}"; do
    [ -n "$cname" ] && docker start "$cname" >/dev/null 2>&1 || true
  done
}
