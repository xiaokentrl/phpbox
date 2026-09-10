#!/bin/bash
# shellcheck shell=bash
# Docker 预检、Compose 通用调用与容器清理（搬运自 lib/common.sh，纯迁移无逻辑改动）

# Docker daemon 预检：所有需要与 daemon 交互的变更类命令必须先过这一关。
# 否则 daemon 未运行时，错误会以"配置验证失败/启动超时"等无关面目出现，极难排查；
# 更糟的是 nginx install 这类流程会先删旧实例、写 yml，失败后留下半安装状态
require_docker() {
  command -v docker &>/dev/null || error "未找到 docker 命令，请先安装 Docker"
  if ! docker info &>/dev/null; then
    error "Docker daemon 未运行（无法连接 docker API）。请先启动后重试：
  Linux:  sudo systemctl start docker
  其他:   service docker start / 打开 Docker Desktop"
  fi
}

# 停止并移除单个服务容器。不能借 compose down 卸载单个服务：down 会连带删除基础
# compose 文件里定义的共享网络——当其余服务的容器恰好都处于停止/崩溃状态时，网络因
# 无 endpoint 而被成功删除，之后所有引用旧网络的已停止容器 docker start 一律报
# "network not found"（重启宿主机也拉不起来），只能逐个 force-recreate 才能恢复。
# 先 docker stop 走优雅停机（MySQL 的 entrypoint 会清理 socket 并干净关库），
# docker rm -f 兜底删除已退出或不存在的容器
stop_and_remove_container() {
  local cname=$1
  docker stop "$cname" &>/dev/null || true
  docker rm -f "$cname" &>/dev/null || true
}

# ---- 半安装回滚 ----
# 删除可能已被容器内用户（如 mysql 的 999）接管的目录：宿主 rm 会因权限失败，
# 借容器内 root 兜底（与属主 chown 兜底同一思路）。回滚/卸载清理专用，失败不抛出
_rm_rf_with_docker_fallback() {
  local dir=$1
  rm -rf "$dir" 2>/dev/null && return 0
  [ -d "$dir" ] || return 0   # rm 虽报错但目标已不存在，视为成功
  docker run --rm -v "${dir%/*}":/parent alpine rm -rf "/parent/${dir##*/}" >/dev/null 2>&1 || true
}

run_compose() {
  local svc=$1 ver=$2; shift 2
  local service_file="$EXT_DIR/${svc}-${ver}.yml"
  if [ ! -f "$service_file" ]; then
    error "未找到服务 ${svc} ${ver} 的 Compose 配置文件"
  fi
  # 注意：不要使用 --remove-orphans——每个版本的服务文件只定义单个服务，
  # 该参数会把同 project 下所有其他服务（其他 PHP 版本/MySQL/Redis/Nginx）当作孤儿删除
  # 注意：Compose 把 yml 中相对路径按第一个 -f 文件所在目录解析，必须显式指定
  # --project-directory="$BASE_DIR"，service yml 中的挂载才能统一用 ./ 前缀
  docker compose -p "$PROJECT_NAME" --project-directory "$BASE_DIR" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -f "$service_file" "$@"
}

# 本地健康探测：绕过任何代理、固定 IPv4、单次限时。否则会话里的代理变量、
# localhost 解析到 IPv6 或挂起的连接都会让轮询循环整体超时误判
# （且 curl -s 连错误信息都吞掉，失败时看不到任何线索）
http_probe_ok() {
  curl -s --noproxy '*' --max-time 3 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$1" | grep -qE '200|301|302|404'
}
