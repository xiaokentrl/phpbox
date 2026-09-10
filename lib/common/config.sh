#!/bin/bash
# shellcheck shell=bash
# 配置持久化工具（.env 写入侧）（搬运自 lib/common.sh，纯迁移无逻辑改动）

sed_i() {
  # macOS(BSD) 的 sed 要求 -i 后跟空串参数，Linux(GNU) 不需要——统一封装抹平差异
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i "" "$@"
  else
    sed -i "$@"
  fi
}

# 转义 sed 替换文本中的特殊字符：/ 与 |（本项目 sed 替换表达式用的分隔符）、
# &（替换侧代表"整个匹配"，不转义会把原值拼进去）
escape_sed() {
  echo "$1" | sed -e 's/[\/&|]/\\&/g'
}

# 写/更新 .env 键值：已存在则整行替换，不存在则追加。
# 全项目唯一的 .env 写入口，保证格式一致、不产生重复键
env_set() {
  local key=$1 val=$2 escaped_key escaped_val
  escaped_key=$(escape_sed "$key")
  escaped_val=$(escape_sed "$val")
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed_i "s|^${escaped_key}=.*|${escaped_key}=${escaped_val}|" "$ENV_FILE"
  else
    echo "${key}=${val}" >> "$ENV_FILE"
  fi
}

# 从 .env 删除键（半安装回滚用）；键不存在时静默。键名仅含字母数字下划线，可安全拼进 sed
env_unset() {
  sed_i "/^${1}=/d" "$ENV_FILE" 2>/dev/null || true
}
