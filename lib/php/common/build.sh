#!/bin/bash
# shellcheck shell=bash

# PHP 镜像构建编排层（原 lib/build.sh 按职责拆分后保留的编排与渲染，优化切片 A）：
#   扩展依赖映射 → Dockerfile 渲染 → docker build → 成功调 offline.sh 晋升 / 失败调其丢弃。
# 三文件分工：build.sh=编排渲染，offline.sh=离线资产事务与下载代理，apk-fetch.sh=apk 容器下载器。
# 本模块只被 php 线的生命周期函数调用（_php_generate_compose → _php_build_image），
# 不直接对接 CLI；依赖方向：build.sh → lib/common 通用工具 + offline.sh + apk-fetch.sh，禁止反向。
# 函数保留 _php_ 前缀：这是"PHP 镜像"的构建，迁移到其他语言不适用

# 渲染 Dockerfile（独立成函数便于测试断言）。参数分工：
#   bundled  内置模块名列表（逗号分隔，IPE 离线编译）
#   remote   预下载的本地 tarball 文件名列表（空格分隔，可能为空）
# heredoc 内的 $ 分工：
#   $bundled / ${bundled//,/ }  生成时展开：逗号换空格变成多个参数
#   \$APK_MIRRORS / \${UID}     写入字面量，真正取值发生在 docker build 时（ARG）
# 各扩展的 apk 编译期依赖映射（"扩展:包,包"，空格分隔多个映射；包名跨 alpine 版本稳定）。
# 全部扩展的依赖一次性装进独立 RUN 层并缓存：失败重试/重建不再重复下载数百 MiB；
# 映射未覆盖的依赖由 IPE 按名自行安装（网络路径照旧），此处缺失只会变慢不会失败
_PHP_BUILD_BASE_APK_DEPS="musl-dev linux-headers pkgconf re2c"
_PHP_EXT_APK_DEPS="gd:libpng-dev,libjpeg-turbo-dev,freetype-dev,libwebp-dev,zlib-dev,libxpm-dev intl:icu-dev zip:libzip-dev pgsql:libpq-dev pdo_pgsql:libpq-dev soap:libxml2-dev imagick:imagemagick-dev"

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
  # COPY pecl 与 pecl 循环拆开维护：COPY 必须在依赖安装层之前，循环必须在之后
  local copy_exts="" pecl_loop=""
  if [ -n "$remote_files" ]; then
    copy_exts="COPY pecl/ /tmp/pecl/"
    # 零网络 pecl 安装：pecl install 对本地 tgz 仍会走 pear 的联网环节（实测 imagick
    # 编译完成后卡在拉 PHP-Parser，两次构建同点挂死），所以绕开 pecl 命令，直接
    # phpize/configure/make/make install——编译与安装（make install 仅拷 .so）均不触网，
    # docker-php-ext-enable 只写 ini 同样离线。三态等价于 pecl install 的最终产物
    pecl_loop="RUN set -e; for t in /tmp/pecl/*.tgz; do [ -e \"\$t\" ] || { echo \"ERROR: /tmp/pecl/ 下没有 .tgz 包\"; exit 1; }; d=\"/tmp/src/\$(basename \"\$t\" .tgz)\"; mkdir -p \"\$d\"; tar xzf \"\$t\" -C \"\$d\" --strip-components=1; (cd \"\$d\" && phpize && ./configure && make -j\"\$(nproc)\" && make install); docker-php-ext-enable \"\$(basename \"\$t\" .tgz | sed 's/-[0-9][0-9.]*\$//')\"; done"
  fi
  local apk_deps; apk_deps=$(_php_ext_apk_deps "$bundled,${remote_files//.tgz/}")
  local body=""
  if [ "$offline" = "1" ]; then
    # 离线：apk 依赖闭包 + 官方 docker-php-ext-install，全程零网络（连 IPE 二进制都不拉取）。
    # 顺序即正确性：工具链与系统依赖（apk add --no-network）先于一切编译。
    # gd 需要 freetype/jpeg/webp 支持时官方默认配置不带，显式传参补齐
    local configure_gd=""
    case ",$bundled," in *,gd,*) configure_gd="docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp --with-xpm && " ;; esac
    local bundled_install=""
    if [ -n "$bundled" ]; then
      bundled_install="RUN $configure_gd docker-php-ext-install -j\"\$(nproc)\" ${bundled//,/ }"
    fi
    body="COPY apk/ /tmp/apk/
$copy_exts
RUN apk add --no-network /tmp/apk/*.apk
$pecl_loop
$bundled_install"
  else
    body="RUN apk add --no-cache shadow curl
COPY --from=mlocati/php-extension-installer:2 /usr/bin/install-php-extensions /usr/local/bin/
RUN apk add --no-cache \$PHPIZE_DEPS $apk_deps
$copy_exts
$pecl_loop
# 重试一次兜底：受限网络下连接被重置是随机的，IPE 幂等可安全重跑（已装扩展会跳过）
RUN if [ -n \"$bundled\" ]; then install-php-extensions ${bundled//,/ } || install-php-extensions ${bundled//,/ }; fi"
  fi
  cat <<DEOF
FROM php:${ver}-fpm-alpine
ARG UID=1000
ARG GID=1000
# APK_MIRRORS：Alpine 镜像源列表（空格分隔，按序故障转移），值截取到 /alpine 含
ARG APK_MIRRORS="https://mirrors.aliyun.com/alpine https://dl-cdn.alpinelinux.org/alpine"
RUN cp /etc/apk/repositories /tmp/repos.orig && : > /etc/apk/repositories && \
  for m in \$APK_MIRRORS; do case "\$m" in */alpine) : ;; *) m="\$m/alpine" ;; esac; sed "s|https://dl-cdn.alpinelinux.org/alpine|\$m|g" /tmp/repos.orig >> /etc/apk/repositories; done
