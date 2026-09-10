#!/bin/bash
# shellcheck shell=bash
# 命名派生与版本号校验（搬运自 lib/common.sh，纯迁移无逻辑改动）

# 版本号去掉点：8.4 → 84。服务名/容器名/镜像 tag/文件名不允许出现点，统一用无点形式
get_service_key() { echo "${1}${2//./}"; }

# 版本号白名单：仅允许 8.4 / 8.0.35 这类纯数字点分格式。
# 版本号会被拼进文件名、容器名、镜像 tag 和 .env 键名——空格/分号等字符会注入破坏这些位置，
# 甚至写出含空格的 .env 键污染后续所有命令
validate_version() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || error "无效版本号: $1（示例: 8、8.4、8.0.35）"
}

# 端口在 .env 中的键名：服务名_去点版本_PORT 转大写（如 MYSQL_84_PORT）
port_key() { echo "${1}_${2//./}_PORT" | tr '[:lower:]' '[:upper:]'; }
get_container_name() {
  local svc=$1 ver=$2
  local prefix_var="${svc^^}_SERVICE_PREFIX"   # ${svc^^} 转大写：php → PHP，拼出变量名 PHP_SERVICE_PREFIX
  local prefix="${!prefix_var:-$svc}"          # ${!var} 间接展开：读取该名字变量的值；未设置则回退为服务名本身
  echo "${prefix}${ver//./}"                   # 前缀 + 无点版本号，如 php84 / mysql84
}
get_volume_name() { echo "${PROJECT_NAME}_$(get_service_key "$1" "$2")_data"; }
