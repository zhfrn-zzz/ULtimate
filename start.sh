#!/bin/bash

# ============================================================
#  Proxmox CT Creator + WordPress Auto Installer
#  By: Zhafran | Target: ubuntu-24.04-standard
# ============================================================

set -e  # Stop jika ada error

# ─────────────────────────────────────────
#  KONFIGURASI CT
# ─────────────────────────────────────────
VMID=105
HOSTNAME="zhafran"
PASSWORD="12345678"
STORAGE="local-lvm"           # Untuk disk CT
TEMPLATE_STORAGE="local"      # Tempat template disimpan
TEMPLATE="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
DISK=64                       # GB
CPU=4
MEMORY=2048                   # MB
SWAP=2048                     # MB
IP="192.168.10.5/24"
GW="192.168.10.1"
BRIDGE="vmbr0"

# ─────────────────────────────────────────
#  KONFIGURASI WORDPRESS
# ─────────────────────────────────────────
DB_NAME="wordpress"
DB_USER="wpuser"
DB_PASS='P@ssw0rd123'

# ─────────────────────────────────────────
#  WARNA OUTPUT
# ─────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

echo ""
echo "══════════════════════════════════════════════════"
echo "   Proxmox CT Creator + WordPress Auto Installer  "
echo "══════════════════════════════════════════════════"
echo ""

# ─────────────────────────────────────────
#  CEK: Script harus dijalankan sebagai root
# ─────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    error "Jalankan script ini sebagai root di Proxmox host"
fi

# ─────────────────────────────────────────
#  CEK: VMID sudah dipakai atau belum
# ─────────────────────────────────────────
if pct status $VMID &>/dev/null; then
    error "CT $VMID sudah ada! Ganti VMID atau hapus CT yang lama dengan: pct destroy $VMID"
fi

# ─────────────────────────────────────────
#  CEK: Template tersedia
# ─────────────────────────────────────────
TEMPLATE_PATH="/var/lib/vz/template/cache/$TEMPLATE"
if [ ! -f "$TEMPLATE_PATH" ]; then
    error "Template tidak ditemukan di $TEMPLATE_PATH\nDownload dulu: pveam download local $TEMPLATE"
fi

# ─────────────────────────────────────────
#  STEP 1: Buat CT
# ─────────────────────────────────────────
log "Membuat CT $VMID ($HOSTNAME)..."

pct create $VMID \
    $TEMPLATE_STORAGE:vztmpl/$TEMPLATE \
    --hostname $HOSTNAME \
    --password $PASSWORD \
    --rootfs $STORAGE:$DISK \
    --cores $CPU \
    --memory $MEMORY \
    --swap $SWAP \
    --net0 name=eth0,bridge=$BRIDGE,ip=$IP,gw=$GW \
    --unprivileged 1 \
    --features nesting=1 \
    --ostype ubuntu \
    --start 0

log "CT $VMID berhasil dibuat"

# ─────────────────────────────────────────
#  STEP 2: Start CT
# ─────────────────────────────────────────
log "Menjalankan CT $VMID..."
pct start $VMID

log "Menunggu CT siap (15 detik)..."
sleep 15

# ─────────────────────────────────────────
#  STEP 3: apt update & upgrade
# ─────────────────────────────────────────
log "Menjalankan apt update..."
pct exec $VMID -- bash -c "apt-get update -y"

log "Menjalankan apt upgrade..."
pct exec $VMID -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get upgrade -y"

# ─────────────────────────────────────────
#  STEP 4: Install LAMP Stack
# ─────────────────────────────────────────
log "Menginstall Apache, MySQL, PHP dan extension WordPress..."
pct exec $VMID -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y \
    apache2 \
    mysql-server \
    php \
    php-mysql \
    php-curl \
    php-gd \
    php-mbstring \
    php-xml \
    php-zip \
    libapache2-mod-php"

# ─────────────────────────────────────────
#  STEP 5: Buat Database WordPress
# ─────────────────────────────────────────
log "Membuat database dan user MySQL..."
pct exec $VMID -- bash -c "mysql -e \"
    CREATE DATABASE $DB_NAME DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
    GRANT ALL ON $DB_NAME.* TO '$DB_USER'@'localhost';
    FLUSH PRIVILEGES;
\""

log "Database '$DB_NAME' dan user '$DB_USER' berhasil dibuat"

# ─────────────────────────────────────────
#  STEP 6: Download & Install WordPress
# ─────────────────────────────────────────
log "Mendownload WordPress versi terbaru..."
pct exec $VMID -- bash -c "
    cd /tmp && \
    wget -q https://wordpress.org/latest.tar.gz && \
    tar -xzf latest.tar.gz
"

log "Memindahkan WordPress ke /var/www/html/..."
pct exec $VMID -- bash -c "
    mv /tmp/wordpress /var/www/html/ && \
    chown -R www-data:www-data /var/www/html/wordpress && \
    chmod -R 755 /var/www/html/wordpress
"

# ─────────────────────────────────────────
#  STEP 7: Konfigurasi wp-config.php
# ─────────────────────────────────────────
log "Mengkonfigurasi wp-config.php..."
pct exec $VMID -- bash -c "
    cd /var/www/html/wordpress && \
    cp wp-config-sample.php wp-config.php && \
    sed -i 's|database_name_here|$DB_NAME|' wp-config.php && \
    sed -i 's|username_here|$DB_USER|' wp-config.php && \
    sed -i 's|password_here|$DB_PASS|' wp-config.php
"

# ─────────────────────────────────────────
#  STEP 8: Konfigurasi Apache
# ─────────────────────────────────────────
log "Mengkonfigurasi Apache Virtual Host..."
pct exec $VMID -- bash -c "cat > /etc/apache2/sites-available/000-default.conf << 'APACHECONF'
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html/wordpress

    <Directory /var/www/html/wordpress>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
APACHECONF"

log "Mengaktifkan mod_rewrite dan restart Apache..."
pct exec $VMID -- bash -c "a2enmod rewrite && systemctl restart apache2"

# ─────────────────────────────────────────
#  SELESAI
# ─────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════"
echo -e "${GREEN}   INSTALASI SELESAI!${NC}"
echo "══════════════════════════════════════════════════"
echo ""
echo "  CT ID      : $VMID"
echo "  Hostname   : $HOSTNAME"
echo "  IP Address : ${IP%/*}"
echo "  DB Name    : $DB_NAME"
echo "  DB User    : $DB_USER"
echo "  DB Pass    : $DB_PASS"
echo ""
echo "  Buka browser dan akses:"
echo -e "  ${GREEN}http://${IP%/*}${NC}"
echo ""
echo "  Lanjutkan wizard WordPress di browser untuk"
echo "  menyelesaikan setup nama situs & akun admin."
echo "══════════════════════════════════════════════════"
