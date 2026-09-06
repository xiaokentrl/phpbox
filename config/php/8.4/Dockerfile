FROM php:8.4-fpm-alpine
ARG UID=1000
ARG GID=1000
# APK_MIRRORS：Alpine 镜像源列表（空格分隔，按序故障转移），值截取到 /alpine 含
ARG APK_MIRRORS="https://mirrors.aliyun.com/alpine https://dl-cdn.alpinelinux.org/alpine"
RUN cp /etc/apk/repositories /tmp/repos.orig && : > /etc/apk/repositories &&   for m in $APK_MIRRORS; do case "$m" in */alpine) : ;; *) m="$m/alpine" ;; esac; sed "s|https://dl-cdn.alpinelinux.org/alpine|$m|g" /tmp/repos.orig >> /etc/apk/repositories; done
# 依赖与源码包全部来自宿主机侧本地备份（offline/apk、offline/pecl），构建不依赖容器内网络
RUN apk add --no-cache shadow curl
COPY --from=mlocati/php-extension-installer:2 /usr/bin/install-php-extensions /usr/local/bin/
RUN apk add --no-cache $PHPIZE_DEPS musl-dev linux-headers pkgconf re2c libpng-dev libjpeg-turbo-dev freetype-dev libwebp-dev zlib-dev zlib-dev libxpm-dev icu-dev libpq-dev libpq-dev libxml2-dev libzip-dev imagemagick-dev
COPY pecl/ /tmp/pecl/
RUN for t in /tmp/pecl/*.tgz; do [ -e "$t" ] || { echo "ERROR: /tmp/pecl/ 下没有 .tgz 包"; exit 1; }; pecl install "$t" && docker-php-ext-enable "$(basename "$t" .tgz | sed 's/-[0-9][0-9.]*$//')" || exit 1; done
# 重试一次兜底：受限网络下连接被重置是随机的，IPE 幂等可安全重跑（已装扩展会跳过）
RUN if [ -n "bcmath,exif,gd,intl,mysqli,opcache,pdo_mysql,pdo_pgsql,pgsql,soap,sockets,zip" ]; then install-php-extensions bcmath exif gd intl mysqli opcache pdo_mysql pdo_pgsql pgsql soap sockets zip || install-php-extensions bcmath exif gd intl mysqli opcache pdo_mysql pdo_pgsql pgsql soap sockets zip; fi
RUN usermod -u ${UID} www-data && groupmod -g ${GID} www-data
