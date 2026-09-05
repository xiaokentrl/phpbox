#!/bin/bash
# shellcheck shell=bash

_php_get_extensions_file() {
  local ver=$1
  echo "$STATE_DIR/php-${ver//./}-extensions.env"
}

_php_read_extensions() {
  local ver=$1
  local f="$(_php_get_extensions_file "$ver")"
  if [ -f "$f" ]; then
    # 清洗流水线：去注释行 → 去空行 → 去掉 "KEY=" 前缀 → 再去空行 →
    # 按逗号拆行排序去重 → 重新拼回逗号串（最终输出形如 gd,redis）
    grep -v '^#' "$f" | grep -v '^$' | sed 's/^[A-Za-z_][A-Za-z0-9_]*=//' | grep -v '^$' | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//'
  else
    echo ""
  fi
}

_php_write_extensions() {
  local ver=$1 exts=$2
  local f="$(_php_get_extensions_file "$ver")"
  echo "# PHP ${ver} 扩展列表（逗号分隔）" > "$f"
  echo "PHP_EXTENSIONS=${exts}" >> "$f"
}

_php_validate_extensions() {
  local exts="$1"
  local IFS=,   # 把分词符设为逗号：下面的 for 直接按逗号逐项遍历 $exts
  for ext in $exts; do
    # 白名单字符集：扩展名会被拼进 Dockerfile，禁止空格/分号等注入字符。
    # 允许点号：install-php-extensions 的版本钉住语法（如 apcu-5.1.27）需要
    if ! [[ "$ext" =~ ^[a-zA-Z0-9._-]+$ ]]; then
      error "无效扩展名: $ext"
    fi
  done
}

# 探测构建可用的 HTTP 代理。背景：网络受限环境下 pecl.php.net 的 IPv4 被间歇性重置
# （宿主机可能仅 IPv6 可达），而构建容器没有 IPv6 出口，也无法直达宿主 loopback 上的
# 本地代理。关键教训：直连"单次探测通过"不代表构建期间稳定——一次构建会发起大量
# 连接，任一被重置即失败。因此探测策略是代理优先：本地存在能通 pecl 的代理就走代理，
# 只有探测不到代理时才直连（构建失败时由报错信息引导配置 BUILD_PROXY）。
# 输出：代理 URL（stdout）；未探测到输出空串（走直连）
_php_detect_build_proxy() {
  command -v curl &>/dev/null || return 0
  local port attempt
  for port in 10809 7890 8118 1087 1080 8888; do
    # -f：代理返回 4xx/5xx 也视为不可用（如仅 SOCKS 的端口对 HTTP 代理请求会报 400）；
    # 每端口重试一次：探测连接可能与代理上残留的连接竞争而瞬断，单次失败不足以判死
    for attempt in 1 2; do
      if curl -4 -s -f --connect-timeout 3 --max-time 6 -x "http://127.0.0.1:$port" -o /dev/null https://pecl.php.net/channel.xml 2>/dev/null; then
        echo "http://127.0.0.1:$port"
        return 0
      fi
    done
  done
  return 0
}

# pecl 远端模块清单：这些扩展的源码包不在 php 源码树里，需从 pecl.php.net 下载。
# 其余扩展（gd/zip/pgsql 等）是"内置模块"，IPE 用镜像内 PHP 源码离线编译，不依赖网络
_PHP_PECL_REMOTE_EXTS="imagick xdebug redis"
_PECL_STAGED=""   # 本次构建暂存（尚未验证）的 pecl 包名，构建成功后才晋升进备份库
_APK_STAGED=""    # 本次构建暂存（尚未验证）的 apk 闭包包名列表，同上

