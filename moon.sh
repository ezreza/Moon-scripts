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
        echo -e "${RED}Error: Domin and Secure Domain must not be the same.${RESET}"
        return 1
    fi
    return 0
}

validate_no_spaces() {
    if [[ "$1" =~ \  ]]; then
        echo -e "${RED}Error: $2 should not contain spaces.${RESET}"
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
    echo -e "${CYAN}Moon Network Installation...${RESET}"
    read -p "Enter your domain (e.g., example.com): " DOMAIN

    while true; do
        read -p "Enter your secure domain (or subdomain) (e.g., sec.example.com): " SECURE_DOMAIN

        if ! validate_domain "$DOMAIN" "$SECURE_DOMAIN"; then
            continue
        fi
        break
    done

    read -p "Enter database name: " MAINDB
    read -p "Enter database username: " DB_USER
    read -sp "Enter database user password: " DB_PASSWORD
    echo ""

    # Update and upgrate system
    echo -e "${CYAN}Updating system packages...${RESET}"
    sleep 0.5
    sudo apt-get update -y
    sudo apt-get upgrade -y

    clear

    # Dependencies
    echo -e "${CYAN}Installing required dependencies...${RESET}"
    sleep 0.5
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

    clear

    # Clone project
    echo -e "${CYAN}Cloning project from GitHub...${RESET}"
    sleep 0.5

    if [ -d "/var/www/Moon" ]; then
        echo "Directory /var/www/Moon exists. Removing it..."
        rm -rf /var/www/Moon
        echo "Directory removed."
    fi

    cd /var/www
    git clone git@github.com:ezreza/Moon.git
    cd Moon
    echo -e "${YELLOW}Repositories Cloned.${RESET}"
    wait

    clear

    # Composer dependencies
    echo -e "${CYAN}Installing Laravel dependencies with Composer...${RESET}"
    sleep 0.5

    composer install --optimize-autoloader --no-dev

    # Environment
    echo "Configuring environment variables..."
    cp .env.example .env
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

    clear

    # remove Apache
    echo -e "${CYAN}Checking if Apache is installed...${RESET}"
    sleep 0.5

    if dpkg -l | grep -q apache2; then
        echo "Stopping Apache service..."
        sudo systemctl stop apache2
        sudo systemctl disable apache2

        echo "Removing Apache and related packages..."
        sudo apt-get purge -y apache2 apache2-utils apache2-bin apache2.2-common apache2-doc apache2-data libapache2-mod-php

        echo "Cleaning up dependencies..."
        sudo apt-get autoremove -y
        sudo apt-get autoclean -y

        echo "Removing leftover files..."
        sudo rm -rf /etc/apache2 /var/www/html

        echo "Apache has been completely removed!"
    else
        echo "Apache is not installed. Skipping removal..."
    fi

    clear

    # Config Nginx
    echo -e "${CYAN}Configuring Nginx...${RESET}"
    sleep 0.5

    NGINX_CONF="/etc/nginx/sites-available/moon_network"
    sudo cp /var/www/Moon/nginx/Moon.conf "$NGINX_CONF"
    sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/

    if [ ! -f "$NGINX_CONF" ]; then
        echo -e "${RED}Error: Nginx configuration file not found at $NGINX_CONF${RESET}"
        exit 1
    fi

    sed -i "s/server_name [^;]*/server_name $DOMAIN/" "$NGINX_CONF"

    echo "Restarting Nginx..."
    sudo nginx -t && sudo systemctl restart nginx

    clear

    # MySQL root
    echo -e "${CYAN}Configuring MySQL root user...${RESET}"
    sleep 0.5

    sudo mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$MYSQL_ROOT_PASSWORD';
FLUSH PRIVILEGES;
EOF
    echo -e "${YELLOW}Root user configured!${RESET}"

    # MySQL Config
    echo -e "${CYAN}Creating MySQL database and user...${RESET}"
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<EOF
CREATE DATABASE IF NOT EXISTS $MAINDB;
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON $MAINDB.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
    echo -e "${YELLOW}Database $MAINDB and user $DB_USER created successfully!${RESET}"

    clear

    # Running migrations
    echo -e "${CYAN}Running database migrations...${RESET}"
    sleep 0.5
    php artisan migrate

    clear

    # Setting up Cronjob
    echo -e "${CYAN}Setting up Cronjob and supervisor...${RESET}"
    sleep 0.5

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
    echo -e "${CYAN}Installing Node.js 18...${RESET}"
    sleep 0.5
    curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
    sudo apt-get install -y nodejs
    npm install
    npm run build

    clear

    # PhpMyAdmin
    set -e
    echo -e "${CYAN}Installing phpMyAdmin...${RESET}"
    sleep 0.5

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

    echo -e "${YELLOW}Installing phpMyAdmin...${RESET}"
    sudo nginx -t && sudo systemctl restart nginx

    clear

    # Certbot
    echo -e "${CYAN}Installing Certbot...${RESET}"
    sleep 0.5

    sudo apt install -y certbot python3-certbot-nginx
    echo "Requesting SSL certificate..."
    sudo certbot --nginx -d $DOMAIN -d www.$DOMAIN -d $SECURE_DOMAIN

    if sudo certbot certificates | grep -q "$DOMAIN"; then
        echo -e "${YELLOW}SSL successfully installed for $DOMAIN and $SECURE_DOMAIN!${RESET}"
    else
        echo -e "${RED}Error: SSL installation failed!${RESET}"
        exit 1
    fi

    echo "Checking automatic SSL renewal..."
    sudo certbot renew --dry-run
    echo -e "${YELLOW}SSL setup completed!${RESET}"

    sleep 0.5

    clear
    echo "Your MySQL credentials (SAVE THEM SAFELY!):"
    echo "--------------------------------------------"
    echo " MySQL Root Password: $MYSQL_ROOT_PASSWORD"
    echo " Database Name:       $MAINDB"
    echo " Database User:       $DB_USER"
    echo " Database Password:   $DB_PASSWORD"
    echo "--------------------------------------------"
    echo -e "Application Available at: ${CYAN}https://$DOMAIN${RESET}"
    echo -e "PhpMyAdmin Available at: ${CYAN}https://$SECURE_DOMAIN/phpmyadmin${RESET}"

    unset MYSQL_ROOT_PASSWORD
    unset MAINDB
    unset DB_USER
    unset DB_PASSWORD

    rm -- "$0"

}

remove() {
    echo "Soon..."
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
    echo "Usage: $0 {install|remove}"
    exit 1
fi
