#!/bin/bash

# ROOT
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Define color variables
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"
RESET="\e[0m"

validate_domain() {
    if [[ "$1" == "$2" ]]; then
        echo -e "${RED}❌ Error: DOMAIN and SECURE_DOMAIN must not be the same.${RESET}"
        return 1
    fi
    return 0
}

# Function to check if input contains spaces
validate_no_spaces() {
    if [[ "$1" =~ \  ]]; then
        echo -e "${RED}❌ Error: $2 should not contain spaces.${RESET}"
        return 1
    fi
    return 0
}

install() {
    #MYSQL_ROOT_PASSWORD=$(openssl rand -base64 12)
    MYSQL_ROOT_PASSWORD="EscGOWiCmQaWiWJi"
    DATA_ENCRYPTION_KEY=$(openssl rand -base64 32)

    clear

    # Getting user input for MySQL database and user
    echo "Moon Network Installation..."
    echo -e "${CYAN}Moon Network Installation...${RESET}"
    #read -p "Enter your domain (e.g., example.com): " DOMAIN

    while true; do
        read -p "Enter your secure domain (or subdomain) (e.g., sec.example.com): " SECURE_DOMAIN

        # Check if DOMAIN and SECURE_DOMAIN are the same
        if ! validate_domain "$DOMAIN" "$SECURE_DOMAIN"; then
            continue
        fi
        break
    done

    #read -p "Enter your secure domain (or subdomain) (e.g., sec.example.com): " SECURE_DOMAIN
    read -p "Enter database name: " MAINDB
    read -p "Enter database username: " DB_USER
    read -sp "Enter database user password: " DB_PASSWORD
    echo ""

    # Moon Network Install
    echo "Starting Moon Network Installation..."

    # Update and upgrate system
    echo "Updating system packages..."
    sudo apt-get update -y
    sudo apt-get upgrade -y

    # Dependencies
    echo "Installing required dependencies..."
    # NGINX
    sudo apt-get install -y nginx
    # PHP
    sudo apt-get install -y php php-cli php-fpm php-mbstring php-xml php-curl php-mysql php-zip php-bcmath
    # Git Zip Curl
    sudo apt-get install -y git unzip curl
    #MYSQL
    sudo apt-get install -y mysql-server
    #COMPOSER
    sudo apt-get install -y composer
    #REDIS
    sudo apt-get install -y redis
    #Supervisor
    sudo apt-get install -y supervisor

    # Clone project
    clear
    echo "Cloning project from GitHub..."
    if [ -d "/var/www/Moon" ]; then
        echo "Directory /var/www/Moon exists. Removing it..."
        rm -rf /var/www/Moon
        echo "Directory removed."
    fi

    cd /var/www
    git clone git@github.com:ezreza/Moon.git
    cd Moon
    echo "🚀 Cloned!"
    wait

    # Composer dependencies
    echo "Installing Laravel dependencies with Composer..."
    composer install --optimize-autoloader --no-dev

    # Environment
    echo "Configuring environment variables..."
    cp .env.example .env

    # Config .env
    sed -i 's/^# DB_HOST/DB_HOST/' .env
    sed -i 's/^# DB_PORT/DB_PORT/' .env
    sed -i 's/^# DB_DATABASE/DB_DATABASE/' .env
    sed -i 's/^# DB_USERNAME/DB_USERNAME/' .env
    sed -i 's/^# DB_PASSWORD/DB_PASSWORD/' .env

    sed -i 's/DB_CONNECTION=.*/DB_CONNECTION=mysql/' .env
    sed -i "s/DB_DATABASE=.*/DB_DATABASE=$MAINDB/" .env
    sed -i "s/DB_USERNAME=.*/DB_USERNAME=$DB_USER/" .env
    sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=$DB_PASSWORD/" .env

    sed -i "s/^DATA_ENCRYPTION_KEY=.*/DATA_ENCRYPTION_KEY=$DATA_ENCRYPTION_KEY/" .env

    # Generating key
    echo "Generating Laravel application key..."
    php artisan key:generate

    # Permissions
    echo "Setting proper file permissions..."
    sudo chown -R www-data:www-data /var/www/Moon
    sudo chmod -R 775 /var/www/Moon/storage /var/www/Moon/bootstrap/cache
    php artisan storage:link

    # remove Apache
    echo "🔍 Checking if Apache is installed..."
    if dpkg -l | grep -q apache2; then
        echo "🛑 Stopping Apache service..."
        sudo systemctl stop apache2
        sudo systemctl disable apache2

        echo "🧹 Removing Apache and related packages..."
        sudo apt-get purge -y apache2 apache2-utils apache2-bin apache2.2-common apache2-doc apache2-data libapache2-mod-php

        echo "🔄 Cleaning up dependencies..."
        sudo apt-get autoremove -y
        sudo apt-get autoclean -y

        echo "🗑️ Removing leftover files..."
        sudo rm -rf /etc/apache2 /var/www/html

        echo "✅ Apache has been completely removed!"
    else
        echo "ℹ️ Apache is not installed. Skipping removal..."
    fi

    # Config Nginx
    echo "Configuring Nginx..."
    NGINX_CONF="/etc/nginx/sites-available/moon_network"
    sudo cp /var/www/Moon/nginx/Moon.conf "$NGINX_CONF"
    sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/

    if [ ! -f "$NGINX_CONF" ]; then
        echo "❌ Error: Nginx configuration file not found at $NGINX_CONF"
        exit 1
    fi

    sed -i "s/server_name [^;]*/server_name $DOMAIN/" "$NGINX_CONF"

    echo "Restarting Nginx..."
    sudo nginx -t && sudo systemctl restart nginx

    # MySQL root
    echo "Configuring MySQL root user..."
    sudo mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$MYSQL_ROOT_PASSWORD';
FLUSH PRIVILEGES;
EOF
    echo "Root user configured!"

    # MySQL Config
    echo "Creating MySQL database and user..."
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<EOF
CREATE DATABASE IF NOT EXISTS $MAINDB;
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON $MAINDB.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

    echo "Database $MAINDB and user $DB_USER created successfully!"

    # Running migrations
    echo "Running database migrations..."
    php artisan migrate

    # Setting up Cronjob
    echo "Setting up cron job for Laravel scheduler..."
    (
        crontab -l
        echo "* * * * * cd /var/www/Moon && php artisan schedule:run >> /dev/null 2>&1"
    ) | crontab -

    # Supervisor service
    sudo systemctl enable supervisor
    sudo systemctl start supervisor

    # Setting Worker for Laravel Queue
    SUPERVISOR_CONF="/etc/supervisor/conf.d/laravel-queue-worker.conf"
    echo "Configuring Laravel Queue Worker..."

    sudo bash -c "cat > $SUPERVISOR_CONF" <<EOF
[program:laravel-queue-worker]
process_name=%(program_name)s_%(process_num)02d
command=php /var/www/Moon/artisan queue:work --tries=3 --timeout=90
autostart=true
autorestart=true
numprocs=1
redirect_stderr=true
stdout_logfile=/var/www/Moon/storage/logs/queue-worker.log
EOF

    if [ -f "$SUPERVISOR_CONF" ]; then
        echo "Laravel Queue Worker configuration added successfully!"
        sudo supervisorctl reread
        sudo supervisorctl update
        sudo supervisorctl start laravel-queue-worker
    else
        echo "Error: Failed to create Supervisor configuration file!"
    fi

    # Node.js 18
    echo "Installing Node.js 18..."
    curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
    sudo apt-get install -y nodejs
    echo "Node.js version: $(node -v)"
    echo "NPM version: $(npm -v)"
    npm install
    npm run build

    # PhpMyAdmin
    set -e
    echo "🔍 Installing phpMyAdmin..."

    export DEBIAN_FRONTEND=noninteractive
    sudo apt install -y phpmyadmin php-gd php-json

    sudo phpenmod mbstring
    PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")
    sudo systemctl restart nginx
    sudo systemctl restart php${PHP_VERSION}-fpm

    if [ -d "/usr/share/phpmyadmin" ]; then
        echo "✅ phpMyAdmin installed successfully!"
    else
        echo "❌ Error: phpMyAdmin installation failed!"
        exit 1
    fi

    PHPMYADMIN_NGINX_CONF="/etc/nginx/sites-available/phpmyadmin"

    if [ ! -f "/var/www/Moon/nginx/phpmyadmin.conf" ]; then
        echo "❌ Error: phpMyAdmin Nginx configuration file not found!"
        exit 1
    fi

    sudo cp /var/www/Moon/nginx/phpmyadmin.conf "$PHPMYADMIN_NGINX_CONF"
    sudo ln -sf "$PHPMYADMIN_NGINX_CONF" /etc/nginx/sites-enabled/

    if [ ! -f "$PHPMYADMIN_NGINX_CONF" ]; then
        echo "❌ Error: Nginx configuration file not found at $PHPMYADMIN_NGINX_CONF"
        exit 1
    fi

    sed -i "s/server_name [^;]*/server_name $SECURE_DOMAIN/" "$PHPMYADMIN_NGINX_CONF"

    echo "🔄 Restarting Nginx..."
    sudo nginx -t && sudo systemctl restart nginx

    # Certbot
    echo "🔍 Installing Certbot..."
    sudo apt install -y certbot python3-certbot-nginx
    echo "🔒 Requesting SSL certificate..."
    sudo certbot --nginx -d $DOMAIN -d www.$DOMAIN -d $SECURE_DOMAIN

    if sudo certbot certificates | grep -q "$DOMAIN"; then
        echo "✅ SSL successfully installed for $DOMAIN and $SECURE_DOMAIN!"
    else
        echo "❌ Error: SSL installation failed!"
        exit 1
    fi

    echo "🔄 Checking automatic SSL renewal..."
    sudo certbot renew --dry-run

    echo "✅ SSL setup completed."

    sleep 1

    clear
    echo "Your MySQL credentials (SAVE THEM SAFELY!):"
    echo "--------------------------------------------"
    echo " MySQL Root Password: $MYSQL_ROOT_PASSWORD"
    echo " Database Name:       $MAINDB"
    echo " Database User:       $DB_USER"
    echo " Database Password:   $DB_PASSWORD"
    echo "--------------------------------------------"
    echo -e "Application Available at: \e[1;34mhttps://$DOMAIN\e[0m"
    echo -e "PhpMyAdmin Available at: \e[1;34mhttps://$SECURE_DOMAIN/phpmyadmin\e[0m"

    unset MYSQL_ROOT_PASSWORD
    unset MAINDB
    unset DB_USER
    unset DB_PASSWORD

    rm -- "$0"

}

remove() {
    echo "🧹 Removing packages..."
}

if [ "$1" == "install" ]; then
    install
elif [ "$1" == "phpmyadmin" ]; then
    phpmyadmin
elif [ "$1" == "remove" ]; then
    remove
else
    echo "Usage: $0 {install|remove}"
    exit 1
fi
