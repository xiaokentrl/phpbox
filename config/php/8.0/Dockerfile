FROM php:8.0-fpm-alpine
ARG UID=1000
ARG GID=1000
# APK_MIRROR：替换 Alpine 官方 CDN（国内网络对其极不稳定），如 https://mirrors.aliyun.com
ARG APK_MIRROR=
RUN if [ -n "$APK_MIRROR" ]; then sed -i "s|https://dl-cdn.alpinelinux.org|$APK_MIRROR|g; s|http://dl-cdn.alpinelinux.org|$APK_MIRROR|g" /etc/apk/repositories; fi
RUN apk add --no-cache shadow curl
COPY --from=mlocati/php-extension-installer:2 /usr/bin/install-php-extensions /usr/local/bin/
# http_proxy 是 Docker 预定义 build arg（自动注入每个 RUN 的环境）；但 PEAR 的下载器
# 只认自己的代理配置而不读环境变量，须显式写入，否则 pecl 源码包下载仍走直连
ARG http_proxy=
RUN if [ -n "$http_proxy" ]; then pear config-set http_proxy "$http_proxy" 2>/dev/null || true; fi
# 重试一次兜底：受限网络下连接被重置是随机的，IPE 幂等可安全重跑（已装扩展会跳过）
RUN if [ -n "bcmath,exif,gd,imagick,intl,mysqli,opcache,pdo_mysql,pdo_pgsql,pgsql,redis,soap,sockets,xdebug,zip" ]; then install-php-extensions bcmath exif gd imagick intl mysqli opcache pdo_mysql pdo_pgsql pgsql redis soap sockets xdebug zip || install-php-extensions bcmath exif gd imagick intl mysqli opcache pdo_mysql pdo_pgsql pgsql redis soap sockets xdebug zip; fi
RUN usermod -u ${UID} www-data && groupmod -g ${GID} www-data
