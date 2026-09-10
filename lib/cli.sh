#!/bin/bash
# shellcheck shell=bash
# 命令路由实现与全局命令（搬运自 lib/common.sh，纯迁移无逻辑改动）
# show_help 与入口薄化在第 5 步执行；本切片先落 cmd_list

# 全局服务列表
cmd_list() {
  # docker --format 里要嵌 Shell 变量，用的是"关引号-插值-再开引号"拼接：
  # 单引号段是字面模板；中间 "'"${VAR}"'" 处引号临时关闭、插入变量值、再恢复单引号。
  # {{.Names}}/{{.Label}} 是 Go 模板占位符，\t 是制表符分列
  docker ps -a --filter "label=${PROJECT_NAME}${LABEL_SEPARATOR}service" --format \
    'table {{.Names}}\t{{.Label "'"${PROJECT_NAME}${LABEL_SEPARATOR}"'service"}}\t{{.Label "'"${PROJECT_NAME}${LABEL_SEPARATOR}"'version"}}\t{{.Ports}}\t{{.Status}}'
}