# 依赖与源码包全部来自宿主机侧本地备份（offline/apk、offline/pecl），构建不依赖容器内网络
$body
RUN usermod -u \${UID} www-data && groupmod -g \${GID} www-data
DEOF
}

# 执行镜像构建并收尾：成功→暂存包验证晋升入备份库（pecl + apk 闭包）；
# 失败→彻底删除全部暂存目录后报错退出。
# 二选一是刻意的：失败路径绝不晋升，保证备份库里只有对本 PHP 版本验证可用的内容
_php_docker_build_verified() {
  local img=$1 build_dir=$2 ver=$3 offline=$4
  shift 4
  local build_rc=0
  local build_timeout=3600
  log "Docker 构建开始：PHP ${ver}，超时 ${build_timeout}s，构建上下文: $build_dir"
  timeout --foreground "$build_timeout" docker build -t "$img" "$@" "$build_dir" || build_rc=$?
  if [ $build_rc -ne 0 ]; then
    _php_discard_staging "$build_dir"
    if [ $build_rc -eq 124 ]; then
      error "PHP 镜像构建超时（${build_timeout}s），已清理暂存；旧离线库保持不变"
    fi
    error "PHP 镜像构建失败（退出码: $build_rc；网络受限时可在 .env 配置 BUILD_PROXY 指向本地 HTTP 代理）"
  fi
  log "PHP ${ver} 镜像构建成功，开始晋升已验证的离线依赖..."
  if [ "$offline" = "1" ]; then
    _php_promote_apk_closure "$ver" "$build_dir/apk"
  else
    log "PHP ${ver} 未使用 APK 离线闭包，跳过 APK 备份库晋升"
  fi
  _php_promote_pecl_tarballs "$ver" "$build_dir/pecl"
  # 晋升完成后清空两个暂存目录：正本在备份库（offline/php/<版本>/），残留只是垃圾，
  # 且 config/php/<版本>/{pecl,apk} 会被 phpbox backup 经 CONFIG_DIR 卷入造成双份冗余。
  # 下次构建会从备份库重新复制，零损失
  rm -rf "$build_dir/pecl" "$build_dir/apk"
}

# 在线路径的 docker build 参数（镜像源预解析注入、代理、no_proxy），stdout 每行一个参数。
# 代理缺省为 none（直连）；镜像源未配置时不注入，apk 走官方源
_php_online_build_args() {
  local proxy=$1 apk_mirror=$2
  if [ -n "$apk_mirror" ]; then
    local apk_mirror_host="${apk_mirror#*://}"; apk_mirror_host="${apk_mirror_host%%/*}"
    local apk_mirror_ip
    apk_mirror_ip=$(getent ahostsv4 "$apk_mirror_host" 2>/dev/null | awk '{print $1; exit}' || true)
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
    rm -rf "$build_dir/pecl"
    mkdir -p "$build_dir/pecl"
    _php_stage_pecl_tarballs "$ver" "$remote" "$build_dir"
    local tgz
    for tgz in "$build_dir"/pecl/*.tgz; do
      remote_files="$remote_files $(basename "$tgz")"
    done
    remote_files="${remote_files# }"
  fi

  # apk 离线闭包：备份命中或预取成功 → 离线路径；预取失败 → 在线路径兜底。
  # apk 先清空重建：预取容器以 root 写入的历史残留会让宿主 cp 覆盖时权限不足
  local build_args=() offline=0
  rm -rf "$build_dir/apk"
  mkdir -p "$build_dir/apk"
  if _php_stage_apk_closure "$ver" "$deps_union" "$build_dir/apk"; then offline=1; fi
  _php_render_dockerfile "$ver" "$bundled" "$remote_files" $offline > "$build_dir/Dockerfile"

  if [ "$offline" = "1" ]; then
    log "离线构建 PHP $ver：apk 闭包 $(ls "$build_dir/apk" | wc -l) 个包，pecl 包全部本地"
  else
    local proxy; proxy=$(_php_resolve_build_proxy)
    mapfile -t build_args < <(_php_online_build_args "$proxy" "${APK_MIRRORS%% *}")
    if [ "$proxy" != "none" ]; then log "在线构建 PHP $ver（流量经代理: $proxy）"; else log "在线构建 PHP $ver（直连）"; fi
  fi

  log "构建 PHP ${ver} 自定义镜像（扩展: ${exts:-无}）..."
  _php_docker_build_verified "$img" "$build_dir" "$ver" "$offline" \
    --build-arg UID="$CURRENT_UID" \
    --build-arg GID="$CURRENT_GID" \
    --build-arg APK_MIRRORS="$APK_MIRRORS" \
    "${build_args[@]}"

  echo "$img"
}
