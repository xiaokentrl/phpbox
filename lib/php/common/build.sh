#!/bin/bash
# shellcheck shell=bash

# PHP 镜像构建管线：离线资产暂存/闭包预取/Dockerfile 渲染/构建验证/晋升。
# 本模块只被 php 线的生命周期函数调用（_php_generate_compose → _php_build_image），
# 不直接对接 CLI；依赖方向：build.sh → common.sh 的通用工具，禁止反向。
# 函数保留 _php_ 前缀：这是"PHP 镜像"的构建，迁移到其他语言不适用
# （整文件搬运自 lib/build.sh，纯迁移无逻辑改动）

# 探测构建可用的 HTTP 代理。背景：网络受限环境下 pecl.php.net 的 IPv4 被间歇性重置
# （宿主机可能仅 IPv6 可达），而构建容器没有 IPv6 出口，也无法直达宿主 loopback 上的
# 本地代理。关键教训：直连"单次探测通过"不代表构建期间稳定——一次构建会发起大量
# 连接，任一被重置即失败。因此探测策略是代理优先：本地存在能通 pecl 的代理就走代理，
# 只有探测不到代理时才直连（构建失败时由报错信息引导配置 BUILD_PROXY）。
# 探测必须用"构建容器视角"：本地代理（xray/v2rayN 等）常只监听 127.0.0.1，宿主侧直连
# 探测当然通，但容器经 docker0 网关访问不到——曾因此选中假可用代理，构建时
# connection refused。以 docker0 网桥 IP 探测（监听 0.0.0.0 才通，通即容器内可达），
# 输出即网桥地址，可直接用作构建期 http_proxy，无需再做地址换算
_php_detect_build_proxy() {
  command -v curl &>/dev/null || return 0
  local bridge attempt port
  bridge=$(ip -4 -o addr show docker0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
  bridge=${bridge:-172.17.0.1}
  for port in 10809 7890 8118 1087 1080 8888; do
    # -f：代理返回 4xx/5xx 也视为不可用（如仅 SOCKS 的端口对 HTTP 代理请求会报 400）；
    # 每端口重试一次：探测连接可能与代理上残留的连接竞争而瞬断，单次失败不足以判死
    for attempt in 1 2; do
      if curl -4 -s -f --connect-timeout 3 --max-time 6 -x "http://$bridge:$port" -o /dev/null https://pecl.php.net/channel.xml 2>/dev/null; then
        echo "http://$bridge:$port"
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
  local dest="$build_dir/pecl"
  local backup_dir="$OFFLINE_DIR/php/$ver/pecl"
  mkdir -p "$dest"
  log "pecl 备份库: $backup_dir → 构建目录: $dest"
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
      log "pecl 备份命中: $backup_dir/$fname → $dest/"
      rm -f "$tmp"
      cp "$backup_dir/$fname" "$dest/$fname"
    else
      mv "$tmp" "$dest/$fname"
      log "pecl 已下载暂存: $dest/$fname（源: $url，构建成功后晋升备份库）"
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
  local parent tmp old fname
  parent=$(dirname "$backup_dir")
  tmp="${backup_dir}.tmp.$$"
  old="${backup_dir}.old.$$"
  mkdir -p "$parent"
  rm -rf "$tmp" "$old"
  mkdir "$tmp"
  if [ -d "$backup_dir" ]; then
    cp "$backup_dir"/*.tgz "$tmp/" 2>/dev/null || true
  fi
  for fname in $_PECL_STAGED; do
    if [ ! -s "$dest/$fname" ]; then
      rm -rf "$tmp"
      error "PECL 晋升失败：暂存包不存在或为空（暂存: $dest/$fname，目标: $backup_dir/$fname）"
    fi
    cp "$dest/$fname" "$tmp/$fname" || {
      rm -rf "$tmp"
      error "PECL 晋升失败：无法复制暂存包（暂存: $dest/$fname）"
    }
  done
  if [ -e "$backup_dir" ]; then
    mv "$backup_dir" "$old" || {
      rm -rf "$tmp"
      error "PECL 晋升失败：无法保留旧备份库（目标: $backup_dir）"
    }
  fi
  if ! mv "$tmp" "$backup_dir"; then
    [ -e "$old" ] && mv "$old" "$backup_dir"
    rm -rf "$tmp"
    error "PECL 晋升失败：无法替换备份库（目标: $backup_dir）"
  fi
  for fname in $_PECL_STAGED; do
    log "已验证入备份库: $backup_dir/$fname"
  done
  rm -rf "$old"
  _PECL_STAGED=""
}

# apk 闭包预取：向空 root 全新安装，把"必然完整"的依赖闭包拉到 $dest。
# 公共实现见 common.sh 的 _apk_ranked_fetch_run（用前测速排序 + APK_TIMEOUT 秒无响应
# 自动切换下一个源）；此处只绑定 PHP 基础镜像与递归闭包模式
_php_apk_prefetch_run() {
  local ver=$1 deps=$2 dest=$3
  _apk_ranked_fetch_run "php:${ver}-fpm-alpine" "phpbox-apkfetch-${ver//./}" 2400 recursive "$dest" $deps
}

# 基础包同步：把基础镜像的全量包按当前镜像源版本补进暂存（钉死库版本与前进的镜像源
# 之间会 breaks，作用见调用方注释）。尽力而为：失败返回 1，由调用方仅告警
_php_apk_basesync_run() {
  local ver=$1 dest=$2
  _apk_ranked_fetch_run "php:${ver}-fpm-alpine" "phpbox-basesync-${ver//./}" 1800 installed "$dest"
}

# 闭包完整性校验：phpize 工具链的关键包必须都在（按文件名前缀匹配，如 autoconf-2.73.apk）。
# 缺失即预取/备份命中了一份残缺闭包，返回 1 由调用方降级在线路径——离线构建缺它必死于
# "Cannot find autoconf"
_php_apk_closure_verify() {
  local dest=$1 need missing=""
  for need in autoconf gcc g++ make pkgconf re2c musl-dev linux-headers file dpkg; do
    ls "$dest/${need}-"*.apk >/dev/null 2>&1 || missing="$missing $need"
  done
  if [ -n "$missing" ]; then
    log "apk 闭包缺少构建依赖:${missing}"
    return 1
  fi
}

# 宿主机侧暂存 apk 依赖闭包到构建上下文：优先命中按版本隔离的备份库
# （offline/php/<版本>/apk/，整批对应一个 PHP 版本，Docker 构建成功后才入库），未命中时
# 借助与目标镜像同源的辅助容器，向一个空 root 做一次"全新安装"——apk 只下载缺失的包，
# 直接 fetch 会跳过容器里已装的基础包导致闭包不完整；--initdb 的空 root 视为全未安装，
# 拉下的 .apk 集合因此必然完整，且"能装完"本身就是对闭包的验证。预取失败仅返回 1 由
# 调用方降级为在线安装路径，不会中断安装
_php_stage_apk_closure() {
  local ver=$1 deps=$2 dest=$3
  local backup_dir="$OFFLINE_DIR/php/$ver/apk"
  # 暂存目录可能残留 chown 修复之前由容器写入的 root 属主文件，宿主用户删不动，走容器兜底清空
  _rm_rf_with_docker_fallback "$dest"
  mkdir -p "$dest"
  log "apk 闭包备份库: $backup_dir → 构建目录: $dest"
  log "apk 镜像源（先测速排序，超时 $APK_TIMEOUT 秒自动切换）: $APK_MIRRORS"
  local hit=0
  if [ -n "$(ls -A "$backup_dir" 2>/dev/null)" ]; then
    log "apk 闭包命中: $backup_dir → $dest/（$(ls "$backup_dir" | wc -l) 个包）"
    cp "$backup_dir"/*.apk "$dest/"
    if _php_apk_closure_verify "$dest"; then
      hit=1
    else
      # 备份命中残缺集（如人工补包只补了一半）：不信任，重新预取，成功后自动覆盖备份库
      log "警告：备份库闭包残缺，忽略并重新预取"
      rm -rf "$dest"
      mkdir -p "$dest"
    fi
  fi
  if [ "$hit" = 0 ]; then
    log "apk 闭包预取: 宿主容器内 apk fetch → $dest/（$ver，$(wc -w <<<"$deps") 个包）"
    if ! _php_apk_prefetch_run "$ver" "$deps" "$dest"; then
      log "警告：apk 闭包预取失败，本次构建降级为在线安装（下次构建自动重试）"
      rm -rf "$dest"
      return 1
    fi
    if ! _php_apk_closure_verify "$dest"; then
      log "警告：预取闭包不完整，本次构建降级为在线安装"
      rm -rf "$dest"
      return 1
    fi
  fi
  # 基础包同步（重要）：基础镜像"钉死库版本"的包（openssl 等不在依赖闭包里），
  # 镜像源前进后其精确 pin 会与闭包里的新库 breaks——把基础镜像的全量包
  # 按当前镜像源版本补进暂存，离线安装时整个基础系统一起升级，版本重新对齐。
  # 离线场景此步会失败：容忍（未漂移时旧闭包仍可用；已漂移则需联网重试一次）
  if ! _php_apk_basesync_run "$ver" "$dest"; then
    log "警告：基础包同步失败（离线场景可忽略）；若构建报 breaks 版本冲突，请联网重试一次"
  fi
  # 暂存集 = 依赖闭包 + 基础镜像全量包（当前镜像源版本）= 可离线安装的一致状态。
  # 此处绝不写正式备份库，必须等 Docker 构建和扩展编译成功后再晋升。
  log "apk 闭包暂存完成: $dest/（$(find "$dest" -maxdepth 1 -name '*.apk' -type f | wc -l) 个包，构建成功后入备份库）"
  return 0
}

# Docker 构建成功后才晋升 APK 闭包。用临时目录组装完整集合，再替换正式目录，避免备份库
# 出现半套包或新旧版本混杂；构建失败路径不会调用此函数。
_php_promote_apk_closure() {
  local ver=$1 dest=$2
  local backup_dir="$OFFLINE_DIR/php/$ver/apk"
  local parent tmp old count size
  count=$(find "$dest" -maxdepth 1 -name '*.apk' -type f 2>/dev/null | wc -l)
  if [ "$count" -eq 0 ]; then
    error "APK 闭包晋升失败：暂存目录没有 .apk（暂存: $dest，目标: $backup_dir）"
  fi
  log "开始晋升已验证 APK 闭包: $dest/ → $backup_dir/（$count 个包）"
  parent=$(dirname "$backup_dir")
  tmp="${backup_dir}.tmp.$$"
  old="${backup_dir}.old.$$"
  mkdir -p "$parent"
  rm -rf "$tmp" "$old"
  mkdir "$tmp"
  if ! cp "$dest"/*.apk "$tmp/"; then
    rm -rf "$tmp"
    error "APK 闭包晋升失败：无法复制暂存包"
  fi
  if [ -e "$backup_dir" ]; then
    mv "$backup_dir" "$old" || {
      rm -rf "$tmp"
      error "APK 闭包晋升失败：无法保留旧备份库"
    }
  fi
  if ! mv "$tmp" "$backup_dir"; then
    [ -e "$old" ] && mv "$old" "$backup_dir"
    rm -rf "$tmp"
    error "APK 闭包晋升失败：无法替换备份库"
  fi
  if ! _php_apk_closure_verify "$backup_dir"; then
    rm -rf "$backup_dir"
    if [ -e "$old" ]; then
      mv "$old" "$backup_dir" || error "APK 闭包晋升失败：目标校验失败且旧备份库恢复失败"
    fi
    error "APK 闭包晋升失败：目标备份库完整性校验失败（目标: $backup_dir）"
  fi
  rm -rf "$old"
  size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)
  log "已验证入备份库: $backup_dir/（$count 个包，$size）"
}

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
_PHP_EXT_APK_DEPS="gd:libpng-dev,libjpeg-turbo-dev,freetype-dev,libwebp-dev,zlib-dev,zlib-dev,libxpm-dev intl:icu-dev zip:libzip-dev pgsql:libpq-dev pdo_pgsql:libpq-dev soap:libxml2-dev imagick:imagemagick-dev"

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

# 解析 BUILD_PROXY 为容器可达的最终代理地址，stdout 输出（none 或 http://URL）。
# none=禁用；auto（默认）=探测本地常见代理端口；其余按显式值（host:port 或完整 URL）。
# 代理地址归一化：原生 docker 的构建容器里 host.docker.internal 默认不解析（Desktop VM
# 才内置该域名），换引擎后 pecl 全部死于 DNS——代理指向本机时改写为 docker0 网关 IP
# （容器内零 DNS 可达），取不到再退回域名，并由调用方的 --add-host host-gateway 兜底
_php_resolve_build_proxy() {
  local proxy="${BUILD_PROXY:-auto}"
  if [ "$proxy" = "auto" ]; then proxy=$(_php_detect_build_proxy); fi
  if [ -z "$proxy" ] || [ "$proxy" = "none" ]; then echo "none"; return 0; fi
  case "$proxy" in
    http://*|https://*) : ;;
    *) proxy="http://${proxy}" ;;
  esac
  local proxy_gw
  proxy_gw=$(ip -4 addr show docker0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 || true)
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

# 构建失败时彻底删除两个暂存目录（pecl 包与 apk 闭包）：未验证的内容没有备份库正本、
# 命中副本的母本在备份库不受影响，留在磁盘上只是垃圾。暂存标记同步清空，防止后续误晋升
_php_discard_staging() {
  local build_dir=$1
  rm -rf "$build_dir/pecl" "$build_dir/apk"
  _PECL_STAGED=""
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


# ---- APK 下载器公共层（搬运自 lib/common.sh，纯迁移无逻辑改动；仅 PHP 构建线使用）----

# 把镜像源域名按预解析 IP 输出为 --add-host 参数（两行：标志与值；解析失败输出空）。
# 容器内 DNS 对国内域名间歇性失败（DNS: transient error）且 apk 连接挂死无重试，跳过 DNS 可根治；
# /etc/hosts 在 buildkit 中只读，必须用 --add-host 而非 RUN echo
_apk_mirror_host_args() {
  local apk_mirror=$1
  local host="${apk_mirror#*://}"; host="${host%%/*}"
  local ip=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}' || true)
  if [ -n "$ip" ]; then echo "--add-host"; echo "$host:$ip"; fi
}

# 容器内 apk 下载器脚本（与 _apk_ranked_fetch_run、_load_apk_mirrors 同属 apk 源管理公共层）：
# 1) 用前测速：逐源下载 main 索引计时（APK_TIMEOUT 秒上限，超时/失败剔除），按最快优先排序；
# 2) 按测速顺序逐源整批下载：索引获取 APK_TIMEOUT 秒超时；下载期间以 /pkgs 增量 + 容器网卡
#    流量为进度双指标，APK_TIMEOUT 秒无增长 = 无响应，杀掉当前下载自动切换下一个源。
# 闭包必须出自同一源：切换源即清空 /pkgs 重来，避免两个源的版本混装。
# 单引号包裹：脚本的 $ 一律为容器运行时展开。调用:
#   sh -c "$_APK_FETCH_SCRIPT" <标签> recursive <包列表...>   # 递归闭包（预取）
#   sh -c "$_APK_FETCH_SCRIPT" <标签> installed               # 全量已装包（基础包同步）
_APK_FETCH_SCRIPT='
cp /etc/apk/repositories /tmp/repos.orig
MODE=$1; shift
APK_TIMEOUT="${APK_TIMEOUT:-30}"
VER="v$(cut -d. -f1,2 /etc/alpine-release 2>/dev/null)"
case "$VER" in
  v) VER=$(sed -n "s|^https://dl-cdn.alpinelinux.org/alpine/||p" /tmp/repos.orig | head -n1 | cut -d/ -f1) ;;
esac
ARCH=$(uname -m)
RANKED=""
echo "== 初始化 apk 下载器（模式: $MODE，架构: $ARCH，超时: ${APK_TIMEOUT}s）=="
echo "== 源测速（APKINDEX 下载耗时，${APK_TIMEOUT}s 上限）=="
for m in $APK_MIRRORS; do
  start=$(cut -d" " -f1 /proc/uptime)
  if timeout $APK_TIMEOUT wget -T $APK_TIMEOUT -q -O /dev/null "$m/$VER/main/$ARCH/APKINDEX.tar.gz" 2>/dev/null; then
    end=$(cut -d" " -f1 /proc/uptime)
    t=$(awk -v a="$end" -v b="$start" "BEGIN{printf \"%.2f\", a-b}")
    echo "  可用 $m  ${t}s"
    RANKED="$RANKED$t $m
"
  else
    echo "  不可用 $m（超时或失败，跳过）"
  fi
done
if [ -n "$RANKED" ]; then
  ORDER=$(printf "%s" "$RANKED" | sort -n | cut -d" " -f2-)
else
  echo "全部源测速失败，退回配置顺序尝试"
  ORDER="$APK_MIRRORS"
fi
n=0
total=$(printf "%s" "$ORDER" | grep -c .)
for m in $ORDER; do
  n=$((n+1))
  echo "== 尝试源 $n/$total: $m =="
  { echo "$m/$VER/main"; echo "$m/$VER/community"; } > /etc/apk/repositories
  # 索引获取：瞬时失败很常见（间歇性网络），重试 3 次；彻底失败仍不放弃该源——
  # 交给 fetch 解析检验（community 缺索引只影响 community 包，main 包照常解析）
  u=1
  while [ $u -le 3 ]; do
    echo "  获取 apk 索引（第 $u/3 次，最长 ${APK_TIMEOUT}s）..."
    if timeout $APK_TIMEOUT apk update >/dev/null 2>&1; then
      echo "  apk 索引获取完成"
      break
    fi
    u=$((u+1))
    [ $u -le 3 ] && { echo "  索引获取失败，重试 $u/3"; sleep 2; }
  done
  [ $u -gt 3 ] && echo "  警告：部分索引获取失败，仍尝试解析下载"
  # 清空仅在递归闭包模式下发生（换源即重来，闭包必须出自同一源）；
  # installed（基础包同步）是增量补充——曾因清空对两种模式都生效，把预取闭包删得只剩
  # 基础镜像自带包（41 个），离线构建 phpize 报 Cannot find autoconf
  case "$MODE" in
    recursive) rm -f /pkgs/*.apk 2>/dev/null; echo "  开始递归下载构建依赖（目标包: $#，输出目录: /pkgs）"; apk fetch --recursive -o /pkgs shadow curl $PHPIZE_DEPS "$@" & ;;
    installed) echo "  开始同步基础镜像已安装包（输出目录: /pkgs）"; apk fetch -o /pkgs $(apk info -q) & ;;
  esac
  apid=$!
  last="$(du -sk /pkgs 2>/dev/null | cut -f1) $(grep "^ *eth0:" /proc/net/dev | awk "{print \$2}")"
  stall=0
  dead=""
  started=$(cut -d" " -f1 /proc/uptime)
  while kill -0 $apid 2>/dev/null; do
    sleep 5
    cur="$(du -sk /pkgs 2>/dev/null | cut -f1) $(grep "^ *eth0:" /proc/net/dev | awk "{print \$2}")"
    now=$(cut -d" " -f1 /proc/uptime)
    elapsed=$(awk -v a="$now" -v b="$started" "BEGIN{printf \"%.0f\", a-b}")
    echo "  下载进行中：已耗时 ${elapsed}s，文件 ${cur%% *} KiB，网卡接收 ${cur##* } KiB"
    if [ "$cur" = "$last" ]; then
      stall=$((stall+5))
      [ $stall -ge $APK_TIMEOUT ] && { dead=1; break; }
    else
      stall=0; last="$cur"
    fi
  done
  if [ -n "$dead" ]; then
    kill $apid 2>/dev/null
    wait $apid 2>/dev/null
    echo "  ${APK_TIMEOUT} 秒无响应，停止并切换下一个源"
    continue
  fi
  if wait $apid; then
    # apk fetch 可能对"无法解析"静默返回 0 且零下载（实测：community 索引缺失时整单
    # 放弃仍退出 0）——按内容验收：phpize 工具链必须落地，缺失视作该源失败换下一个
    # （与宿主侧 _php_apk_closure_verify 同一套清单，双端把关）
    verify=1
    for t in autoconf gcc g++ make pkgconf re2c musl-dev linux-headers file dpkg; do
      ls /pkgs/$t-*.apk >/dev/null 2>&1 || { verify=0; break; }
    done
    if [ "$verify" = 1 ]; then
      count=$(find /pkgs -maxdepth 1 -name "*.apk" -type f 2>/dev/null | wc -l)
      size=$(du -sh /pkgs 2>/dev/null | cut -f1)
      echo "== 源 $m 下载完成（$count 个包，$size）=="
      OK=1
      break
    fi
    echo "  该源闭包不完整（缺构建工具），换下一个源"
    continue
  fi
  echo "  下载失败，换下一个源"
done
if [ "$OK" = 1 ]; then
  chown -R "$HOST_UID:$HOST_UID" /pkgs 2>/dev/null || true
  exit 0
fi
echo "全部源均失败"
exit 1
'

# 在 alpine 系容器内测速下载 apk 包（公共入口，预取/基础包同步等调用方只做薄封装）。
# 参数: $1=基础镜像(如 php:8.4-fpm-alpine)  $2=容器名（固定名：宿主侧 timeout 杀掉客户端
#       时容器会残留并挂住构建目录，按名强制清理，绝不留孤儿）
#       $3=宿主侧总超时秒  $4=模式(recursive|installed)  $5=包落地目录(挂到 /pkgs)
#       $6+=包列表（仅 recursive 模式）
# 返回: 任一源下载成功 → 0；全部失败 → 1（降级策略由调用方决定）
_apk_ranked_fetch_run() {
  local image=$1 cname=$2 host_timeout=$3 mode=$4 dest=$5
  shift 5
  local addhost=()
  mapfile -t addhost < <(_apk_mirror_host_args "${APK_MIRRORS%% *}")   # 主源 DNS 预解析
  docker rm -f "$cname" 2>/dev/null || true   # 上次残留的同名容器会让 run 直接失败，先清
  log "apk 下载器启动：镜像 $image，容器 $cname，宿主超时 ${host_timeout}s，模式 $mode"
  if ! timeout "$host_timeout" docker run --rm --name "$cname" "${addhost[@]}" \
      -e APK_MIRRORS="$APK_MIRRORS" -e APK_TIMEOUT="$APK_TIMEOUT" -e HOST_UID="${CURRENT_UID:-}" -v "$dest":/pkgs \
      "$image" sh -c "$_APK_FETCH_SCRIPT" phpbox-apk "$mode" "$@" >&2; then
    docker rm -f "$cname" 2>/dev/null || true
    return 1
  fi
}
