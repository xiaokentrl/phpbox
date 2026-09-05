FROM php:8.0-fpm-alpine
ARG UID=1000
ARG GID=1000
# APK_MIRROR：替换 Alpine 官方 CDN（国内网络对其极不稳定），如 https://mirrors.aliyun.com
ARG APK_MIRROR=
RUN if [ -n "$APK_MIRROR" ]; then sed -i "s|https://dl-cdn.alpinelinux.org|$APK_MIRROR|g; s|http://dl-cdn.alpinelinux.org|$APK_MIRROR|g" /etc/apk/repositories; fi
# 依赖与源码包全部来自宿主机侧本地备份（apk-cache、pecl-cache），构建不依赖容器内网络
RUN apk add --no-cache shadow curl
COPY --from=mlocati/php-extension-installer:2 /usr/bin/install-php-extensions /usr/local/bin/
RUN apk add --no-cache $PHPIZE_DEPS musl-dev linux-headers pkgconf re2c libpng-dev libjpeg-turbo-dev freetype-dev icu-dev libpq-dev libpq-dev libxml2-dev libzip-dev imagemagick-dev
COPY php-exts/ /tmp/php-exts/
RUN for t in /tmp/php-exts/*.tgz; do [ -e "$t" ] || { echo "ERROR: /tmp/php-exts/ 下没有 .tgz 包"; exit 1; }; pecl install "$t" && docker-php-ext-enable "$(basename "$t" .tgz | sed 's/-[0-9][0-9.]*$//')" || exit 1; done
# 重试一次兜底：受限网络下连接被重置是随机的，IPE 幂等可安全重跑（已装扩展会跳过）
RUN if [ -n "bcmath,exif,gd,intl,mysqli,opcache,pdo_mysql,pdo_pgsql,pgsql,soap,sockets,zip" ]; then install-php-extensions bcmath exif gd intl mysqli opcache pdo_mysql pdo_pgsql pgsql soap sockets zip || install-php-extensions bcmath exif gd intl mysqli opcache pdo_mysql pdo_pgsql pgsql soap sockets zip; fi
RUN usermod -u ${UID} www-data && groupmod -g ${GID} www-data
