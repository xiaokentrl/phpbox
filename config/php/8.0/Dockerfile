FROM php:8.0-fpm-alpine
ARG UID=1000
ARG GID=1000
# APK_MIRROR：替换 Alpine 官方 CDN（国内网络对其极不稳定），如 https://mirrors.aliyun.com
ARG APK_MIRROR=
RUN if [ -n "$APK_MIRROR" ]; then sed -i "s|https://dl-cdn.alpinelinux.org|$APK_MIRROR|g; s|http://dl-cdn.alpinelinux.org|$APK_MIRROR|g" /etc/apk/repositories; fi
RUN apk add --no-cache shadow curl
# 工具链与全部扩展的系统依赖一次性装齐并独立成层：该层成功后即被构建缓存，
# 失败重试/重建/换扩展列表都不会再重复拉取；IPE 内部的按模块装卸发现已装即跳过
RUN apk add --no-cache $PHPIZE_DEPS musl-dev linux-headers pkgconf re2c libpng-dev libjpeg-turbo-dev freetype-dev icu-dev libpq-dev libpq-dev libxml2-dev libzip-dev imagemagick-dev
COPY --from=mlocati/php-extension-installer:2 /usr/bin/install-php-extensions /usr/local/bin/
# pecl 远端模块的源码包已在宿主机侧预下载并 COPY 进来，本地安装不依赖容器内网络
# （pecl.php.net 的 DNS/REST 在受限网络不可达，且老镜像捆绑的 PEAR 有代理解析 bug）
COPY php-exts/ /tmp/php-exts/
RUN for t in /tmp/php-exts/*.tgz; do pecl install "$t" && docker-php-ext-enable "$(basename "$t" .tgz | sed 's/-[0-9][0-9.]*$//')" || exit 1; done
# 重试一次兜底：受限网络下连接被重置是随机的，IPE 幂等可安全重跑（已装扩展会跳过）
RUN if [ -n "bcmath,exif,gd,intl,mysqli,opcache,pdo_mysql,pdo_pgsql,pgsql,soap,sockets,zip" ]; then install-php-extensions bcmath exif gd intl mysqli opcache pdo_mysql pdo_pgsql pgsql soap sockets zip || install-php-extensions bcmath exif gd intl mysqli opcache pdo_mysql pdo_pgsql pgsql soap sockets zip; fi
RUN usermod -u ${UID} www-data && groupmod -g ${GID} www-data
