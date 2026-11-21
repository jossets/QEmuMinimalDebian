
FROM php:8.4-apache-trixie

# php
RUN apt-get update && apt-get install -y --no-install-recommends \
        libzip-dev \
        libpng-dev \
        libjpeg62-turbo-dev \
    && docker-php-ext-install \
        mysqli \
        pdo_mysql \
        zip \
        gd \
    && rm -rf /var/lib/apt/lists/*

# Apache modules
RUN a2enmod rewrite headers

# Configuration PHP
RUN mv "$PHP_INI_DIR/php.ini-production" \
       "$PHP_INI_DIR/php.ini"

# Site html et php
COPY html/ /var/www/html/
RUN find /var/www/html -type d -exec chmod 755 {} \; && \
    find /var/www/html -type f -exec chmod 644 {} \;

# Run apache+php
WORKDIR /var/www/html
EXPOSE 80
CMD ["apache2-foreground"]
