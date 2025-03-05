#!/bin/bash

# Variable
MYSQL_ROOT_PASSWORD="R8585"
MAINDB="moon_db"
DB_USER="moon_user"
DB_PASSWORD="Reza8585"

# Moon Network Install
echo "Starting Moon Network Installation..."


# Update
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
sudo apt-get install -y phpmyadmin
#REDIS
sudo apt-get install -y redis

# Clone
echo "Cloning project from GitHub..."
cd /var/www
git clone https://github.com/ezreza/Moon.git
cd Moon


# Composer dependencies
echo "Installing Laravel dependencies with Composer..."
composer install --optimize-autoloader --no-dev


# Environment 
echo "Configuring environment variables..."
cp .env.example .env


# Config Env
sed -i 's/^# DB_HOST/DB_HOST/' .env
sed -i 's/^# DB_PORT/DB_PORT/' .env
sed -i 's/^# DB_DATABASE/DB_DATABASE/' .env
sed -i 's/^# DB_USERNAME/DB_USERNAME/' .env
sed -i 's/^# DB_PASSWORD/DB_PASSWORD/' .env

# جایگزینی مقادیر جدید در .env
sed -i 's/DB_CONNECTION=.*/DB_CONNECTION=mysql/' .env
sed -i "s/DB_DATABASE=.*/DB_DATABASE=$MAINDB/" .env
sed -i "s/DB_USERNAME=.*/DB_USERNAME=$DB_USER/" .env
sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=$DB_PASSWORD/" .env

# application key
echo "Generating Laravel application key..."
php artisan key:generate


# Permissions
echo "Setting proper file permissions..."
sudo chown -R www-data:www-data /var/www/Moon
sudo chmod -R 775 /var/www/Moon/storage /var/www/Moon/bootstrap/cache
php artisan storage:link

# Stop and remove apache
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
sudo ln -s /usr/share/phpmyadmin /var/www/Moon/public/phpmyadmin

# Test and restart Nginx
echo "Testing Nginx configuration..."
sudo nginx -t
echo "Restarting Nginx..."
sudo systemctl restart nginx

# MySQL root
echo "Configuring MySQL root user..."
sudo mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY $MYSQL_ROOT_PASSWORD;
FLUSH PRIVILEGES;
EOF
echo "root user confided!"

# MySQL Config
echo "Creating MySQL database and user..."
mysql -uroot -p$MYSQL_ROOT_PASSWORD <<EOF
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
(crontab -l ; echo "* * * * * cd /var/www/laravel && php artisan schedule:run >> /dev/null 2>&1") | crontab -


# Node.js 18
echo "Installing Node.js 18..."
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs
echo "Node.js version: $(node -v)"
echo "NPM version: $(npm -v)"
npm install
npm run build

echo "✅ Setup completed successfully!"