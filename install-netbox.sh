#!/usr/bin/bash

# Created by Ian Evans, 10/17/2024 - MIT License.

## IMPORTANT THINGS ##
# You must run this script from a directory other than /root. Running in /root will cause the script to fail due to security constraints.
# The allowed hosts definition allows all connections into the Netbox instance, consider restricting it if needed.
# This script needs to be run in bash.
# When creating a container ensure:
# -> Hostname can be customized but should match what's defined herein.
# -> Build with a minimum of 2 CPU cores and 2048MB of RAM.

# To run script: Save as install-netbox.sh in root directory, edit variables and execute "bash install-netbox.sh"

## VARIABLES ##

# Adjust variables as needed. Password is automatically generated and added into all of the config files.
password=$(openssl rand -base64 20)
# Simple netbox user and netboxdb names for user and database.
netboxdb='netboxdb'
netboxuser='netbox'
# Automatically adds hostname into config files.
current_hostname=$(hostname --fqdn)
# Cert Info (Adjust as needed)
state='State' locality='City' org='Acme' common_name='$current_hostname' country='Country'
# Your email address
email='your@email'

## SYSTEM UPDATES, POSTGRES AND REDIS ## 
# Update system packages, install Prostgresql and install Redis.
apt update -y && apt upgrade -y
# Install sudo and other prerequisites for Netbox
apt -y install sudo && sudo apt -y install net-tools postgresql postgresql-common redis
# Start Postgresql
sudo systemctl enable postgresql
sudo systemctl start postgresql
cd /tmp
# Create the user with the specified password
sudo -u postgres psql -c "CREATE USER $netboxuser WITH PASSWORD '$password';"
# Grant all privileges on the database to the user
# Create the database
sudo -u postgres psql -c "CREATE DATABASE $netboxdb OWNER netbox;"
echo "Database '$netboxdb' and user '$netboxuser' created with granted privileges."

# Enable and restart Redis
sudo apt install -y redis-server
# Delete any existing requirepass entries in Redis.conf.
sudo sed -i '/^[requirepass]/d' /etc/redis/redis.conf
# Add new requirepass into Redis.conf.
echo "requirepass $password" >> /etc/redis/redis.conf
# Check Redis.conf is correct using echo AUTH command
sudo systemctl restart redis-server
sudo systemctl enable redis-server
echo AUTH $password | redis-cli

## NETBOX INSTALL SECTION ##
# Install dependencies for Netbox.
apt install -y git python3 python3-pip python3-venv python3-dev pipx build-essential libxml2-dev libxslt1-dev libffi-dev libpq-dev libssl-dev zlib1g-dev

# Create netbox user and set nologin flag
sudo useradd -r -d /opt/netbox -s /usr/sbin/nologin netbox

# Set directories permissions for Netbox.
cd /opt/
git clone https://github.com/netbox-community/netbox.git
sudo chown --recursive netbox /opt/netbox/netbox/media/

# Fixing permissions yet again as Netbox seems to like resetting them!
chown -R netbox:netbox /opt/netbox/
chmod -R 777 /opt/netbox

# Copy Netbox sample config file and rename for production use
cp /opt/netbox/netbox/netbox/configuration_example.py /opt/netbox/netbox/netbox/configuration.py

# Modify configuration.py to set $password, $netboxdb, $netboxuser and ALLOWED_HOSTS
sudo sed -i "/'PASSWORD': ''/s//'PASSWORD': '$password'/" /opt/netbox/netbox/netbox/configuration.py
sudo sed -i "/'PASSWORD': ''/s//'PASSWORD': '$password'/" /opt/netbox/netbox/netbox/configuration.py
sudo sed -i "/'NAME': 'netbox'/s//'NAME': '$netboxdb'/" /opt/netbox/netbox/netbox/configuration.py
sudo sed -i "/'USER': ''/s//'USER': '$netboxuser'/" /opt/netbox/netbox/netbox/configuration.py
sudo sed -i '/ALLOWED_HOSTS/d' /opt/netbox/netbox/netbox/configuration.py
echo "ALLOWED_HOSTS = ['*']" >> /opt/netbox/netbox/netbox/configuration.py

# Generate new secret key for Netbox and place into Netbox config file.
sudo sed -i '/SECRET_KEY/d' /opt/netbox/netbox/netbox/configuration.py
echo "SECRET_KEY = '$(sudo -u netbox python3 /opt/netbox/netbox/generate_secret_key.py)'" >> /opt/netbox/netbox/netbox/configuration.py

# Install Supervisor
sudo apt install supervisor

python3 -m venv /opt/netbox/venv/
. /opt/netbox/venv/bin/activate

# Activate Netbox upgrade.sh script
sudo /opt/netbox/upgrade.sh yes yes python manage.py collectstatic --noinput

# Active Netbox install/upgrade
source /opt/netbox/venv/bin/activate
# Set up some housekeeping scripts.
sudo ln -s /opt/netbox/contrib/netbox-housekeeping.sh /etc/cron.daily/netbox-housekeeping
# Setup Gunicorn.
sudo -u netbox cp /opt/netbox/contrib/gunicorn.py /opt/netbox/gunicorn.py
# Register Netbox services.
sudo cp -v /opt/netbox/contrib/*.service /etc/systemd/system/ && sudo systemctl daemon-reload
sudo systemctl start netbox netbox-rq
sudo systemctl enable netbox netbox-rq
## APACHE AND GUNICORN ##
# Install Apache 2.
sudo apt -y install apache2
# Enable Apache 2 Modules for SSL.
sudo a2enmod ssl proxy proxy_http headers
# Copy Apache configs.
sudo cp /opt/netbox/contrib/apache.conf /etc/apache2/sites-available/netbox.conf
sudo sed -i 's/^\( *\)ServerName.*/\ServerName '$current_hostname'/' /etc/apache2/sites-available/netbox.conf
# Generate SSL new certificate and place into respective directories
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 -subj "/C=$country/ST=$state/L=$locality/O=$org/CN=$common_name" -keyout /etc/ssl/private/netbox.key -out /etc/ssl/certs/netbox.crt
# Run some checks on the Apache configs.
if ! sudo apachectl configtest | grep "Syntax OK"
then
    echo Config looks good continuing...
else
    echo Check your Apache config file and try again...
    exit
fi
# Enable Netbox VirtualHost Site in Apache and add a2enmod.
sudo a2ensite netbox.conf
sudo a2enmod rewrite
# Restart core services
sudo systemctl restart apache2
sudo systemctl restart redis-server
sudo systemctl restart netbox
sudo systemctl restart netbox-rq

# Set superuser for Netbox UI/CLI
source /opt/netbox/venv/bin/activate
DJANGO_SUPERUSER_PASSWORD=$password python3 /opt/netbox/netbox/manage.py createsuperuser --no-input --username $netboxuser --email $email 
echo ""
echo "Your username for the WebUI is: $netboxuser"
echo "Your password for all services and the WebUI is: $password"
