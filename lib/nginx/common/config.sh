#!/bin/bash
# shellcheck shell=bash
# Nginx compose 分片、主配置与站点注入（搬运自 lib/nginx.sh，纯迁移无逻辑改动）
# SITES_* 常量在原文件重复定义两次（值相同），此处收敛为单处定义，行为零变化

# 站点配置在容器内的挂载点：刻意与 Nginx 版本解耦——无论用 nginx:alpine 还是其它 tag，
# 站点一律放 config/nginx/sites/，每个站点一个 <域名>.conf，由主配置统一 include
SITES_MOUNT_PATH="/etc/nginx/sites"
SITES_INCLUDE_LINE="include ${SITES_MOUNT_PATH}/*.conf;"

# 幂等地把站点目录 include 写进任意版本的 nginx.conf，保证"多站点共用一个 sites 目录"。
# 1) 先剔除历史注入行（任意缩进、任意 sites 路径写法），否则重复 include 会让每个站点的
#    server 块被加载两次，nginx -t 直接报 duplicate server name；
# 2) 再把唯一权威写法插到 http{} 内：紧跟 conf.d 的 include 之后（保留镜像自带 default
#    server 的优先语义），没有 conf.d 时退回紧跟 http{ ；
# 3) 幂等：对同一份配置反复执行结果不变，切换/重装 Nginx 版本不会累积脏行。
_nginx_inject_sites_include() {
  local conf=$1
  [ -f "$conf" ] || error "Nginx 主配置不存在: $conf"
  local stripped="$conf.pbox.tmp"

  # 清理范围限定在"路径中含 sites 目录"的 include（sites/、sites-enabled/、legacy-sites/…），
  # 不碰 mime.types、conf.d 等无关行；历史写法若不清干净，站点 server 块会被加载两次
  # grep 无匹配时返回 1，set -e 下必须 || true（结果为空文件也是合法的）
  grep -vE '^[[:space:]]*include[[:space:]]+[^;]*sites[^;]*\*\.conf;[[:space:]]*$' "$conf" > "$stripped" || true

  # awk 惯用法：命中锚点行后先原样打印、再追加 include，next 结束本行处理；
  # 末尾的 "1" 是恒真条件，对其余行执行默认动作（打印）——即逐行原样输出。
  # done 标志保证只注入一次（配置里可能出现多行 include）
  if grep -qE '^[[:space:]]*include[[:space:]]+/etc/nginx/conf\.d/[^;]*;' "$stripped"; then
    awk -v inc="    ${SITES_INCLUDE_LINE}" '
      /^[[:space:]]*include[[:space:]]+\/etc\/nginx\/conf\.d\/[^;]*;/ {
        print; if (!done) { print inc; done=1 } next
      }
      1
    ' "$stripped" > "$conf"
  else
    awk -v inc="    ${SITES_INCLUDE_LINE}" '
      /http[[:space:]]*{/ { print; if (!done) { print inc; done=1 } next }
      1
    ' "$stripped" > "$conf"
  fi
  rm -f "$stripped"

  grep -qF "${SITES_INCLUDE_LINE}" "$conf" || error "未能向 $(basename "$conf") 注入站点目录 include"
}

# 从指定版本的 nginx 镜像拷出默认配置，并注入站点目录 include
_init_nginx_config() {
  local dir=$1 ver=$2
  docker run --rm -v "$dir":/out "nginx:${ver}" \
    sh -c "cp -r /etc/nginx/conf.d /out/ && cp /etc/nginx/nginx.conf /out/" || {
    rm -rf "$dir"; error "Nginx 配置提取失败"
  }
  _nginx_inject_sites_include "$dir/nginx.conf"
}

# 取 Nginx 实际生效的版本 tag：优先读已安装 nginx-default.yml 里记录的镜像 tag，
# 读不到（未安装）才回退 .env 的 NGINX_VERSION。
# 关键场景：.env 改了 NGINX_VERSION 但尚未重装时，运行中的容器与配置仍是旧版本；
# 若按 .env 校验会挂错目录——docker -v 遇到不存在的宿主路径还会自动建出空目录
# （复现"nginx.conf 是个目录"的幽灵路径），并报出与真实原因无关的验证错误
_nginx_effective_version() {
  local yml="$EXT_DIR/nginx-default.yml" ver=""
  if [ -f "$yml" ]; then
    ver=$(sed -n 's/^[[:space:]]*image:[[:space:]]*nginx://p' "$yml" | head -n1)
    ver="${ver//[[:space:]]/}"
  fi
  echo "${ver:-${NGINX_VERSION:-alpine}}"
}

# 用一次性容器校验 nginx 配置（sites 目录一并挂入）；输出/返回码由调用方处理
_nginx_validate() {
  local ver; ver=$(_nginx_effective_version)
  # 三个平级挂载，与 _nginx_generate_compose 的服务挂载一致。不能把整个版本目录
  # 挂成 /etc/nginx:ro 再嵌套挂 sites：父挂载只读时 Docker 无法 mkdirat 嵌套挂载点
  # （报 read-only file system），且 sites/ 在提取出的配置里本就不存在
  # 不加 --user：与 compose 里的真实服务一致以 root 运行。nginx -t 会尝试打开
  # pid 文件（/run/nginx.pid）验证可写，非 root 在该路径必因权限失败导致误报
  docker run --rm \
    -v "$CONFIG_DIR/nginx/${ver}/nginx.conf":/etc/nginx/nginx.conf:ro \
    -v "$CONFIG_DIR/nginx/${ver}/conf.d":/etc/nginx/conf.d:ro \
    -v "$CONFIG_DIR/nginx/sites":${SITES_MOUNT_PATH}:ro \
    "nginx:${ver}" nginx -t
}

_nginx_generate_compose() {
  # 版本由 .env 的 NGINX_VERSION 决定（默认 alpine）；版本只影响主配置与 conf.d 的目录，
  # 站点目录恒为 config/nginx/sites，切换版本不会动到任何站点
  local ver="${NGINX_VERSION:-alpine}"
  local yml="$EXT_DIR/nginx-default.yml"

  init_config_files "nginx" "$ver"

  # 配置已存在时 init_config_files 会跳过重建，这里再跑一次幂等注入：
  # 旧版把 sites include 插在 http{ 首行（mime.types 之前），此处统一规范化到 conf.d 之后
  local conf="$CONFIG_DIR/nginx/${ver}/nginx.conf"
  if [ -f "$conf" ]; then
    _nginx_inject_sites_include "$conf"
  fi

  cat > "$yml" <<YEOF
services:
  nginx:
    image: nginx:${ver}
    container_name: nginx
    ports:
      - "\${NGINX_PORT}:80"
    volumes:
      - \${WWW_ROOT}:/var/www:ro
      - ./config/nginx/${ver}/conf.d:/etc/nginx/conf.d:ro
      - ./config/nginx/${ver}/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./config/nginx/sites:${SITES_MOUNT_PATH}:ro
      - ./logs/nginx:/var/log/nginx:rw
    networks:
      - net
    restart: unless-stopped
    labels:
      - "${PROJECT_NAME}${LABEL_SEPARATOR}service=nginx"
      - "${PROJECT_NAME}${LABEL_SEPARATOR}version=${ver}"
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1/"]
      interval: 10s
      timeout: 5s
      retries: 5
YEOF
}
