#!/bin/bash

# ========================================================================================
# VCF Offline Depot - Internal CA (Combined CRT)
# Server: depot.rainpole.io | Disk: /dev/sdb (500GB)
# Uses depot.rainpole.io.crt file and depot.rainpole.io.key file from /tmp/certs location
# =================================================================

DOMAIN="depot.rainpole.io"
AUTH_USER="depot-user"
AUTH_PASS="VMw@re1!"
TARGET_DISK="/dev/sdb"
MOUNT_POINT="/var/www/$DOMAIN/html"

# Source location where you uploaded your files
SOURCE_CERT="/tmp/certs/depot.rainpole.io.crt"
SOURCE_KEY="/tmp/certs/depot.rainpole.io.key"

# 1. Root Check
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (use sudo)"
   exit 1
fi

echo "--- [1/7] Storage Setup: Partitioning /dev/sdb ---"
if [ ! -b "$TARGET_DISK" ]; then
    echo "Error: $TARGET_DISK not found. Ensure the 500GB disk is attached."
    exit 1
fi

# Wipe, Partition, and Format
umount ${TARGET_DISK}1 2>/dev/null
wipefs -a $TARGET_DISK
echo "type=83" | sfdisk $TARGET_DISK
mkfs.ext4 -F "${TARGET_DISK}1"

# Mount and Persist
mkdir -p $MOUNT_POINT
mount "${TARGET_DISK}1" $MOUNT_POINT
UUID=$(blkid -s UUID -o value "${TARGET_DISK}1")
if ! grep -q "$UUID" /etc/fstab; then
    echo "UUID=$UUID  $MOUNT_POINT  ext4  defaults  0  2" >> /etc/fstab
fi

echo "--- [2/7] Installing Apache and Utils ---"
apt update && apt install apache2 apache2-utils -y
a2enmod ssl
a2enmod headers
a2enmod rewrite

echo "--- [3/7] Installing SSL Certificates ---"
mkdir -p /etc/apache2/ssl

if [[ -f "$SOURCE_CERT" && -f "$SOURCE_KEY" ]]; then
    cp "$SOURCE_CERT" /etc/apache2/ssl/depot.crt
    cp "$SOURCE_KEY" /etc/apache2/ssl/depot.key
    
    # Set secure permissions
    chmod 600 /etc/apache2/ssl/depot.key
    chmod 644 /etc/apache2/ssl/depot.crt
    chown root:root /etc/apache2/ssl/depot.*
else
    echo "Error: Certificate files not found in /tmp/certs/"
    exit 1
fi

echo "--- [4/7] Setting up Basic Authentication ---"
# This creates the user depot-user with password VMw@re1!
htpasswd -b -c /etc/apache2/.htpasswd $AUTH_USER $AUTH_PASS

echo "--- [5/7] Creating Apache Virtual Host ---"
# Disable default site to prevent conflicts
a2dissite 000-default.conf 2>/dev/null

cat <<EOF > /etc/apache2/sites-available/$DOMAIN.conf
<VirtualHost *:80>
    ServerName $DOMAIN
    # Redirect all HTTP traffic to HTTPS
    RewriteEngine On
    RewriteCond %{HTTPS} off
    RewriteRule ^(.*)\$ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]
</VirtualHost>

<VirtualHost *:443>
    ServerAdmin admin@rainpole.io
    ServerName $DOMAIN
    DocumentRoot $MOUNT_POINT

    SSLEngine on
    # Since your .crt contains the chain, we only need this directive
    SSLCertificateFile /etc/apache2/ssl/depot.crt
    SSLCertificateKeyFile /etc/apache2/ssl/depot.key

    <Directory "$MOUNT_POINT">
        # Enable Directory Indexing for VCF bundles
        Options +Indexes +FollowSymLinks
        AllowOverride None
        
        # Enable Authentication
        AuthType Basic
        AuthName "VCF Offline Depot - Authentication Required"
        AuthUserFile /etc/apache2/.htpasswd
        Require valid-user
    </Directory>

    # Optimization for large bundle downloads
    Timeout 3600
    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF

echo "--- [6/7] Finalizing Configuration ---"
a2ensite $DOMAIN.conf
if ! grep -q "EnableSendfile On" /etc/apache2/apache2.conf; then
    echo "EnableSendfile On" >> /etc/apache2/apache2.conf
fi

echo "--- [7/7] Verifying and Restarting ---"
apache2ctl configtest
systemctl restart apache2

echo "========================================================="
echo " DEPLOYMENT COMPLETE"
echo " URL:         https://$DOMAIN"
echo " Storage:     500GB Mounted at $MOUNT_POINT"
echo " Credentials: $AUTH_USER / $AUTH_PASS"
echo "========================================================="
