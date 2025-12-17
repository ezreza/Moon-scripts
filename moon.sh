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
# Variables (fixed paths)
# =========================
INSTALL_DIR="/var/www/Moon"
ENV_FILE="$INSTALL_DIR/.env"
NGINX_CONF="/etc/nginx/sites-available/moon_network"
SUPERVISOR_CONF="/etc/supervisor/conf.d/laravel-queue-worker.conf"

# =========================
# Improved Install Function
# =========================
install() {
    clear
    echo -e "${CYAN}Moon Network Installation${RESET}"

    # Inputs
    read -p "Enter app name (default: Moon): " APPNAME
    APPNAME=${APPNAME:-Moon}

    read -p "Enter your domain (e.g., example.com): " DOMAIN
    while [[ -z "$DOMAIN" ]]; do
        echo -e "${RED}Domain cannot be empty.${RESET}"
        read -p "Enter your domain: " DOMAIN
    done

    read -p "Enter SSL email (Certbot): " SSL_EMAIL
    until validate_email "$SSL_EMAIL"; do
        echo -e "${RED}Invalid email format.${RESET}"
        read -p "Enter valid SSL email: " SSL_EMAIL
    done

    read -p "Enter database name (default: moon_db): " MAINDB
    MAINDB=${MAINDB:-moon_db}

    read -p "Enter database username (default: moon_user): " DB_USER
    DB_USER=${DB_USER:-moon_user}

    read -sp "Enter database user password (leave empty to generate): " DB_PASSWORD
    echo
    DB_PASSWORD=${DB_PASSWORD:-$(rand 16)}

    # Generate keys only if not exist
    DATA_ENCRYPTION_KEY=$(rand 32)
    MARZBAN_WEBHOOK_SECRET=$(rand 32)

    # System update & deps (idempotent)
    echo -e "${CYAN}Updating system & installing dependencies...${RESET}"
    apt-get update -y
    apt-get install -y nginx php php-cli php-fpm php-mbstring php-xml php-curl php-mysql php-zip php-bcmath git unzip curl mysql-server composer redis-server php-redis supervisor certbot python3-certbot-nginx

    # Disable Apache if exists
    if systemctl list-unit-files | grep -q apache2.service; then
        systemctl stop apache2 2>/dev/null || true
        systemctl disable apache2 2>/dev/null || true
    fi

    # Node.js 20.x if not installed
    if ! command -v node >/dev/null 2>&1 || [[ $(node -v | cut -d. -f1) != "v20" ]]; then
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y nodejs
    fi

    # Clone project (only if not exists)
    if [ ! -d "$INSTALL_DIR" ]; then
        mkdir -p "$INSTALL_DIR"
        git clone git@github.com:ezreza/Moon.git "$INSTALL_DIR" || { echo -e "${RED}Git clone failed. Check SSH key.${RESET}"; exit 1; }
    fi
    cd "$INSTALL_DIR" || exit 1

    # Composer (as www-data to avoid permission issues)
    echo -e "${CYAN}Installing Composer dependencies...${RESET}"
    #sudo -u www-data composer install --optimize-autoloader --no-dev
    COMPOSER_ALLOW_SUPERUSER=1 composer install --optimize-autoloader --no-dev

    # .env setup (preserve existing values if reinstall)
    if [ ! -f .env ]; then
        cp .env.example .env
    fi

    sed -i 's/^# DB_HOST/DB_HOST/' .env
    sed -i 's/^# DB_PORT/DB_PORT/' .env
    sed -i 's/^# DB_DATABASE/DB_DATABASE/' .env
    sed -i 's/^# DB_USERNAME/DB_USERNAME/' .env
    sed -i 's/^# DB_PASSWORD/DB_PASSWORD/' .env
    sed -i "s/DB_CONNECTION=.*/DB_CONNECTION=mysql/" .env
    sed -i "s/DB_DATABASE=.*/DB_DATABASE=$MAINDB/" .env
    sed -i "s/DB_USERNAME=.*/DB_USERNAME=$DB_USER/" .env
    sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=$DB_PASSWORD/" .env
    sed -i "s|^APP_NAME=.*|APP_NAME=$APPNAME|" .env
    sed -i "s|^DATA_ENCRYPTION_KEY=.*|DATA_ENCRYPTION_KEY=$DATA_ENCRYPTION_KEY|" .env
    sed -i "s|^MARZBAN_WEBHOOK_SECRET=.*|MARZBAN_WEBHOOK_SECRET=$MARZBAN_WEBHOOK_SECRET|" .env

    # Do NOT overwrite app key on reinstall
    if ! grep -q "^APP_KEY=base64:" .env; then
        php artisan key:generate --force
    fi

    # Laravel basics
    php artisan storage:link || true
    chown -R www-data:www-data "$INSTALL_DIR"
    chmod -R 775 storage bootstrap/cache

    # Nginx config
    if [ ! -f "$NGINX_CONF" ]; then
        cp nginx/Moon.conf "$NGINX_CONF"
        ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
    fi
    sed -i "s/server_name .*/server_name $DOMAIN;/" "$NGINX_CONF"
    nginx -t && systemctl reload nginx

    # MySQL setup (safe for reinstall)
    MYSQL_ROOT_PASSWORD=$(rand 16)
    sudo mysql <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$MYSQL_ROOT_PASSWORD';
FLUSH PRIVILEGES;
EOF
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" --batch --silent <<EOF
CREATE DATABASE IF NOT EXISTS $MAINDB;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON $MAINDB.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

    # Save root password for possible future uninstall
    if ! grep -q "^MYSQL_ROOT_PASSWORD=" .env 2>/dev/null; then
        echo -e "\nMYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD" >> .env
    fi

    # Migrations & cache
    php artisan migrate --force
    php artisan config:cache
    php artisan route:cache
    php artisan view:cache

    # Cron
    (crontab -l 2>/dev/null | grep -v 'artisan schedule:run'; echo "* * * * * cd $INSTALL_DIR && php artisan schedule:run >> /dev/null 2>&1") | crontab -

    # Supervisor queue
    cat > "$SUPERVISOR_CONF" <<EOF
[program:laravel-queue-worker]
command=php $INSTALL_DIR/artisan queue:work --tries=3 --timeout=90
directory=$INSTALL_DIR
autostart=true
autorestart=true
user=www-data
redirect_stderr=true
stdout_logfile=$INSTALL_DIR/storage/logs/queue-worker.log
EOF
    supervisorctl reread
    supervisorctl update
    supervisorctl restart laravel-queue-worker || true

    # Frontend build
    npm ci
    npm run build

    # Certbot
    certbot --nginx -n --agree-tos --email "$SSL_EMAIL" -d "$DOMAIN" || echo -e "${YELLOW}Certbot failed or already exists.${RESET}"

    clear
    echo -e "${GREEN}Installation completed successfully 🎉${RESET}"
    echo "--------------------------------------------"
    echo "Database Name:     $MAINDB"
    echo "Database User:     $DB_USER"
    echo "Database Password: $DB_PASSWORD"
    echo "MySQL Root Password: $MYSQL_ROOT_PASSWORD (saved in .env)"
    echo "--------------------------------------------"
    echo -e "${YELLOW}https://$DOMAIN${RESET}"
}

