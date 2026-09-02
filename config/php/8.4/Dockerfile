FROM php:8.4-fpm-alpine
ARG UID=1000
ARG GID=1000
RUN apk add --no-cache shadow curl
COPY --from=mlocati/php-extension-installer:2 /usr/bin/install-php-extensions /usr/local/bin/
RUN if [ -n "bcmath,exif,gd,imagick,intl,mysqli,opcache,pdo_mysql,pdo_pgsql,pgsql,redis,soap,sockets,xdebug,zip" ]; then install-php-extensions bcmath exif gd imagick intl mysqli opcache pdo_mysql pdo_pgsql pgsql redis soap sockets xdebug zip; fi
RUN usermod -u ${UID} www-data && groupmod -g ${GID} www-data