# pecl 源码包下载地址。新版扩展会放弃旧 PHP（imagick 3.8 起要求 PHP ≥ 8.0、
# xdebug 最新版要求 PHP ≥ 8.0——7.4 上报 "requires PHP (version >= 8.0.0)"），
# 对不兼容的组合钉住仍支持的旧版本，避免 pecl 拉到最新版后在依赖检查上直接失败
_php_pecl_tarball_url() {
  local ext=$1 ver=$2
  case "$ext" in
    imagick) case "$ver" in 7.*) echo "https://pecl.php.net/get/imagick-3.7.0.tgz"; return ;; esac ;;
    xdebug)  case "$ver" in 7.*) echo "https://pecl.php.net/get/xdebug-3.1.6.tgz"; return ;; esac ;;
  esac
  echo "https://pecl.php.net/get/$ext"
}

# 宿主机侧暂存 pecl 源码包到构建上下文：优先命中离线备份库
# （offline/php/<版本>/pecl/，服务→版本→分类三层，人工整理不会混放），未命中才经
# 宿主代理下载并暂存。暂存 ≠ 入库：包是否可用要等构建验证（见 _php_promote_pecl_tarballs），
# 备份库里因此只会有验证成功的包。手动放入官网 tgz（按"扩展-版本.tgz"命名到对应版本目录）
# 视为用户自证可用，直接命中
_php_stage_pecl_tarballs() {
  local ver=$1 remote_list=$2 build_dir=$3
  local dest="$build_dir/php-exts"
  local backup_dir="$OFFLINE_DIR/php/$ver/pecl"
  mkdir -p "$backup_dir" "$dest"
  local proxy="${BUILD_PROXY:-auto}"
  if [ "$proxy" = "auto" ]; then proxy=$(_php_detect_build_proxy); fi
  local curl_args=()
  if [ -n "$proxy" ] && [ "$proxy" != "none" ]; then curl_args+=(-x "$proxy"); fi

  _PECL_STAGED=""
  local ext url fname tmp
  for ext in $remote_list; do
    url=$(_php_pecl_tarball_url "$ext" "$ver")
    tmp=$(mktemp)
    # -L 跟随 /get/<ext> 的版本跳转，url_effective 即最终带版本号的 URL，取其文件名做备份键
    if ! curl -fsSL -S --retry 2 --connect-timeout 8 -o "$tmp" -w '%{url_effective}' \
      "${curl_args[@]}" "$url" > "$tmp.url"; then
      rm -f "$tmp" "$tmp.url"
      _php_discard_staging "$build_dir"
      error "pecl 包 $ext 预下载失败（检查网络或 .env 的 BUILD_PROXY）"
    fi
    fname=$(basename "$(cat "$tmp.url")")
    rm -f "$tmp.url"
    [[ "$fname" == *.tgz ]] || fname="$ext.tgz"   # 无跳转时拿不到版本号，退回旧命名
    if [ -f "$backup_dir/$fname" ]; then
      log "pecl 备份命中: $fname"
      rm -f "$tmp"
      cp "$backup_dir/$fname" "$dest/$fname"
    else
      mv "$tmp" "$dest/$fname"
      log "pecl 包已暂存（构建成功后入备份库）: $fname"
      _PECL_STAGED="$_PECL_STAGED $fname"
    fi
  done
  _PECL_STAGED="${_PECL_STAGED# }"
}

# 构建成功 = 暂存包在本 PHP 版本上编译与启用全部通过：晋升进备份库供以后直接复用。
# 构建失败的路径不会走到这里，暂存包随构建目录清理而消失——备份库永远不收验证失败的包
_php_promote_pecl_tarballs() {
  local ver=$1 dest=$2
  [ -n "$_PECL_STAGED" ] || return 0
  local backup_dir="$OFFLINE_DIR/php/$ver/pecl"
  mkdir -p "$backup_dir"
  local fname
  for fname in $_PECL_STAGED; do
    cp "$dest/$fname" "$backup_dir/$fname"
    log "已验证入备份库: offline/php/$ver/pecl/$fname"
  done
  _PECL_STAGED=""
}

