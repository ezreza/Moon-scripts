#!/bin/bash

# =========================
# Root check
# =========================
if [ "$(id -u)" != "0" ]; then
echo "This script must be run as root" 1>&2
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
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"
RESET="\e[0m"

# =========================
# Helpers
# =========================
validate_email() {
    [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}


rand() { tr </dev/urandom -dc 'A-Za-z0-9' | head -c "$1"; }

install() {
    INSTALL_DIR="/var/www/Moon"
    ENV_FILE="$INSTALL_DIR/.env"
    NGINX_CONF="/etc/nginx/sites-available/moon_network"

    clear
    echo -e "${CYAN}Moon Network Installation :))${RESET}"

    # =========================
    # Inputs
    # =========================
    read -p "Enter app name (default: Moon): " APPNAME
    APPNAME=${APPNAME:-Moon}

    read -p "Enter your domain (e.g., example.com): " DOMAIN

    read -p "Enter SSL email (Certbot): " SSL_EMAIL
    until validate_email "$SSL_EMAIL"; do
    echo -e "${RED}Invalid email format.${RESET}"
    read -p "Enter valid SSL email: " SSL_EMAIL
    done

    read -p "Enter database name (default: moon_db): " MAINDB
    MAINDB=${MAINDB:-moon_db}


    read -p "Enter database username (default: moon_user): " DB_USER
    DB_USER=${DB_USER:-moon_user}


    read -sp "Enter database user password (leave empty to generate one): " DB_PASSWORD
    echo ""
    DB_PASSWORD=${DB_PASSWORD:-$(rand 12)}


    MYSQL_ROOT_PASSWORD=$(rand 12)
    DATA_ENCRYPTION_KEY=$(rand 32)
    MARZBAN_WEBHOOK_SECRET=$(rand 32)

    # =========================
    # System update & deps
    # =========================
    echo -e "${CYAN}Updating system packages...${RESET}"
    apt-get update -y

    # Disable Apache to avoid conflict with Nginx
    echo -e "${CYAN}Disabling Apache if it exists...${RESET}"
    sleep 0.5
    
    # Disable Apache if exists
    if systemctl list-unit-files | grep -q apache2.service; then
    systemctl stop apache2 2>/dev/null || true
    systemctl disable apache2 2>/dev/null || true
    systemctl mask apache2 2>/dev/null || true
    fi

    # Install dependencies (idempotent)
    echo -e "${CYAN}Installing required dependencies...${RESET}"
    
    # NGINX
    sudo apt-get install -y nginx
    # PHP
    sudo apt-get install -y php php-cli php-fpm php-mbstring php-xml php-curl php-mysql php-zip php-bcmath
    # Git Zip Curl
    sudo apt-get install -y git unzip curl
    #MYSQL
    sudo apt-get install -y mysql-server
    sudo systemctl start mysql
    #COMPOSER
    sudo apt-get install -y composer
    #REDIS
    sudo apt install redis-server -y
    sudo apt install php-redis -y
    #Supervisor
    sudo apt-get install -y supervisor

    # =========================
    # Clone project
    # =========================
    if [ ! -d "$INSTALL_DIR" ]; then
    echo -e "${CYAN}Cloning project...${RESET}"
    git clone git@github.com:ezreza/Moon.git "$INSTALL_DIR"
    fi
    cd "$INSTALL_DIR"

    # =========================
    # Composer
    # =========================
    echo -e "${CYAN}Installing Composer dependencies...${RESET}"
    COMPOSER_ALLOW_SUPERUSER=1 composer install --optimize-autoloader --no-dev

    # =========================
    # Environment (.env)
    # =========================
    if [ ! -f .env ]; then
    cp .env.example .env
    fi

    sed -i "s|^APP_NAME=.*|APP_NAME=$APPNAME|" .env
    sed -i "s|^APP_ENV=.*|APP_ENV=production|" .env
    sed -i "s|^APP_DEBUG=.*|APP_DEBUG=false|" .env
    sed -i "s|^APP_URL=.*|APP_URL=https://$DOMAIN|" .env
    sed -i "s|^DB_CONNECTION=.*|DB_CONNECTION=mysql|" .env
    sed -i "s|^DB_DATABASE=.*|DB_DATABASE=$MAINDB|" .env
    sed -i "s|^DB_USERNAME=.*|DB_USERNAME=$DB_USER|" .env
    sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=$DB_PASSWORD|" .env

    # secrets (append if missing)
    grep -q '^MYSQL_ROOT_PASSWORD=' .env || echo "MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD" >> .env
    grep -q '^DATA_ENCRYPTION_KEY=' .env || echo "DATA_ENCRYPTION_KEY=$DATA_ENCRYPTION_KEY" >> .env
    grep -q '^MARZBAN_WEBHOOK_SECRET=' .env || echo "MARZBAN_WEBHOOK_SECRET=$MARZBAN_WEBHOOK_SECRET" >> .env

    # =========================
    # Laravel setup
    # =========================
    php artisan key:generate --force
    php artisan storage:link || true

    chown -R www-data:www-data "$INSTALL_DIR"
    chmod -R 775 storage bootstrap/cache

    # =========================
    # Nginx
    # =========================
    if [ ! -f "$NGINX_CONF" ]; then
        cp nginx/Moon.conf "$NGINX_CONF"
        ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
    fi

    sed -i "s/server_name .*/server_name $DOMAIN;/" "$NGINX_CONF"
    nginx -t && systemctl reload nginx

    # =========================
    # MySQL
    # =========================
mysql <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$MYSQL_ROOT_PASSWORD';
CREATE DATABASE IF NOT EXISTS $MAINDB;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON $MAINDB.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

    # =========================
    # Migrations & cache
    # =========================
    php artisan migrate --force
    php artisan config:clear
    php artisan config:cache
    php artisan route:cache
    php artisan view:cache

    # =========================
    # Cron (deduplicated)
    # =========================
    (crontab -l 2>/dev/null | grep -v 'artisan schedule:run'; \
    echo "* * * * * cd $INSTALL_DIR && php artisan schedule:run >> /dev/null 2>&1") | crontab -


    # =========================
    # Supervisor (queue)
    # =========================
    SUPERVISOR_CONF="/etc/supervisor/conf.d/laravel-queue-worker.conf"
    cat > "$SUPERVISOR_CONF" <<EOF
[program:laravel-queue-worker]
command=php $INSTALL_DIR/artisan queue:work --tries=3 --timeout=90
autostart=true
autorestart=true
user=www-data
redirect_stderr=true
stdout_logfile=$INSTALL_DIR/storage/logs/queue-worker.log
EOF

    supervisorctl reread
    supervisorctl update
    supervisorctl restart laravel-queue-worker || true

    # =========================
    # Node.js (only if missing)
    # =========================
    if ! command -v node >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
    fi

    npm ci
    npm run build

    #clear

    # =========================
    # Certbot (with DNS check)
    # =========================
    if ! ping -c1 "$DOMAIN" >/dev/null 2>&1; then
    echo -e "${RED}Domain does not resolve to this server. Fix DNS first.${RESET}"
    exit 1
    fi

    apt-get install -y certbot python3-certbot-nginx

    if certbot certificates | grep -q "$DOMAIN"; then
    echo -e "${GREEN}SSL certificate already exists for $DOMAIN.${RESET}"
    else
    certbot --nginx -n --agree-tos --email "$SSL_EMAIL" -d "$DOMAIN"
    certbot renew --dry-run
    fi

    # =========================
    # Done
    # =========================
    clear
    echo -e "${GREEN}Installation completed successfully 🎉${RESET}"
    echo "--------------------------------------------"
    echo "MySQL Root Password: $MYSQL_ROOT_PASSWORD"
    echo "Database Name: $MAINDB"
    echo "Database User: $DB_USER"
    echo "Database Password: $DB_PASSWORD"
    echo "--------------------------------------------"
    echo -e "${YELLOW}https://$DOMAIN${RESET}"

    rm -- "$0"
}

key() {
    clear
    echo -e "${CYAN}Setting up SSH key for GitHub...${RESET}"

    read -p "Enter your SSH key name (default: moon-admin): " SSH_KEY_NAME
    SSH_KEY_NAME=${SSH_KEY_NAME:-moon-admin}

    mkdir -p ~/.ssh
    cd ~/.ssh || {
        echo -e "${RED}Failed to access ~/.ssh directory.${RESET}"

        exit 1
    }

    ssh-keygen -t rsa -b 4096 -C "moon-admin" -f "$SSH_KEY_NAME" -N ""

    echo -e "${GREEN}Public SSH Key${RESET} ${YELLOW}(Add this to GitHub):${RESET}\n"
    cat "$SSH_KEY_NAME.pub"
    echo -e "Host github.com\n\tIdentityFile ~/.ssh/$SSH_KEY_NAME\n" >>~/.ssh/config

    chmod 600 ~/.ssh/config
    chmod 600 ~/.ssh/"$SSH_KEY_NAME"
    chmod 644 ~/.ssh/"$SSH_KEY_NAME.pub"

    echo -n -e "\n${YELLOW}Have you added the SSH key to GitHub? (Press Enter to confirm): ${RESET}"
    read -r CONFIRMATION
    CONFIRMATION=${CONFIRMATION:-y}

    if [[ "$CONFIRMATION" =~ ^[Yy]$ ]]; then
        echo -e "Testing SSH connection with GitHub..."
        sleep 1
        ssh -T git@github.com
    else
        echo -e "${RED}SSH key not added to GitHub. Skipping test.${RESET}"
    fi
}

if [ "$1" == "install" ]; then
    install
elif [ "$1" == "key" ]; then
    key
elif [ "$1" == "remove" ]; then
    remove
else
    echo "Usage: $0 {install|key|remove}"
    exit 1
fi