# =========================
# Improved Uninstall (SAFE for reinstall)
# =========================
uninstall() {
    echo -e "${RED}WARNING: This will remove Moon Network and its database ONLY. MySQL server will remain.${RESET}"
    read -p "Type YES to continue: " CONFIRM
    if [[ "$CONFIRM" != "YES" ]]; then
        echo "Aborted."
        exit 0
    fi

    # Read config first (before deleting files)
    if [ -f "$ENV_FILE" ]; then
        MYSQL_ROOT_PASSWORD=$(grep '^MYSQL_ROOT_PASSWORD=' "$ENV_FILE" | cut -d '=' -f2)
        MAINDB=$(grep '^DB_DATABASE=' "$ENV_FILE" | cut -d '=' -f2)
        DB_USER=$(grep '^DB_USERNAME=' "$ENV_FILE" | cut -d '=' -f2)
    else
        echo -e "${YELLOW}.env not found. Skipping database removal.${RESET}"
        MYSQL_ROOT_PASSWORD=""
    fi

    # Stop services
    supervisorctl stop laravel-queue-worker 2>/dev/null || true
    systemctl reload nginx 2>/dev/null || true

    # Remove cron
    (crontab -l 2>/dev/null | grep -v 'artisan schedule:run') | crontab -

    # Drop database & user if we have credentials
    if [[ -n "$MYSQL_ROOT_PASSWORD" && -n "$MAINDB" && -n "$DB_USER" ]]; then
        echo -e "${CYAN}Dropping database and user...${RESET}"
        mysql -uroot -p"$MYSQL_ROOT_PASSWORD" --batch --silent <<EOF
DROP DATABASE IF EXISTS $MAINDB;
DROP USER IF EXISTS '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
    fi

    # Remove project files
    rm -rf "$INSTALL_DIR"

    # Remove configs
    rm -f "$NGINX_CONF" /etc/nginx/sites-enabled/moon_network "$SUPERVISOR_CONF"

    # Clean supervisor & nginx
    supervisorctl reread && supervisorctl update || true
    nginx -t && systemctl reload nginx || true

    echo -e "${GREEN}Moon Network removed successfully. MySQL server is intact for other apps.${RESET}"
    echo -e "${YELLOW}You can now safely reinstall with the same script.${RESET}"
}

# =========================
# SSH Key setup (unchanged)
# =========================
key() {
    clear
    echo -e "${CYAN}Setting up SSH key for GitHub...${RESET}"

    read -p "Enter your SSH key name (default: moon-admin): " SSH_KEY_NAME
    SSH_KEY_NAME=${SSH_KEY_NAME:-moon-admin}

    mkdir -p ~/.ssh
    cd ~/.ssh || exit 1

    ssh-keygen -t rsa -b 4096 -C "moon-admin" -f "$SSH_KEY_NAME" -N ""

    echo -e "${GREEN}Public SSH Key (Add to GitHub):${RESET}"
    cat "$SSH_KEY_NAME.pub"

    echo -e "Host github.com\n\tIdentityFile ~/.ssh/$SSH_KEY_NAME\n" >> ~/.ssh/config
    chmod 600 ~/.ssh/config ~/.ssh/"$SSH_KEY_NAME"
    chmod 644 ~/.ssh/"$SSH_KEY_NAME.pub"

    read -n1 -r -p $'\nAdd key to GitHub then press Enter...'
    ssh -T git@github.com || true
}

# =========================
# Main
# =========================
case "$1" in
    install)
        install
        ;;
    remove|uninstall)
        uninstall
        ;;
    key)
        key
        ;;
    *)
        echo "Usage: $0 {install|remove|key}"
        exit 1
        ;;
esac
