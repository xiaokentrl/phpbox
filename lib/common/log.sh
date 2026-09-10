#!/bin/bash
# shellcheck shell=bash
# 统一日志输出与终端交互（搬运自 lib/common.sh，纯迁移无逻辑改动）

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

# log/success 一律走 stderr：项目里大量函数以 stdout 返回值、调用方用命令替换捕获，
# 日志若混入 stdout 会污染返回值——曾把彩色日志行拼进生成的 compose yml 导致解析失败
log()    { echo -e "${CYAN}[INFO] $*${NC}" >&2; }
success(){ echo -e "${GREEN}[OK]   $*${NC}" >&2; }
# 统一失败出口：打印红色错误到 stderr 后立即退出整个脚本——全项目依赖这一约定
error()  { echo -e "${RED}[ERR]  $*${NC}" >&2; exit 1; }

# 交互确认：仅在终端可用时提问（回车默认拒绝）；非终端环境直接返回 1（不删除）
confirm_yes() {
  local prompt=$1
  [[ -t 0 ]] || return 1   # -t 0：标准输入是否连着终端；脚本/管道环境一律视为拒绝
  local ans
  read -p "${prompt} (y/N): " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}
