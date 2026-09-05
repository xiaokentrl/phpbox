FROM php:8.0-fpm-alpine
ARG UID=1000
ARG GID=1000
# APK_MIRRORS：Alpine 镜像源列表（空格分隔，按序故障转移），值截取到 /alpine 含
ARG APK_MIRRORS="https://mirrors.aliyun.com/alpine https://dl-cdn.alpinelinux.org/alpine"
RUN cp /etc/apk/repositories /tmp/repos.orig && : > /etc/apk/repositories &&   for m in $APK_MIRRORS; do case "$m" in */alpine) : ;; *) m="$m/alpine" ;; esac; sed "s|https://dl-cdn.alpinelinux.org/alpine|$m|g" /tmp/repos.orig >> /etc/apk/repositories; done
# 依赖与源码包全部来自宿主机侧本地备份（apk-cache、pecl-cache），构建不依赖容器内网络
COPY apk/ /tmp/apk/
COPY pecl/ /tmp/pecl/
RUN apk add --no-network /tmp/apk/*.apk
RUN for t in /tmp/pecl/*.tgz; do [ -e "$t" ] || { echo "ERROR: /tmp/pecl/ 下没有 .tgz 包"; exit 1; }; pecl install "$t" && docker-php-ext-enable "$(basename "$t" .tgz | sed 's/-[0-9][0-9.]*$//')" || exit 1; done
RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp --with-xpm &&  docker-php-ext-install -j"$(nproc)" bcmath exif gd intl mysqli opcache pdo_mysql pdo_pgsql pgsql soap sockets zip
RUN usermod -u ${UID} www-data && groupmod -g ${GID} www-data
