#!/bin/bash

# ROOT
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

install() {
    # Generate
    MYSQL_ROOT_PASSWORD=$(openssl rand -base64 12)
    DATA_ENCRYPTION_KEY=$(openssl rand -base64 32)

    clear

    # Getting user input for MySQL database and user
    echo "Moon Network Installation..."
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
    #PhpMyAdmin
    #sudo apt-get install -y phpmyadmin
    #REDIS
    sudo apt-get install -y redis

    clear

    # Clone project
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

    # جایگزینی مقادیر جدید در .env
    sed -i 's/^# DB_HOST/DB_HOST/' .env
    sed -i 's/^# DB_PORT/DB_PORT/' .env
    sed -i 's/^# DB_DATABASE/DB_DATABASE/' .env
    sed -i 's/^# DB_USERNAME/DB_USERNAME/' .env
    sed -i 's/^# DB_PASSWORD/DB_PASSWORD/' .env

    sed -i 's/DB_CONNECTION=.*/DB_CONNECTION=mysql/' .env
    sed -i "s/DB_DATABASE=.*/DB_DATABASE=$MAINDB/" .env
    sed -i "s/DB_USERNAME=.*/DB_USERNAME=$DB_USER/" .env
    sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=$DB_PASSWORD/" .env

    # اضافه کردن کلید رمزنگاری به .env
    sed -i "s/^DATA_ENCRYPTION_KEY=.*/DATA_ENCRYPTION_KEY=$DATA_ENCRYPTION_KEY/" .env

    # application key
    echo "Generating Laravel application key..."
    php artisan key:generate

    # Permissions
    echo "Setting proper file permissions..."
    sudo chown -R www-data:www-data /var/www/Moon
    sudo chmod -R 775 /var/www/Moon/storage /var/www/Moon/bootstrap/cache
    php artisan storage:link

    # Stop and remove Apache if installed
    echo "Checking if Apache is installed..."
    if dpkg -l | grep -q apache2; then
        echo "Stopping Apache service..."
        sudo systemctl stop apache2
        sudo systemctl disable apache2
        echo "Removing Apache..."
        sudo apt-get purge -y apache2 apache2-utils apache2-bin apache2.2-common
        sudo apt-get autoremove -y
        sudo rm -rf /etc/apache2 /var/www/html
        echo "Apache has been completely removed!"
    else
        echo "Apache is not installed. Skipping removal..."
    fi

    # Config Nginx
    echo "Configuring Nginx..."
    sudo cp /var/www/Moon/nginx/Moon.conf /etc/nginx/sites-available/moon_network
    sudo ln -s /etc/nginx/sites-available/moon_network /etc/nginx/sites-enabled/

    # Test and restart Nginx
    echo "Testing Nginx configuration..."
    sudo nginx -t
    echo "Restarting Nginx..."
    sudo systemctl restart nginx

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

    # اجرای مهاجرت‌ها
    echo "Running database migrations..."
    php artisan migrate

    # پیکربندی کرون‌جاب برای تسک‌ها (اختیاری)
    echo "Setting up cron job for Laravel scheduler..."
    (
        crontab -l
        echo "* * * * * cd /var/www/Moon && php artisan schedule:run >> /dev/null 2>&1"
    ) | crontab -

    # Node.js 18
    echo "Installing Node.js 18..."
    curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
    sudo apt-get install -y nodejs
    echo "Node.js version: $(node -v)"
    echo "NPM version: $(npm -v)"
    npm install
    npm run build

    clear
    # نمایش اطلاعات مهم در پایان نصب
    echo "🔑 Your MySQL credentials (SAVE THEM SAFELY!):"
    echo "--------------------------------------------"
    echo " MySQL Root Password: $MYSQL_ROOT_PASSWORD"
    echo " Database Name:       $MAINDB"
    echo " Database User:       $DB_USER"
    echo " Database Password:   $DB_PASSWORD"
    echo "--------------------------------------------"
    echo ""
    echo "🚀 Your Moon Network project is installed and ready to use!"

    unset MYSQL_ROOT_PASSWORD
    unset MAINDB
    unset DB_USER
    unset DB_PASSWORD

}

remove() {
    echo "🧹 Removing packages..."
}

# بررسی ورودی پارامتر
if [ "$1" == "install" ]; then
    install
elif [ "$1" == "remove" ]; then
    remove
else
    echo "Usage: $0 {install|remove}"
    exit 1
fi