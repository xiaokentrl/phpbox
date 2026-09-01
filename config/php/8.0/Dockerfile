FROM php:8.0-fpm-alpine
ARG UID=1000
ARG GID=1000
RUN apk add --no-cache shadow curl
COPY --from=mlocati/php-extension-installer:2 /usr/bin/install-php-extensions /usr/local/bin/
RUN if [ -n "gd,redis" ]; then install-php-extensions gd redis; fi
RUN usermod -u ${UID} www-data && groupmod -g ${GID} www-data