# 宿主机侧暂存 apk 依赖闭包到构建上下文：优先命中按版本隔离的备份库
# （offline/php/<版本>/apk/，整批对应一个 PHP 版本，构建成功后才入库），未命中时
# 借助与目标镜像同源的辅助容器 apk fetch --recursive 预取（与构建走同一镜像源和 DNS 注入）。
# 预取失败仅返回 1 由调用方降级为在线安装路径，不会中断安装
_php_stage_apk_closure() {
  local ver=$1 deps=$2 dest=$3
  local backup_dir="$OFFLINE_DIR/php/$ver/apk"
  _APK_STAGED=""
  mkdir -p "$dest"
  if [ -n "$(ls -A "$backup_dir" 2>/dev/null)" ]; then
    log "apk 离线闭包命中（$(ls "$backup_dir" | wc -l) 个包）"
    cp "$backup_dir"/*.apk "$dest/"
    return 0
  fi
  local mirror="${APK_MIRROR:-https://mirrors.aliyun.com}"
  local addhost=()
  mapfile -t addhost < <(_php_mirror_host_args "$mirror")
  log "预取 apk 离线闭包（$ver，$(wc -w <<<"$deps") 个包）..."
  if ! docker run --rm "${addhost[@]}" -e APK_MIRROR="$mirror" -v "$dest":/pkgs \
      "php:${ver}-fpm-alpine" sh -c '
        sed -i "s|https://dl-cdn.alpinelinux.org|$APK_MIRROR|g; s|http://dl-cdn.alpinelinux.org|$APK_MIRROR|g" /etc/apk/repositories
        apk fetch --recursive -o /pkgs shadow curl $PHPIZE_DEPS '"$deps"' >/dev/null
      '; then
    log "警告：apk 离线闭包预取失败，本次构建降级为在线安装"
    rm -rf "$dest"
    return 1
  fi
  _APK_STAGED=$(ls "$dest")
  if [ -z "$_APK_STAGED" ]; then
    log "警告：apk 离线闭包预取结果为空，本次构建降级为在线安装"
    rm -rf "$dest"
    return 1
  fi
  return 0
}

# 构建成功 = 闭包在本 PHP 版本上安装/编译全部通过：整批晋升进备份库，下次构建离线可用
_php_promote_apk_closure() {
  local ver=$1 dest=$2
  [ -n "$_APK_STAGED" ] || return 0
  local backup_dir="$OFFLINE_DIR/php/$ver/apk"
  mkdir -p "$backup_dir"
  cp "$dest"/*.apk "$backup_dir/"
  log "apk 离线闭包已验证入备份库: offline/php/$ver/apk/（$(ls "$backup_dir" | wc -l) 个包）"
  _APK_STAGED=""
}

# 渲染 Dockerfile（独立成函数便于测试断言）。参数分工：
#   bundled  内置模块名列表（逗号分隔，IPE 离线编译）
#   remote   预下载的本地 tarball 文件名列表（空格分隔，可能为空）
# heredoc 内的 $ 分工：
#   $bundled / ${bundled//,/ }  生成时展开：逗号换空格变成多个参数
#   \$APK_MIRROR / \${UID}      写入字面量，真正取值发生在 docker build 时（ARG）
# 各扩展的 apk 编译期依赖映射（"扩展:包,包"，空格分隔多个映射；包名跨 alpine 版本稳定）。
# 全部扩展的依赖一次性装进独立 RUN 层并缓存：失败重试/重建不再重复下载数百 MiB；
# 映射未覆盖的依赖由 IPE 按名自行安装（网络路径照旧），此处缺失只会变慢不会失败
_PHP_BUILD_BASE_APK_DEPS="musl-dev linux-headers pkgconf re2c"
_PHP_EXT_APK_DEPS="gd:libpng-dev,libjpeg-turbo-dev,freetype-dev intl:icu-dev zip:libzip-dev pgsql:libpq-dev pdo_pgsql:libpq-dev soap:libxml2-dev imagick:imagemagick-dev"

_php_ext_apk_deps() {
  local names=${1//,/ } ext pair out="$_PHP_BUILD_BASE_APK_DEPS"
  for ext in $names; do
    for pair in $_PHP_EXT_APK_DEPS; do
      case "$pair" in "$ext:"*) out="$out ${pair#*:}" ;; esac
    done
  done
  echo "$out" | tr ',' ' ' | tr -s ' '
}

_php_render_dockerfile() {
  local ver=$1 bundled=$2 remote_files=$3 offline=$4
  # pecl 本地安装块：COPY 与安装循环必须成对出现——两条渲染路径（在线/离线）都要带上
  local pecl_block=""
  if [ -n "$remote_files" ]; then
    pecl_block="COPY php-exts/ /tmp/php-exts/
RUN for t in /tmp/php-exts/*.tgz; do [ -e \"\$t\" ] || { echo \"ERROR: /tmp/php-exts/ 下没有 .tgz 包\"; exit 1; }; pecl install \"\$t\" && docker-php-ext-enable \"\$(basename \"\$t\" .tgz | sed 's/-[0-9][0-9.]*\$//')\" || exit 1; done"
  fi
  local apk_deps; apk_deps=$(_php_ext_apk_deps "$bundled,${remote_files//.tgz/}")
  local body=""
  if [ "$offline" = "1" ]; then
    # 离线：apk 依赖闭包 + 官方 docker-php-ext-install，全程零网络（连 IPE 二进制都不拉取）。
    # gd 需要 freetype/jpeg/webp 支持时官方默认配置不带，显式传参补齐
    local configure_gd=""
    case ",$bundled," in *,gd,*) configure_gd="docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp && " ;; esac
    local bundled_install=""
    if [ -n "$bundled" ]; then
      bundled_install="RUN $configure_gd docker-php-ext-install -j\"\$(nproc)\" ${bundled//,/ }"
    fi
    body="COPY php-pkgs/ /tmp/php-pkgs/
$pecl_block
RUN apk add --no-network /tmp/php-pkgs/*.apk
$bundled_install"
  else
    body="RUN apk add --no-cache shadow curl
COPY --from=mlocati/php-extension-installer:2 /usr/bin/install-php-extensions /usr/local/bin/
RUN apk add --no-cache \$PHPIZE_DEPS $apk_deps
$pecl_block
# 重试一次兜底：受限网络下连接被重置是随机的，IPE 幂等可安全重跑（已装扩展会跳过）
RUN if [ -n \"$bundled\" ]; then install-php-extensions ${bundled//,/ } || install-php-extensions ${bundled//,/ }; fi"
  fi
  cat <<DEOF
FROM php:${ver}-fpm-alpine
ARG UID=1000
ARG GID=1000
# APK_MIRROR：替换 Alpine 官方 CDN（国内网络对其极不稳定），如 https://mirrors.aliyun.com
ARG APK_MIRROR=
RUN if [ -n "\$APK_MIRROR" ]; then sed -i "s|https://dl-cdn.alpinelinux.org|\$APK_MIRROR|g; s|http://dl-cdn.alpinelinux.org|\$APK_MIRROR|g" /etc/apk/repositories; fi
# 依赖与源码包全部来自宿主机侧本地备份（offline/apk、offline/pecl），构建不依赖容器内网络
$body
RUN usermod -u \${UID} www-data && groupmod -g \${GID} www-data
DEOF
}

# 归一化代理地址并改写为构建容器可达的宿主地址，stdout 输出最终值。
# 原生 docker 的构建容器里 host.docker.internal 默认不解析（Desktop VM 才内置该域名），
# 换引擎后 pecl 全部死于 DNS；直接改用 docker0 网关 IP（容器内零 DNS 可达），
# 取不到再退回域名并由 build_args 的 --add-host host-gateway 兜底
_php_resolve_build_proxy() {
  local proxy=$1
  case "$proxy" in
    http://*|https://*) : ;;
    *) proxy="http://${proxy}" ;;
  esac
  local proxy_gw=$(ip -4 addr show docker0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
  if [ -n "$proxy_gw" ]; then
    proxy="${proxy//127.0.0.1/$proxy_gw}"
    proxy="${proxy//localhost/$proxy_gw}"
  else
    proxy="${proxy//127.0.0.1/host.docker.internal}"
    proxy="${proxy//localhost/host.docker.internal}"
  fi
  echo "$proxy"
}

# 解析 BUILD_PROXY 为容器可达的最终代理地址，stdout 输出（none 或 http://URL）。
# none=禁用；auto（默认）=探测本地常见代理端口；其余按显式值（host:port 或完整 URL）。
# 原生 docker 的构建容器里 host.docker.internal 默认不解析（Desktop VM 才内置该域名），
# 换引擎后 pecl 全部死于 DNS：代理指向本机时改写为 docker0 网关 IP（容器内零 DNS 可达），
# 取不到再退回域名，并由调用方的 --add-host host-gateway 兜底
_php_resolve_build_proxy() {
  local proxy="${BUILD_PROXY:-auto}"
  if [ "$proxy" = "auto" ]; then proxy=$(_php_detect_build_proxy); fi
  if [ -z "$proxy" ] || [ "$proxy" = "none" ]; then echo "none"; return 0; fi
  case "$proxy" in
    http://*|https://*) : ;;
    *) proxy="http://${proxy}" ;;
  esac
  local proxy_gw=$(ip -4 addr show docker0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
  if [ -n "$proxy_gw" ]; then
    proxy="${proxy//127.0.0.1/$proxy_gw}"
    proxy="${proxy//localhost/$proxy_gw}"
  else
    proxy="${proxy//127.0.0.1/host.docker.internal}"
    proxy="${proxy//localhost/host.docker.internal}"
  fi
  echo "$proxy"
}

# 把逗号分隔的扩展列表拆成 内置/远端 两组（写入全局 _SPLIT_BUNDLED/_SPLIT_REMOTE 供调用方读取）
_php_split_ext_list() {
  local exts=$1 ext
  _SPLIT_BUNDLED="" ; _SPLIT_REMOTE=""
  local IFS=,
  for ext in $exts; do
    case " $_PHP_PECL_REMOTE_EXTS " in
      *" $ext "*) _SPLIT_REMOTE="$_SPLIT_REMOTE $ext" ;;
      *) _SPLIT_BUNDLED="${_SPLIT_BUNDLED:+$_SPLIT_BUNDLED,}$ext" ;;
    esac
  done
  _SPLIT_REMOTE="${_SPLIT_REMOTE# }"
}

# 把镜像源域名按预解析 IP 输出为 --add-host 参数（两行：标志与值；无镜像源或解析失败输出空）。
# 容器内 DNS 对国内域名间歇性失败（DNS: transient error）且 apk 连接挂死无重试，跳过 DNS 可根治；
# /etc/hosts 在 buildkit 中只读，必须用 --add-host 而非 RUN echo
_php_mirror_host_args() {
  local apk_mirror=$1
  local host="${apk_mirror#*://}"; host="${host%%/*}"
  local ip=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}' || true)
  if [ -n "$ip" ]; then echo "--add-host"; echo "$host:$ip"; fi
}

# 构建失败时彻底删除两个暂存目录（pecl 包与 apk 闭包）：未验证的内容没有备份库正本、
# 命中副本的母本在备份库不受影响，留在磁盘上只是垃圾。暂存标记同步清空，防止后续误晋升
_php_discard_staging() {
  local build_dir=$1
  rm -rf "$build_dir/php-exts" "$build_dir/php-pkgs"
  _PECL_STAGED="" ; _APK_STAGED=""
}

# 执行镜像构建并收尾：成功→暂存包验证晋升入备份库（pecl + apk 闭包）；
# 失败→彻底删除全部暂存目录后报错退出。
# 二选一是刻意的：失败路径绝不晋升，保证备份库里只有对本 PHP 版本验证可用的内容
_php_docker_build_verified() {
  local img=$1 build_dir=$2 ver=$3
  shift 3
  local build_rc=0
  docker build -t "$img" "$@" "$build_dir" || build_rc=$?
  if [ $build_rc -ne 0 ]; then
    _php_discard_staging "$build_dir"
    error "PHP 镜像构建失败（网络受限时可在 .env 配置 BUILD_PROXY 指向本地 HTTP 代理）"
  fi
  _php_promote_pecl_tarballs "$ver" "$build_dir/php-exts"
  _php_promote_apk_closure "$ver" "$build_dir/php-pkgs"
}

# 在线路径的 docker build 参数（镜像源预解析注入、代理、no_proxy），stdout 每行一个参数。
# 代理缺省为 none（直连）；镜像源未配置时不注入，apk 走官方源
_php_online_build_args() {
  local proxy=$1 apk_mirror=$2
  if [ -n "$apk_mirror" ]; then
    local apk_mirror_host="${apk_mirror#*://}"; apk_mirror_host="${apk_mirror_host%%/*}"
    local apk_mirror_ip=$(getent ahostsv4 "$apk_mirror_host" 2>/dev/null | awk '{print $1; exit}' || true)
    if [ -n "$apk_mirror_ip" ]; then echo "--add-host"; echo "$apk_mirror_host:$apk_mirror_ip"; fi
  fi
  if [ -n "$proxy" ] && [ "$proxy" != "none" ]; then
    local no_proxy_host="${apk_mirror#*://}"; no_proxy_host="${no_proxy_host%%/*}"
    echo "--build-arg"; echo "http_proxy=$proxy"
    echo "--build-arg"; echo "https_proxy=$proxy"
    echo "--build-arg"; echo "no_proxy=127.0.0.1,localhost${no_proxy_host:+,$no_proxy_host}"
  fi
  # 兜底：让 host.docker.internal 在原生 docker 的构建容器内也能解析到宿主
  echo "--add-host"; echo "host.docker.internal:host-gateway"
}

_php_build_image() {
  local ver=$1 exts=$2
  local img="${IMAGE_PREFIX}php${ver//./}"
  local build_dir="$CONFIG_DIR/php/$ver"
  mkdir -p "$build_dir"

  _php_split_ext_list "$exts"
  local bundled=$_SPLIT_BUNDLED remote=$_SPLIT_REMOTE
  local deps_union; deps_union=$(_php_ext_apk_deps "$bundled,${remote//.tgz/}")

  local remote_files=""
  if [ -n "$remote" ]; then
    rm -rf "$build_dir/php-exts"
    mkdir -p "$build_dir/php-exts"
    _php_stage_pecl_tarballs "$ver" "$remote" "$build_dir"
    local tgz
    for tgz in "$build_dir"/php-exts/*.tgz; do
      remote_files="$remote_files $(basename "$tgz")"
    done
    remote_files="${remote_files# }"
  fi

  # apk 离线闭包：备份命中或预取成功 → 离线路径；预取失败 → 在线路径兜底
  local apk_mirror="${APK_MIRROR:-}" build_args=() offline=0
  mkdir -p "$build_dir/php-pkgs"
  if _php_stage_apk_closure "$ver" "$deps_union" "$build_dir/php-pkgs"; then offline=1; fi
  _php_render_dockerfile "$ver" "$bundled" "$remote_files" $offline > "$build_dir/Dockerfile"

  if [ "$offline" = "1" ]; then
    apk_mirror=""
    log "离线构建 PHP $ver：apk 闭包 $(ls "$build_dir/php-pkgs" | wc -l) 个包，pecl 包全部本地"
  else
    local proxy; proxy=$(_php_resolve_build_proxy)
    if [ "$proxy" != "none" ] && [ -z "$apk_mirror" ]; then apk_mirror="https://mirrors.aliyun.com"; fi
    mapfile -t build_args < <(_php_online_build_args "$proxy" "$apk_mirror")
    if [ "$proxy" != "none" ]; then log "在线构建 PHP $ver（流量经代理: $proxy）"; else log "在线构建 PHP $ver（直连）"; fi
  fi

  log "构建 PHP ${ver} 自定义镜像（扩展: ${exts:-无}）..."
  _php_docker_build_verified "$img" "$build_dir" "$ver" \
    --build-arg UID="$CURRENT_UID" \
    --build-arg GID="$CURRENT_GID" \
    --build-arg APK_MIRROR="$apk_mirror" \
    "${build_args[@]}"

  echo "$img"
}

_php_ensure_running() {
  local ver=$1
  local svc_key=$(get_service_key "php" "$ver")
  local yml="$EXT_DIR/php-${ver}.yml"
  if [ ! -f "$yml" ]; then
    _php_generate_compose "$ver"
  fi
  run_compose "php" "$ver" up -d "$svc_key"
  local cname=$(get_container_name "php" "$ver")
  local timeout=30
  while [ $timeout -gt 0 ]; do
    if docker exec "$cname" php-fpm -t &>/dev/null; then
      # 容器可能被重建（如 extension add/remove），刷新 nginx 的 upstream 连接
      nginx_try_reload
      return 0
    fi
    sleep 2
    timeout=$((timeout - 2))
  done
  error "PHP ${ver} 启动超时"
}

_php_generate_compose() {
  local ver=$1
  local svc_key=$(get_service_key "php" "$ver")
  local yml="$EXT_DIR/php-${ver}.yml"
  local exts="$(_php_read_extensions "$ver")"
  # local 与赋值拆开是刻意的：local 会吞掉命令替换的失败状态——镜像构建失败时必须
  # 让 set -e 在写 yml 之前中止，否则会生成 image 为空的坏 yml（compose 报 "image must be a string"）
  local image
  image="$(_php_build_image "$ver" "$exts")"

  # yml 里两种 $ 的分工：
  #   \${WWW_ROOT}   保留字面量，由 compose 运行时从 .env 解析（改 .env 即生效，无需重新生成）
  #   ./config/...   相对路径以 run_compose 传入的 --project-directory（即 BASE_DIR）为基准
  cat > "$yml" <<YEOF
services:
  $svc_key:
    image: $image
    container_name: $(get_container_name "php" "$ver")
    volumes:
      - \${WWW_ROOT}:/var/www
      - ./config/php/${ver}/php.ini:/usr/local/etc/php/php.ini:ro
      - ./logs/php:/var/log/php:rw
    networks:
      - net
    restart: unless-stopped
    labels:
      - "${PROJECT_NAME}${LABEL_SEPARATOR}service=php"
      - "${PROJECT_NAME}${LABEL_SEPARATOR}version=${ver}"
    healthcheck:
      test: ["CMD-SHELL", "php-fpm -t || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
YEOF
}

_php_cleanup_images() {
  local ver=$1
  local cname=$(get_container_name "php" "$ver")
  docker rm -f "$cname" 2>/dev/null || true
  local pattern="${IMAGE_PREFIX}php${ver//./}"
  # xargs -r：镜像 ID 列表为空时不执行后面的 rmi（否则 docker rmi 缺参数报错）
  docker images --filter "reference=${pattern}" -q 2>/dev/null | xargs -r docker rmi -f 2>/dev/null || true
}

_php_install() {
  local ver="${1:-}"
  [ -z "$ver" ] && error "用法: phpbox php install <版本> [--extensions 扩展列表]"
  validate_version "$ver"
  # 版本线守门：php:X-fpm-alpine 官方镜像只发布过 5.x / 7.x / 8.x
  [[ "$ver" == 5.* || "$ver" == 7.* || "$ver" == 8.* ]] || error "PHP 不存在 ${ver%%.*}.x 版本，可用版本线: 5.6 / 7.x / 8.x"
  shift

  local exts=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --extensions)
        [ $# -ge 2 ] || error "--extensions 需要指定扩展列表"
        exts="$2"; shift 2 ;;
      *) error "未知选项: $1" ;;
    esac
  done

  require_docker

  if [ -f "$EXT_DIR/php-${ver}.yml" ]; then
    error "PHP ${ver} 已安装，如需修改扩展请使用 'phpbox php extension add/remove'"
  fi
  _install_rollback_begin "php" "$ver"
  # 未指定 --extensions 时采用默认扩展集（.env 的 PHP_DEFAULT_EXTENSIONS 可覆盖）
  if [ -z "$exts" ]; then
    exts="$PHP_DEFAULT_EXTENSIONS"
  fi
  if [ -n "$exts" ]; then
    _php_validate_extensions "$exts"
    _php_write_extensions "$ver" "$exts"
  fi
  init_config_files "php" "$ver"
  _php_generate_compose "$ver"
  _php_ensure_running "$ver"
  _install_rollback_commit
  success "PHP ${ver} 安装完成"
}

_php_extension_op() {
  local sub="${1:-}"
  local ver="${2:-}"
  local ext="${3:-}"
  [ -z "$sub" ] && error "用法: phpbox php extension {add|remove} <版本> <扩展名>"
  [ -z "$ver" ] && error "请指定 PHP 版本"
  [ -z "$ext" ] && error "请指定扩展名"
  validate_version "$ver"
  [[ "$ver" == 5.* || "$ver" == 7.* || "$ver" == 8.* ]] || error "PHP 不存在 ${ver%%.*}.x 版本，可用版本线: 5.6 / 7.x / 8.x"
  _php_validate_extensions "$ext"

  # 幂等短路在前：已存在/不存在的扩展直接返回，不需要 daemon
  local current="$(_php_read_extensions "$ver")"
  local new_exts=""
  if [ "$sub" = "add" ]; then
    # 两端补逗号做整项匹配：查 "gd" 才不会误命中 "xgdx"
    if [[ ",$current," == *",$ext,"* ]]; then
      log "扩展 $ext 已存在"
      return
    fi
    new_exts="${current:+$current,}$ext"   # ${var:+x}：current 非空时展开为 "current内容,"，空则不加逗号
  elif [ "$sub" = "remove" ]; then
    # 同上整项匹配，此处 != 表示"列表里不存在该项"
    if [[ ",$current," != *",$ext,"* ]]; then
      log "扩展 $ext 不存在"
      return
    fi
    new_exts=$(echo "$current" | tr ',' '\n' | grep -v "^$ext$" | tr '\n' ',' | sed 's/,$//')
  else
    error "未知扩展操作: $sub (支持 add/remove)"
  fi

  require_docker

  _php_cleanup_images "$ver"
  rm -f "$EXT_DIR/php-${ver}.yml"
  _php_write_extensions "$ver" "$new_exts"
  _php_generate_compose "$ver"
  _php_ensure_running "$ver"
  success "PHP ${ver} 扩展已更新（${sub}: $ext）"
}

_php_show_list() {
  echo "已安装 PHP 版本:"
  for f in "$EXT_DIR"/php-*.yml; do
    [ -f "$f" ] || continue   # glob 无匹配时保持字面串，靠 -f 过滤掉
    local ver=$(basename "$f" .yml | sed 's/php-//')
    local cname=$(get_container_name "php" "$ver")
    local status=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo "不存在")
    local exts="$(_php_read_extensions "$ver")"
    printf "  %s  %s  (扩展: %s)\n" "$ver" "$status" "${exts:-无}"
  done
}

_php_uninstall() {
  local ver="${1:-}"
  local purge=false
  [ -z "$ver" ] && error "用法: phpbox php uninstall <版本> [--purge]"
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --purge) purge=true ;;
      *) error "未知选项: $1" ;;
    esac
    shift
  done

  if [ ! -f "$EXT_DIR/php-${ver}.yml" ]; then
    error "PHP ${ver} 未安装"
  fi

  log "卸载 PHP ${ver}"
  stop_and_remove_container "$(get_container_name "php" "$ver")"
  _php_cleanup_images "$ver"
  rm -f "$EXT_DIR/php-${ver}.yml"
  rm -f "$(_php_get_extensions_file "$ver")"
  if $purge && confirm_yes "是否删除配置目录 $CONFIG_DIR/php/$ver ?"; then
    rm -rf "$CONFIG_DIR/php/$ver"
  fi
  success "PHP ${ver} 已卸载"
}

# 仅做分发，实现见各 _php_* 函数
cmd_php() {
  case "${1:-help}" in
    install)   shift; _php_install "$@" ;;
    extension) shift; _php_extension_op "$@" ;;
    list)      _php_show_list ;;
    uninstall) shift; _php_uninstall "$@" ;;
    *) error "未知 php 操作: ${1:-help} (支持 install, extension, list, uninstall)" ;;
  esac
}
