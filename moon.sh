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

# =========================
# Helpers
# =========================
validate_email() {
    [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

rand() { tr </dev/urandom -dc 'A-Za-z0-9' | head -c "$1"; }

# =========================
# Install
# =========================
install() {
    INSTALL_DIR="/var/www/Moon"
    ENV_FILE="$INSTALL_DIR/.env"
    NGINX_CONF="/etc/nginx/sites-available/moon_network"

    clear
    echo -e "${CYAN}Moon Network Installation :))${RESET}"

    # Inputs
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

    # System update & deps
    echo -e "${CYAN}Updating system packages...${RESET}"
    apt-get update -y

    # Disable Apache
    echo -e "${CYAN}Disabling Apache if it exists...${RESET}"
    if systemctl list-unit-files | grep -q apache2.service; then
        systemctl stop apache2 2>/dev/null || true
        systemctl disable apache2 2>/dev/null || true
        systemctl mask apache2 2>/dev/null || true
    fi

    # Install dependencies (idempotent)
    echo -e "${CYAN}Installing required dependencies...${RESET}"
    apt-get install -y nginx php php-cli php-fpm php-mbstring php-xml php-curl php-mysql php-zip php-bcmath git unzip curl mysql-server composer redis-server php-redis supervisor

    # Clone project
    if [ ! -d "$INSTALL_DIR" ]; then
        echo -e "${CYAN}Cloning project...${RESET}"
        git clone git@github.com:ezreza/Moon.git "$INSTALL_DIR"
    fi
    cd "$INSTALL_DIR"

    # Composer
    echo -e "${CYAN}Installing Composer dependencies...${RESET}"
    COMPOSER_ALLOW_SUPERUSER=1 composer install --optimize-autoloader --no-dev

    # Environment (.env)
    if [ ! -f .env ]; then cp .env.example .env; fi
    sed -i "s/DB_CONNECTION=.*/DB_CONNECTION=mysql/" .env
    sed -i "s/DB_DATABASE=.*/DB_DATABASE=$MAINDB/" .env
    sed -i "s/DB_USERNAME=.*/DB_USERNAME=$DB_USER/" .env
    sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=$DB_PASSWORD/" .env
    sed -i "s|^APP_NAME=.*|APP_NAME=$APPNAME|" .env
    sed -i "s|^DATA_ENCRYPTION_KEY=.*|DATA_ENCRYPTION_KEY=$DATA_ENCRYPTION_KEY|" .env
    sed -i "s|^MARZBAN_WEBHOOK_SECRET=.*|MARZBAN_WEBHOOK_SECRET=$MARZBAN_WEBHOOK_SECRET|" .env

    if ! grep -q "^MYSQL_ROOT_PASSWORD=" "$ENV_FILE"; then
        echo -e "\n# Database configuration\nMYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD" >>"$ENV_FILE"
    else
        MYSQL_ROOT_PASSWORD=$(grep -E '^MYSQL_ROOT_PASSWORD=' "$ENV_FILE" | cut -d '=' -f2)
    fi

    # Laravel setup
    php artisan key:generate --force
    php artisan storage:link || true
    chown -R www-data:www-data "$INSTALL_DIR"
    chmod -R 775 storage bootstrap/cache

    # Nginx
    if [ ! -f "$NGINX_CONF" ]; then
        cp nginx/Moon.conf "$NGINX_CONF"
        ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
    fi
    sed -i "s/server_name .*/server_name $DOMAIN;/" "$NGINX_CONF"
    nginx -t && systemctl reload nginx

    # MySQL
mysql <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$MYSQL_ROOT_PASSWORD';
CREATE DATABASE IF NOT EXISTS $MAINDB;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON $MAINDB.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

    # Migrations & cache
    php artisan migrate --force
    php artisan config:clear
    php artisan config:cache
    php artisan route:cache
    php artisan view:cache

    # Cron
    (crontab -l 2>/dev/null | grep -v 'artisan schedule:run'; \
    echo "* * * * * cd $INSTALL_DIR && php artisan schedule:run >> /dev/null 2>&1") | crontab -

    # Supervisor (queue)
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

    # Node.js
    if ! command -v node >/dev/null 2>&1; then
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y nodejs
    fi
    npm ci
    npm run build

    # Certbot
    if ! ping -c1 "$DOMAIN" >/dev/null 2>&1; then
        echo -e "${RED}Domain does not resolve to this server. Fix DNS first.${RESET}"
        exit 1
    fi
    apt-get install -y certbot python3-certbot-nginx
    if ! certbot certificates | grep -q "$DOMAIN"; then
        certbot --nginx -n --agree-tos --email "$SSL_EMAIL" -d "$DOMAIN"
        certbot renew --dry-run
    fi

    # Done
    clear
    echo -e "${GREEN}Installation completed successfully 🎉${RESET}"
    echo "--------------------------------------------"
    echo "MySQL Root Password: $MYSQL_ROOT_PASSWORD"
    echo "Database Name:       $MAINDB"
    echo "Database User:       $DB_USER"
    echo "Database Password:   $DB_PASSWORD"
    echo "--------------------------------------------"
    echo -e "${YELLOW}https://$DOMAIN${RESET}"

    rm -- "$0"
}

# =========================
# Uninstall
# =========================
uninstall() {
    INSTALL_DIR="/var/www/Moon"
    ENV_FILE="$INSTALL_DIR/.env"
    NGINX_CONF="/etc/nginx/sites-available/moon_network"
    SUPERVISOR_CONF="/etc/supervisor/conf.d/laravel-queue-worker.conf"

    echo -e "${RED}WARNING: This will completely remove Moon Network, database, and all related files!${RESET}"
    read -p "Type YES to continue: " CONFIRM
    if [[ "$CONFIRM" != "YES" ]]; then
        echo "Aborted."
        exit 1
    fi

    # =========================
    # Extract DB credentials from .env if exists
    # =========================
    if [ -f "$ENV_FILE" ]; then
        MYSQL_ROOT_PASSWORD=$(grep -E '^MYSQL_ROOT_PASSWORD=' "$ENV_FILE" | cut -d '=' -f2)
        MAINDB=$(grep -E '^DB_DATABASE=' "$ENV_FILE" | cut -d '=' -f2)
        DB_USER=$(grep -E '^DB_USERNAME=' "$ENV_FILE" | cut -d '=' -f2)
    else
        read -sp "Enter MySQL root password: " MYSQL_ROOT_PASSWORD
        echo ""
        read -p "Enter database name to drop: " MAINDB
        read -p "Enter database user to drop: " DB_USER
    fi

    echo -e "${CYAN}Stopping services...${RESET}"
    supervisorctl stop laravel-queue-worker || true
    systemctl stop nginx || true

    echo -e "${CYAN}Removing Cron jobs...${RESET}"
    crontab -l 2>/dev/null | grep -v 'artisan schedule:run' | crontab -

    echo -e "${CYAN}Removing project files...${RESET}"
    rm -rf "$INSTALL_DIR"

    echo -e "${CYAN}Dropping MySQL database and user...${RESET}"
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<EOF
DROP DATABASE IF EXISTS $MAINDB;
DROP USER IF EXISTS '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

    echo -e "${CYAN}Removing Nginx and Supervisor configs...${RESET}"
    rm -f "$NGINX_CONF"
    rm -f /etc/nginx/sites-enabled/moon_network
    rm -f "$SUPERVISOR_CONF"

    echo -e "${CYAN}Reloading services...${RESET}"
    systemctl reload nginx || true
    supervisorctl reread
    supervisorctl update

    echo -e "${GREEN}Moon Network has been completely removed.${RESET}"
}


# =========================
# SSH Key setup
# =========================
key() {
    clear
    echo -e "${CYAN}Setting up SSH key for GitHub...${RESET}"

    read -p "Enter your SSH key name (default: moon-admin): " SSH_KEY_NAME
    SSH_KEY_NAME=${SSH_KEY_NAME:-moon-admin}

    mkdir -p ~/.ssh
    cd ~/.ssh || exit 1

    ssh-keygen -t rsa -b 4096 -C "moon-admin" -f "$SSH_KEY_NAME" -N ""

    echo -e "${GREEN}Public SSH Key${RESET} (Add this to GitHub):"
    cat "$SSH_KEY_NAME.pub"
    echo -e "Host github.com\n\tIdentityFile ~/.ssh/$SSH_KEY_NAME\n" >>~/.ssh/config

    chmod 600 ~/.ssh/config
    chmod 600 ~/.ssh/"$SSH_KEY_NAME"
    chmod 644 ~/.ssh/"$SSH_KEY_NAME.pub"

    read -n1 -r -p $'\nHave you added the SSH key to GitHub? Press Enter to continue...'
    ssh -T git@github.com || true
}

# =========================
# Main
# =========================
if [ "$1" == "install" ]; then
    install
elif [ "$1" == "key" ]; then
    key
elif [ "$1" == "remove" ]; then
    uninstall
else
    echo "Usage: $0 {install|key|remove}"
    exit 1
fi
