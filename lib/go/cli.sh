#!/bin/bash
# shellcheck shell=bash
# go 子命令分发（搬运自 lib/go.sh，纯迁移无逻辑改动）

cmd_go() {
  local action="${1:-help}"
  case "$action" in
    install) shift; _go_install "$@" ;;
    uninstall) shift; _go_uninstall "$@" ;;
    list) _go_list ;;
    server) _go_server ;;
    run|test|shell|logs|stop|env)
      [ $# -ge 2 ] || error "用法: phpbox go $action <项目名或路径>"
      _go_exec "$action" "$2" "${@:3}" ;;
    help|-h|--help)
      cat <<'HELPEOF'
Go 命令:
  go install [版本]                         安装 Go 镜像
  go uninstall <版本> [--purge]             卸载 Go 镜像（latest 表示最新稳定版）
  go list                                   查看已安装的 Go 镜像和容器
  go server                                 查看自动发现的 Go 项目及状态
  go run <项目>                              启动 Go 项目开发进程
  go test <项目>                             执行 go test ./...
  go shell <项目>                            进入 Go 容器
  go logs <项目>                             查看 Go 容器日志
  go stop <项目>                             停止 Go 项目容器
  go env <项目>                              查看 Go 容器环境
HELPEOF
      ;;
    *) error "未知 go 操作: $action（支持 install, list, server, run, test, shell, logs, stop, env）" ;;
  esac
}
