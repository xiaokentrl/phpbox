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

# ---- 镜像离线事务（公共层：官方二进制镜像服务的 install/uninstall 共用）----
# 适用对象：不自定义构建镜像、直接用官方 tag 的服务（mysql:<版本>、redis:<版本>-alpine）。
# PHP 线不走这里：它是源码构建，离线缓存的是 APK/PECL 构建材料（lib/php/common/offline.sh）。
# 契约（与 PHP 线对齐，AGENTS.md §2.1.1）：offline/<服务>/<版本>/ 只收"验证过"的内容——
# 二进制镜像的验证 = 拉取成功 + 容器健康检查；回写 = 临时文件 + tar 可读校验 + 原子替换。

# 离线库路径：offline/<服务>/<版本>/<服务>-<版本>.tar
_image_offline_tar_path() {
  local svc=$1 ver=$2
  echo "$OFFLINE_DIR/$svc/$ver/$svc-$ver.tar"
}

# 镜像获取三段决策（公共入口，进度走 stderr，stdout 只输出镜像 tag）：
#   1. 镜像已在本地 → 直接返回（零操作）
#   2. 离线库命中 → docker load 零网络；load 后 tag 与期望不符 = 必须报错，
#      禁止让后续步骤静默联网拉取绕过离线契约
#   3. 都没有 → docker pull；mode=install 时拉取成功后回写离线库（尽力而为，
#      回写失败仅告警不中断安装）；mode=preload 只拉取不回写
# 参数：$1=服务名（离线库子目录）  $2=版本（离线库子目录，与 tag 后缀不一定相同：
#       redis:8-alpine 的版本是 8）  $3=镜像 tag（mysql:8.4 / redis:8-alpine）
#       $4=mode（install|preload）。拉取/回写共用 600s 总超时——覆盖 1GB 级镜像的
#       慢网络场景，redis/mysql 量级差异远小于该裕度，不为此加参数
_ensure_offline_image() {
  local svc=$1 ver=$2 image=$3 mode="${4:-install}"
  local host_timeout=600
  local tar_path; tar_path=$(_image_offline_tar_path "$svc" "$ver")

  if docker image inspect "$image" &>/dev/null; then
    log "${image} 镜像已存在，跳过获取"
    echo "$image"
    return 0
  fi

  if [ -f "$tar_path" ]; then
    log "${svc} 离线命中: $tar_path（零网络 docker load）"
    if ! docker load -i "$tar_path" 2>&1 | sed 's/^/  /' >&2; then
      error "${svc} 离线镜像加载失败: $tar_path（文件可能损坏，可删除后重试在线拉取）"
    fi
    # load 成功但 tag 不匹配是异常状态（tar 内容被换过/版本目录错放），必须拦下：
    # 不拦的话安装会继续走并在 up 时按 yml 里的 image: 重新联网拉取，静默绕过离线契约
    if ! docker image inspect "$image" &>/dev/null; then
      error "${svc} 离线镜像加载后未找到 ${image}（tar 内容与版本目录不匹配）"
    fi
    echo "$image"
    return 0
  fi

  log "${svc} 离线库未命中，在线拉取 ${image} ..."
  if ! timeout "$host_timeout" docker pull "$image" >&2; then
    error "${image} 拉取失败（检查网络；或手动放置镜像 tar 到 $tar_path 后重试）"
  fi

  if [ "$mode" = "install" ]; then
    _save_image_to_offline "$svc" "$image" "$tar_path" "$host_timeout"
  else
    log "预下载模式：不回写离线库（仅确认镜像可用）"
  fi
  echo "$image"
}

# 拉取成功后回写离线库：临时文件 + tar 可读校验 + 原子替换。
# 尽力而为：回写失败绝不中断安装（镜像本身已可用），只清理半成品不留垃圾
_save_image_to_offline() {
  local svc=$1 image=$2 tar_path=$3 host_timeout=$4
  local dir; dir=$(dirname "$tar_path")
  local tmp="${tar_path}.tmp.$$"
  mkdir -p "$dir"
  log "回写 ${svc} 镜像到离线库: $tar_path ..."
  if ! timeout "$host_timeout" docker save "$image" -o "$tmp" >&2; then
    rm -f "$tmp"
    log "警告：docker save 失败，本次不回写离线库（安装不受影响）"
    return 0
  fi
  # tar 可读性校验：save 中途被杀会留截断文件，load 时的报错信息很深，
  # 提前在这里拦下并清理
  if ! timeout 120 tar -tf "$tmp" &>/dev/null; then
    rm -f "$tmp"
    log "警告：镜像 tar 校验失败，已丢弃（安装不受影响）"
    return 0
  fi
  if ! mv "$tmp" "$tar_path"; then
    rm -f "$tmp"
    log "警告：离线库写入失败（$tar_path），已清理临时文件"
    return 0
  fi
  local size; size=$(du -h "$tar_path" | cut -f1)
  log "已验证入离线库: $tar_path（$size）"
}
