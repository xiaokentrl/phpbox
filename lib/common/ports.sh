#!/bin/bash
# shellcheck shell=bash
# 端口检查、占用报告与端口分配（搬运自 lib/common.sh，纯迁移无逻辑改动）

check_port() {
  local port=$1
  # command -v：判断某个命令是否可用（比 which 可靠）；&>/dev/null：stdout/stderr 全部丢弃，只关心退出码
  if command -v ss &>/dev/null; then
    # 冒号后必须紧跟空白：查 80 端口时才不会误匹配到 8080 的监听行
    ss -tln | grep -qE ":${port}[[:space:]]" && return 1
  elif command -v lsof &>/dev/null; then
    lsof -i :"$port" -sTCP:LISTEN -t &>/dev/null 2>&1 && return 1
  fi
  return 0
}

show_port_owner() {
  local port=$1
  if command -v lsof &>/dev/null; then
    if lsof -i :"$port" -sTCP:LISTEN &>/dev/null 2>&1; then
      lsof -i :"$port" -sTCP:LISTEN 2>/dev/null | tail -n +2   # tail -n +2：跳过输出的表头行
    else
      lsof -i :"$port" 2>/dev/null | tail -n +2
    fi
  elif command -v netstat &>/dev/null; then
    netstat -tlnp 2>/dev/null | awk "/:${port}[[:space:]]/"'{print $7}'
  else
    echo "无法获取进程信息（缺少 lsof/netstat）"
  fi
}

check_and_report_port() {
  local port=$1
  if ! check_port "$port"; then
    echo -e "${RED}端口 ${port} 已被占用，占用信息：${NC}" >&2
    show_port_owner "$port" >&2
    echo -e "${CYAN}请手动释放端口，或使用 '--port' 指定其他可用端口。${NC}" >&2
    return 1
  fi
  return 0
}

find_free_port() {
  local start=${1:-80}
  local p=$start
  while ! check_port "$p"; do
    p=$((p+1))
  done
  echo "$p"
}

get_or_set_port() {
  local svc=$1 ver=$2 default=$3
  local key; key=$(port_key "$svc" "$ver")   # 键名如 MYSQL_84_PORT；nginx 固定用 NGINX_PORT
  if [ "$svc" = "nginx" ]; then
    key="NGINX_PORT"
  fi

  # local 与赋值拆开写是刻意的：local 会吞掉命令替换的失败状态，合写会掩盖错误
  local val; val=$(read_env_value "$key" "")
  if [ -z "$val" ]; then
    val=$(find_free_port "$default")   # 从未记录过：自动挑空闲端口并写入 .env
    env_set "$key" "$val"
  else
    if ! check_port "$val"; then
      echo -e "${YELLOW}警告：已配置的端口 ${val} 被占用，正在寻找可用端口...${NC}" >&2
      local new_val; new_val=$(find_free_port "$default")
      log "将使用新端口 ${new_val}，并更新 .env"
      env_set "$key" "$new_val"
      val=$new_val
    fi
  fi
  echo "$val"
}
