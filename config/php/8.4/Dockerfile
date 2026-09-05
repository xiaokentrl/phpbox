FROM php:8.4-fpm-alpine
ARG UID=1000
ARG GID=1000
# APK_MIRROR：替换 Alpine 官方 CDN（国内网络对其极不稳定），如 https://mirrors.aliyun.com
ARG APK_MIRROR=
RUN if [ -n "$APK_MIRROR" ]; then sed -i "s|https://dl-cdn.alpinelinux.org|$APK_MIRROR|g; s|http://dl-cdn.alpinelinux.org|$APK_MIRROR|g" /etc/apk/repositories; fi
RUN apk add --no-cache shadow curl
COPY --from=mlocati/php-extension-installer:2 /usr/bin/install-php-extensions /usr/local/bin/
# http_proxy 是 Docker 预定义 build arg，声明后自动进入每个 RUN 的环境，PEAR/pecl
# 直接读取该环境变量即可走代理。切勿 pear config-set：PEAR 的解析器不吃带 scheme 的值
# （http://host:port 会被解析成空主机），一旦写入，所有 pecl 请求都去连 ":"，
# 报 "No releases available"——曾导致 imagick/redis/xdebug 等全部远端扩展装不上
ARG http_proxy=
# 重试一次兜底：受限网络下连接被重置是随机的，IPE 幂等可安全重跑（已装扩展会跳过）
RUN if [ -n "bcmath,exif,gd,imagick,intl,mysqli,opcache,pdo_mysql,pdo_pgsql,pgsql,redis,soap,sockets,xdebug,zip" ]; then install-php-extensions bcmath exif gd imagick intl mysqli opcache pdo_mysql pdo_pgsql pgsql redis soap sockets xdebug zip || install-php-extensions bcmath exif gd imagick intl mysqli opcache pdo_mysql pdo_pgsql pgsql redis soap sockets xdebug zip; fi
RUN usermod -u ${UID} www-data && groupmod -g ${GID} www-data
