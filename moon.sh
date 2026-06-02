#!/bin/bash

# =========================
# Root check
# =========================
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root"
    exit 1
fi

# =========================
# Colors
# =========================
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

# =========================
# Helpers
# =========================
validate_email() {
    [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

rand() { tr </dev/urandom -dc 'A-Za-z0-9' | head -c "$1"; }

# =========================
# Variables
# =========================
PHP_VERSION="8.4"  # Fixed PHP version for compatibility
INSTALL_DIR="/var/www/Moon"
ENV_FILE="$INSTALL_DIR/.env"
NGINX_CONF="/etc/nginx/sites-available/moon_network"
SUPERVISOR_CONF="/etc/supervisor/conf.d/laravel-queue-worker.conf"

# =========================
# Install PHP 8.4
# =========================
install_php84() {
    echo -e "${CYAN}Installing PHP $PHP_VERSION...${RESET}"
    
    # Add Ondrej PHP repository (official PHP packages)
    apt-get update -y
    apt-get install -y software-properties-common
    add-apt-repository -y ppa:ondrej/php
    apt-get update -y
    
    # Remove any existing PHP versions
    apt-get purge -y php* || true
    apt-get autoremove -y
    
    # Install PHP 8.4 and required extensions
    apt-get install -y \
        php$PHP_VERSION \
        php$PHP_VERSION-fpm \
        php$PHP_VERSION-cli \
        php$PHP_VERSION-mysql \
        php$PHP_VERSION-xml \
        php$PHP_VERSION-mbstring \
        php$PHP_VERSION-curl \
        php$PHP_VERSION-zip \
        php$PHP_VERSION-bcmath \
        php$PHP_VERSION-gd \
        php$PHP_VERSION-redis \
        php$PHP_VERSION-common
    
    # Set PHP 8.4 as default
    update-alternatives --set php /usr/bin/php$PHP_VERSION
    update-alternatives --set phar /usr/bin/phar$PHP_VERSION
    update-alternatives --set phar.phar /usr/bin/phar.phar$PHP_VERSION
    
    echo -e "${GREEN}PHP $PHP_VERSION installed successfully${RESET}"
}

# =========================
# Install
# =========================
install() {
    clear
    echo -e "${CYAN}Moon Network Installation (PHP $PHP_VERSION)${RESET}"

    read -p "Enter app name (default: Moon): " APPNAME
    APPNAME=${APPNAME:-Moon}

    read -p "Enter domain (example.com): " DOMAIN
    while [[ -z "$DOMAIN" ]]; do
        echo -e "${RED}Domain cannot be empty${RESET}"
        read -p "Enter domain: " DOMAIN
    done

    read -p "Enter SSL email: " SSL_EMAIL
    until validate_email "$SSL_EMAIL"; do
        echo -e "${RED}Invalid email${RESET}"
        read -p "Enter SSL email: " SSL_EMAIL
    done

    read -p "Database name (default: moon_db): " MAINDB
    MAINDB=${MAINDB:-moon_db}

    read -p "Database user (default: moon_user): " DB_USER
    DB_USER=${DB_USER:-moon_user}

    read -sp "Database password (leave empty to generate): " DB_PASSWORD
    echo
    DB_PASSWORD=${DB_PASSWORD:-$(rand 16)}

    DATA_ENCRYPTION_KEY=$(rand 32)
    MARZBAN_WEBHOOK_SECRET=$(rand 32)

    echo -e "${CYAN}Installing system dependencies...${RESET}"
    apt-get update -y
    apt-get install -y \
        nginx mysql-server redis-server supervisor \
        git unzip curl \
        certbot python3-certbot-nginx

    # Install PHP 8.4 specifically
    install_php84

    # Install Composer
    if ! command -v composer >/dev/null; then
        curl -sS https://getcomposer.org/installer | php
        mv composer.phar /usr/local/bin/composer
        chmod +x /usr/local/bin/composer
    fi

    if systemctl list-unit-files | grep -q apache2.service; then
        systemctl stop apache2 || true
        systemctl disable apache2 || true
    fi

    if ! command -v node >/dev/null || [[ $(node -v | cut -d. -f1) != "v20" ]]; then
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y nodejs
    fi

    # Fix git ownership issue
    if [ ! -d "$INSTALL_DIR" ]; then
        git config --global --add safe.directory "$INSTALL_DIR"
        git clone git@github.com:ezreza/Moon.git "$INSTALL_DIR" || {
            echo -e "${RED}Git clone failed. Trying HTTPS...${RESET}"
            git clone https://github.com/ezreza/Moon.git "$INSTALL_DIR" || {
                echo -e "${RED}Git clone failed${RESET}"
                exit 1
            }
        }
    fi

    cd "$INSTALL_DIR" || exit 1

    echo -e "${CYAN}Installing backend dependencies with PHP $PHP_VERSION...${RESET}"
    
    # Ensure composer uses correct PHP version
    export COMPOSER_ALLOW_SUPERUSER=1
    
    # Update composer dependencies to be compatible with PHP 8.4
    composer update --optimize-autoloader --no-dev || {
        echo -e "${YELLOW}Trying composer install...${RESET}"
        composer install --optimize-autoloader --no-dev
    }

    if [ ! -f .env ]; then
        cp .env.example .env
    fi

    sed -i 's/^APP_DEBUG=.*/APP_DEBUG=false/' .env
    sed -i 's/^APP_ENV=.*/APP_ENV=production/' .env
    sed -i "s|^APP_URL=.*|APP_URL=https://$DOMAIN|" .env

    sed -i '/^# DB_HOST=/s/^# *//' .env
    sed -i '/^# DB_PORT=/s/^# *//' .env
    sed -i '/^# DB_DATABASE=/s/^# *//' .env
    sed -i '/^# DB_USERNAME=/s/^# *//' .env
    sed -i '/^# DB_PASSWORD=/s/^# *//' .env

    sed -i "s/^DB_CONNECTION=.*/DB_CONNECTION=mysql/" .env
    sed -i "s/^DB_DATABASE=.*/DB_DATABASE=$MAINDB/" .env
    sed -i "s/^DB_USERNAME=.*/DB_USERNAME=$DB_USER/" .env
    sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=$DB_PASSWORD/" .env

    sed -i "s|^APP_NAME=.*|APP_NAME=\"$APPNAME\"|" .env
    sed -i "s|^DATA_ENCRYPTION_KEY=.*|DATA_ENCRYPTION_KEY=$DATA_ENCRYPTION_KEY|" .env
    sed -i "s|^MARZBAN_WEBHOOK_SECRET=.*|MARZBAN_WEBHOOK_SECRET=$MARZBAN_WEBHOOK_SECRET|" .env

    if ! grep -q "^APP_KEY=base64:" .env; then
        php artisan key:generate --force
    fi

    # Permissions
    sudo chown -R www-data:www-data "$INSTALL_DIR"
    sudo chmod -R 775 "$INSTALL_DIR"/storage "$INSTALL_DIR"/bootstrap/cache
    php artisan storage:link || true

    # MySQL
    echo -e "${CYAN}Configuring MySQL...${RESET}"
    mysql <<EOF
CREATE DATABASE IF NOT EXISTS $MAINDB;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON $MAINDB.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

    php artisan migrate --force
    php artisan optimize

    # Nginx configuration with correct PHP version
    if [ ! -f "$NGINX_CONF" ]; then
        cp nginx/Moon.conf "$NGINX_CONF" 2>/dev/null || {
            # Create default nginx config if Moon.conf doesn't exist
            cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    root $INSTALL_DIR/public;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    index index.php;

    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ \.php$ {
        fastcgi_pass unix:/var/run/php/php$PHP_VERSION-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF
        }
        ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
    fi

    sed -i "s/server_name .*/server_name $DOMAIN;/" "$NGINX_CONF"

    # Fix PHP-FPM socket path in nginx config
    sed -i "s|fastcgi_pass .*php.*-fpm.sock;|fastcgi_pass unix:/var/run/php/php$PHP_VERSION-fpm.sock;|g" "$NGINX_CONF"

    # Cron
    (crontab -l 2>/dev/null | grep -v 'artisan schedule:run'; \
     echo "* * * * * cd $INSTALL_DIR && php artisan schedule:run >> /dev/null 2>&1") | crontab -

    # Supervisor service
    sudo systemctl enable supervisor
    sudo systemctl start supervisor

    # Setting Worker for Laravel Queue
    echo "Configuring Laravel Queue Worker..."

    sudo bash -c "cat > $SUPERVISOR_CONF" <<EOF
[program:laravel-queue-worker]
process_name=%(program_name)s_%(process_num)02d
command=php $INSTALL_DIR/artisan queue:work --tries=3 --timeout=90
autostart=true
autorestart=true
numprocs=1
redirect_stderr=true
stdout_logfile=$INSTALL_DIR/storage/logs/queue-worker.log
EOF

    if [ -f "$SUPERVISOR_CONF" ]; then
        echo "Laravel Queue Worker configuration added successfully!"
        sudo supervisorctl reread
        sudo supervisorctl update
        sudo supervisorctl start laravel-queue-worker
    else
        echo "Error: Failed to create Supervisor configuration file!"
    fi

    # Build
    echo -e "${CYAN}Building frontend...${RESET}"
    npm ci
    npm run build

    # PHP upload limits
    echo -e "${CYAN}Configuring PHP upload limits...${RESET}"
    
    PHP_INI="/etc/php/$PHP_VERSION/fpm/php.ini"
    
    if [ -f "$PHP_INI" ]; then
        sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 10M/' "$PHP_INI"
        sed -i 's/^post_max_size = .*/post_max_size = 25M/' "$PHP_INI"
        
        systemctl restart "php$PHP_VERSION-fpm"
    else
        echo -e "${YELLOW}Warning: $PHP_INI not found. Skipping PHP upload config.${RESET}"
    fi

    # Cert
    certbot --nginx -n --agree-tos --email "$SSL_EMAIL" -d "$DOMAIN" || true
    grep -q 'listen 443 ssl http2;.*managed by Certbot' "$NGINX_CONF" || \
    sed -i -E 's|listen[[:space:]]+443[[:space:]]+ssl;([[:space:]]*# managed by Certbot)|listen 443 ssl http2;\1|' "$NGINX_CONF"
    nginx -t && systemctl reload nginx

    # moon CLI
    echo -e "${CYAN}Installing moon CLI command...${RESET}"
    
    CLI_SOURCE="$INSTALL_DIR/cli/moon"
    CLI_TARGET="/usr/local/bin/moon"
    
    if [ -f "$CLI_SOURCE" ]; then
        cp "$CLI_SOURCE" "$CLI_TARGET"
        chmod +x "$CLI_TARGET"
        echo -e "${GREEN}moon command installed! You can now run 'moon' from anywhere.${RESET}"
    else
        echo -e "${YELLOW}moon CLI script not found at $CLI_SOURCE${RESET}"
    fi

    clear
    echo -e "${GREEN}Installation completed successfully!${RESET}"
    echo "----------------------------------"
    echo -e "PHP Version: ${CYAN}$PHP_VERSION${RESET}"
    echo -e "You can now manage your Moon project using the ${CYAN}moon${RESET} command from anywhere."
    echo -e "Visit your project at: ${YELLOW}https://$DOMAIN${RESET}"
    echo "----------------------------------"
    
    # Show PHP version for verification
    php -v
}

# =========================
# Uninstall
# =========================
uninstall() {
    echo -e "${RED}This will remove Moon and its database${RESET}"
    read -p "Type YES to continue: " CONFIRM
    [[ "$CONFIRM" != "YES" ]] && exit 0

    if [ -f "$ENV_FILE" ]; then
        MAINDB=$(grep '^DB_DATABASE=' "$ENV_FILE" | cut -d= -f2)
        DB_USER=$(grep '^DB_USERNAME=' "$ENV_FILE" | cut -d= -f2)
    fi

    supervisorctl stop laravel-queue-worker || true
    (crontab -l 2>/dev/null | grep -v 'artisan schedule:run') | crontab -

    mysql <<EOF
DROP DATABASE IF EXISTS $MAINDB;
DROP USER IF EXISTS '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

    rm -rf "$INSTALL_DIR"
    rm -f "$NGINX_CONF"
    rm -f /etc/nginx/sites-enabled/$(basename "$NGINX_CONF")
    rm -f "$SUPERVISOR_CONF"

    supervisorctl reread && supervisorctl update || true
    nginx -t && systemctl reload nginx || true

    echo -e "${GREEN}Moon removed successfully${RESET}"
}

# =========================
# SSH Key
# =========================
key() {
    read -p "SSH key name (default: moon-admin): " SSH_KEY_NAME
    SSH_KEY_NAME=${SSH_KEY_NAME:-moon-admin}

    mkdir -p ~/.ssh
    ssh-keygen -t rsa -b 4096 -f ~/.ssh/$SSH_KEY_NAME -N ""

    cat ~/.ssh/$SSH_KEY_NAME.pub
    echo -e "Host github.com\n\tIdentityFile ~/.ssh/$SSH_KEY_NAME\n" >> ~/.ssh/config
    chmod 600 ~/.ssh/config ~/.ssh/$SSH_KEY_NAME
}

# =========================
# Main
# =========================
case "$1" in
    install) install ;;
    uninstall|remove) uninstall ;;
    key) key ;;
    *) echo "Usage: $0 {install|uninstall|key}" ;;
esac
