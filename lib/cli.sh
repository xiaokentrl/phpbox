#!/bin/bash
# shellcheck shell=bash
# 命令路由实现与全局命令（show_help 自 bin/phpbox、cmd_list 自 lib/common.sh 迁入，纯迁移无逻辑改动）
# bin/phpbox 自迁移第 5 步起退化为薄入口：shebang/守护 + 固定加载链 + 转调本文件。
# 本文件在 bin/phpbox 末尾被 source，届时全部函数已加载完毕、load_env 已执行，
# 文件底部的 Docker 预检与命令分发随即运行——与旧入口的执行位置完全一致

CMD_NAME="$(basename "$0")"

show_help() {
    cat <<HELPEOF
${CMD_NAME} - 多版本 Docker 开发环境管理

命令:
  php install <版本> [--ext 扩展列表]         安装 PHP（不带 --ext 时安装默认扩展集，见 PHP_DEFAULT_EXTENSIONS）
  php extension add <版本> <扩展>             添加扩展
  php extension remove <版本> <扩展>          移除扩展
  php list                                   列出所有 PHP
  php uninstall <版本> [--purge]             卸载 PHP

  mysql install <版本> [--port 端口]          安装 MySQL（完成后显示 root 密码）
  mysql port set <版本> <新端口>              修改端口
  mysql list                                 列出所有 MySQL
  mysql uninstall <版本> [--purge]           卸载 MySQL

  redis install [<版本>] [--port 端口]        安装 Redis（默认最新稳定版 Redis 8，默认端口 6379）
  redis port set <版本> <新端口>              修改端口
  redis list                                 列出所有 Redis
  redis uninstall <版本> [--purge]           卸载 Redis

  go install [版本]                         安装 Go 镜像（默认最新稳定版）
  go uninstall <版本> [--purge]             卸载 Go 镜像（latest 表示最新稳定版）
  go list                                   查看已安装的 Go 镜像和容器
  go server                                 查看自动发现的 Go 项目及状态
  go run <项目>                              启动 Go 项目开发进程
  go test <项目>                             执行 go test ./...
  go shell <项目>                            进入 Go 容器
  go logs <项目>                             查看 Go 容器日志
  go stop <项目>                             停止 Go 项目容器
  go env <项目>                              查看 Go 容器环境

  nginx install [--port 端口]                安装 Nginx (固定使用 nginx:alpine)
  nginx port set <新端口>                     修改 Nginx 端口
  nginx reload                               重载配置
  nginx uninstall                            卸载 Nginx（保留配置）

  site add <域名> --php <版本>                创建站点
  site switch <域名> --php <版本>             切换站点的 PHP 版本
  site list                                  列出所有站点
  site remove <域名>                         删除站点

  hosts add <域名>                           添加 hosts 解析
  hosts remove <域名>                        移除 hosts 解析
  hosts list                                 查看 hosts 状态

  backup                                     备份所有数据
  restore <备份文件> [-y]                   恢复数据（-y 非交互确认）

  list                                       列出所有已安装服务

环境变量 (.env):
  WWW_ROOT        网站根目录（默认 ~/www）
  MYSQL_DATA_ROOT MySQL 数据主目录（默认$HOME/mysql-data）
  MYSQL_80_ROOT_PASSWORD  预设 MySQL 8.0 的 root 密码（安装前写入 .env 即生效，键名规则 MYSQL_<去点版本>_ROOT_PASSWORD，未预设则自动生成）
  PHP_DEFAULT_EXTENSIONS  PHP 默认安装的扩展集（php install 不带 --ext 时生效，逗号分隔）
  REDIS_<去点版本>_ROOT_PASSWORD  Redis 认证密码（redis install 自动生成并保存）
  APK_MIRRORS     Alpine 镜像源兜底列表（空格分隔；使用前自动测速按最快优先下载，超时自动切换）
  APK_TIMEOUT     镜像源网络超时秒数（默认 30；测速/索引获取/下载无响应判定共用）
  BUILD_PROXY     PHP 构建代理（auto=自动探测本地代理，默认；none=禁用；或直接指定 host:port）
  GO_PROJECTS_ROOT Go 项目扫描目录（默认 ~/www）
  GO_DEFAULT_VERSION Go 默认镜像版本（默认 alpine，最新稳定版）
  GO_PROXY        Go 模块代理（默认 https://goproxy.cn,direct）
  GO_CACHE_ROOT   Go GOPATH 缓存根目录（默认 ~/phpbox/cache/go）
  其他变量请查看 .env 文件

示例:
  phpbox php install 8.4 --ext gd,redis
  phpbox mysql install 8.0 --port 3307
  phpbox nginx install --port 8080
  phpbox site add demo.test --php 8.4
  phpbox hosts add demo.test
  phpbox list
HELPEOF
}

# 全局服务列表
cmd_list() {
  # docker --format 里要嵌 Shell 变量，用的是"关引号-插值-再开引号"拼接：
  # 单引号段是字面模板；中间 "'"${VAR}"'" 处引号临时关闭、插入变量值、再恢复单引号。
  # {{.Names}}/{{.Label}} 是 Go 模板占位符，\t 是制表符分列
  docker ps -a --filter "label=${PROJECT_NAME}${LABEL_SEPARATOR}service" --format \
    'table {{.Names}}\t{{.Label "'"${PROJECT_NAME}${LABEL_SEPARATOR}"'service"}}\t{{.Label "'"${PROJECT_NAME}${LABEL_SEPARATOR}"'version"}}\t{{.Ports}}\t{{.Status}}'
}

# Docker daemon 预检：依赖容器运行时的命令先过这一关（实现见 lib/common/docker.sh 的 require_docker）。
# 不预检的话 daemon 不在场会藏在深处的误导性报错里（如 nginx 的"配置验证失败"），
# 或产生 uninstall 假成功（compose down 静默失败但 yml 被删）。
# 豁免：help/hosts（不碰 docker）、site list（纯文件读取）、未知命令（应报"未知命令"而非 docker 错）
case "${1:-help}" in
    php|mysql|redis|nginx|backup|restore|list)
        require_docker
        ;;
    go)
      case "${2:-help}" in
        help|-h|--help) ;;
        *) require_docker ;;
      esac
      ;;
    site)
      [ "${2:-}" = "list" ] || require_docker
      ;;
esac

case "${1:-help}" in
    php)     shift; cmd_php "$@" ;;
    mysql)   shift; cmd_mysql "$@" ;;
    redis)   shift; cmd_redis "$@" ;;
    go)      shift; cmd_go "$@" ;;
    nginx)   shift; cmd_nginx "$@" ;;
    site)    shift; cmd_site "$@" ;;
    hosts)   shift; cmd_hosts "$@" ;;
    backup)  shift; cmd_backup "$@" ;;
    restore) shift; cmd_restore "$@" ;;
    list)    cmd_list ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "未知命令: $1，使用 '$CMD_NAME help' 查看帮助"
        exit 1
        ;;
esac
