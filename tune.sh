#!/bin/bash

# -----------------------
# KONFIGURASI DASAR
# -----------------------
LOG_FILE="/var/log/server-tuning-$(date +%Y%m%d-%H%M%S).log"
BACKUP_DIR="/etc/server-tuning-backups"
BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
WEB_USER="www-data"

# -----------------------
# FUNGSI UTILITAS
# -----------------------
init_logging() {
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
}

log() {
    local level=$1
    local message=$2
    local color=""
    
    case $level in
        "SUCCESS") color="\e[32m" ;;
        "ERROR") color="\e[31m" ;;
        "WARNING") color="\e[33m" ;;
        "INFO") color="\e[36m" ;;
        *) color="\e[0m" ;;
    esac
    
    echo -e "${color}$(date +'%F %T') [${level}] ${message}\e[0m"
}

validate_input() {
    local input=$1
    local min=${2:-1}
    if ! [[ "$input" =~ ^[0-9]+$ ]] || [[ $input -lt $min ]]; then
        log "ERROR" "Input harus angka positif (min $min)"
        return 1
    fi
    return 0
}

# -----------------------
# DETEKSI SISTEM
# -----------------------
detect_system() {
    log "INFO" "Memulai deteksi sistem..."
    
    # Deteksi versi PHP
    PHP_VERSION=$(php -v 2>/dev/null | grep -oP 'PHP \K[0-9]+\.[0-9]+' | head -1)
    if [[ -z "$PHP_VERSION" ]]; then
        log "ERROR" "PHP tidak terdeteksi! Instal PHP terlebih dahulu."
        exit 1
    fi
    
    # Verifikasi Nginx
    if ! systemctl is-active --quiet nginx; then
        log "ERROR" "Nginx tidak aktif!"
        exit 1
    fi
    
    # Deteksi spesifikasi hardware
    SERVER_CPU_CORES=$(nproc)
    SERVER_MEMORY_MB=$(free -m | awk '/Mem:/ {print $2}')
    SERVER_MEMORY_GB=$(( (SERVER_MEMORY_MB + 1023) / 1024 ))
    SERVER_CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d ':' -f2 | sed 's/^[ \t]*//')
    SERVER_DISK_TYPE=$(lsblk -d -o rota | awk 'NR==2 {print $1=="0"?"SSD":"HDD"}')
    
    log "SUCCESS" "System detected:"
    log "INFO" "  PHP Version: ${PHP_VERSION}"
    log "INFO" "  Web Server: Nginx (User: ${WEB_USER})"
    log "INFO" "  CPU Cores: ${SERVER_CPU_CORES} (${SERVER_CPU_MODEL})"
    log "INFO" "  Memory: ${SERVER_MEMORY_GB}GB (${SERVER_MEMORY_MB}MB)"
    log "INFO" "  Disk Type: ${SERVER_DISK_TYPE}"
}

# -----------------------
# BACKUP KONFIGURASI
# -----------------------
backup_configs() {
    log "INFO" "Membuat backup konfigurasi..."
    
    mkdir -p "$BACKUP_DIR/$BACKUP_TIMESTAMP"
    
    local files_to_backup=(
        "/etc/php/${PHP_VERSION}/fpm/php.ini"
        "/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"
        "/etc/nginx/nginx.conf"
        "/etc/security/limits.conf"
        "/etc/sysctl.conf"
    )
    
    for file in "${files_to_backup[@]}"; do
        if [[ -f "$file" ]]; then
            cp "$file" "$BACKUP_DIR/$BACKUP_TIMESTAMP/" && \
            log "INFO" "Backup sukses: $file" || \
            log "ERROR" "Gagal backup: $file"
        else
            log "WARNING" "File tidak ditemukan: $file"
        fi
    done
    
    # Buat archive backup
    tar -czf "$BACKUP_DIR/server-tuning-backup-${BACKUP_TIMESTAMP}.tar.gz" -C "$BACKUP_DIR/$BACKUP_TIMESTAMP" . && \
    log "SUCCESS" "Backup lengkap tersimpan di: $BACKUP_DIR/server-tuning-backup-${BACKUP_TIMESTAMP}.tar.gz"
}

# -----------------------
# PERHITUNGAN RESOURCE
# -----------------------
calculate_resources() {
    log "INFO" "Menghitung alokasi resource..."
    
    # Input dari user
    while true; do
        read -p "Estimasi user concurrent (100-100000): " EXPECTED_USERS
        validate_input "$EXPECTED_USERS" 100 && break
    done
    
    while true; do
        read -p "Tipe workload (1-CPU, 2-Memory, 3-Mixed): " WORKLOAD_TYPE
        validate_input "$WORKLOAD_TYPE" 1 && [[ $WORKLOAD_TYPE -le 3 ]] && break
        log "WARNING" "Masukkan 1, 2, atau 3"
    done
    
    # Faktor penyesuaian
    local cpu_multiplier=$(( 1 + SERVER_CPU_CORES / 8 ))
    local memory_multiplier=$(( SERVER_MEMORY_GB / 4 ))
    
    # Penyesuaian berdasarkan workload type
    case $WORKLOAD_TYPE in
        1)
            cpu_multiplier=$(( cpu_multiplier * 2 ))
            MEMORY_PER_WORKER=$(( 40 + EXPECTED_USERS / 500 ))
        ;;
        2)
            memory_multiplier=$(( memory_multiplier * 2 ))
            MEMORY_PER_WORKER=$(( 60 + EXPECTED_USERS / 300 ))
        ;;
        3)
            MEMORY_PER_WORKER=$(( 50 + EXPECTED_USERS / 400 ))
        ;;
    esac
    
    # Hitung PHP-FPM workers
    local max_children_mem=$(( (SERVER_MEMORY_MB * 70 / 100) / MEMORY_PER_WORKER ))
    local max_children_cpu=$(( SERVER_CPU_CORES * 15 * cpu_multiplier ))
    
    PM_MAX_CHILDREN=$(( max_children_mem < max_children_cpu ? max_children_mem : max_children_cpu ))
    PM_MAX_CHILDREN=$(( PM_MAX_CHILDREN < 20 ? 20 : PM_MAX_CHILDREN ))
    
    PM_START_SERVERS=$(( SERVER_CPU_CORES * 4 * cpu_multiplier ))
    PM_MIN_SPARE_SERVERS=$(( SERVER_CPU_CORES * 2 * cpu_multiplier ))
    PM_MAX_SPARE_SERVERS=$(( SERVER_CPU_CORES * 6 * cpu_multiplier ))
    
    # Hitung parameter PHP
    if [[ $SERVER_MEMORY_GB -lt 2 ]]; then
        PHP_MEMORY_LIMIT="128M"
        elif [[ $SERVER_MEMORY_GB -lt 8 ]]; then
        PHP_MEMORY_LIMIT="$(( SERVER_MEMORY_MB / 8 ))M"
    else
        PHP_MEMORY_LIMIT="$(( SERVER_MEMORY_MB / 12 ))M"
    fi
    
    # Hitung parameter Nginx
    NGINX_WORKER_PROCESSES=$SERVER_CPU_CORES
    [[ $SERVER_CPU_CORES -gt 8 ]] && NGINX_WORKER_PROCESSES=$(( SERVER_CPU_CORES * 2 ))
    
    NGINX_WORKER_CONNECTIONS=$(( PM_MAX_CHILDREN * 3 ))
    [[ $EXPECTED_USERS -gt 5000 ]] && NGINX_WORKER_CONNECTIONS=$(( NGINX_WORKER_CONNECTIONS * 2 ))
    
    # Hitung OPcache memory
    OP_CACHE_MEM=$(( SERVER_MEMORY_MB / 8 ))
    [[ $OP_CACHE_MEM -gt 1024 ]] && OP_CACHE_MEM=1024
    
    log "SUCCESS" "Hasil perhitungan:"
    log "INFO" "  PHP-FPM:"
    log "INFO" "    pm.max_children = ${PM_MAX_CHILDREN}"
    log "INFO" "    pm.start_servers = ${PM_START_SERVERS}"
    log "INFO" "    Memory/worker ≈ ${MEMORY_PER_WORKER}MB"
    log "INFO" "  Nginx:"
    log "INFO" "    worker_processes = ${NGINX_WORKER_PROCESSES}"
    log "INFO" "    worker_connections = ${NGINX_WORKER_CONNECTIONS}"
    log "INFO" "  PHP:"
    log "INFO" "    memory_limit = ${PHP_MEMORY_LIMIT}"
    log "INFO" "    opcache.memory_consumption = ${OP_CACHE_MEM}MB"
}

# -----------------------
# TUNING PHP
# -----------------------
tune_php() {
    log "INFO" "Memulai tuning PHP..."
    
    local php_ini="/etc/php/${PHP_VERSION}/fpm/php.ini"
    local php_fpm_conf="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"
    
    # PHP.INI
    sed -i "s/^memory_limit = .*/memory_limit = ${PHP_MEMORY_LIMIT}/" "$php_ini"
    sed -i "s/^max_execution_time = .*/max_execution_time = 120/" "$php_ini"
    sed -i "s/^upload_max_filesize = .*/upload_max_filesize = 64M/" "$php_ini"
    sed -i "s/^post_max_size = .*/post_max_size = 72M/" "$php_ini"
    sed -i "s/^max_input_vars = .*/max_input_vars = 3000/" "$php_ini"
    
    # Session handling
    sed -i "s/^;*session.gc_probability = .*/session.gc_probability = 1/" "$php_ini"
    sed -i "s/^;*session.gc_divisor = .*/session.gc_divisor = 100/" "$php_ini"
    sed -i "s/^;*session.gc_maxlifetime = .*/session.gc_maxlifetime = 1440/" "$php_ini"
    
    # OPcache tuning
    cat >> "$php_ini" <<EOF

; OPcache Configuration
opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=$OP_CACHE_MEM
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=20000
opcache.validate_timestamps=0
opcache.revalidate_freq=0
opcache.save_comments=1
opcache.fast_shutdown=1
EOF
    
    # PHP-FPM Pool
    sed -i "s/^pm = .*/pm = dynamic/" "$php_fpm_conf"
    sed -i "s/^pm.max_children = .*/pm.max_children = ${PM_MAX_CHILDREN}/" "$php_fpm_conf"
    sed -i "s/^pm.start_servers = .*/pm.start_servers = ${PM_START_SERVERS}/" "$php_fpm_conf"
    sed -i "s/^pm.min_spare_servers = .*/pm.min_spare_servers = ${PM_MIN_SPARE_SERVERS}/" "$php_fpm_conf"
    sed -i "s/^pm.max_spare_servers = .*/pm.max_spare_servers = ${PM_MAX_SPARE_SERVERS}/" "$php_fpm_conf"
    sed -i "s/^;*pm.max_requests = .*/pm.max_requests = 500/" "$php_fpm_conf"
    sed -i "s/^;*pm.process_idle_timeout = .*/pm.process_idle_timeout = 30s/" "$php_fpm_conf"
    
    # Process management
    sed -i "s/^;*rlimit_files = .*/rlimit_files = 65535/" "$php_fpm_conf"
    sed -i "s/^;*rlimit_core = .*/rlimit_core = unlimited/" "$php_fpm_conf"
    
    log "SUCCESS" "Tuning PHP selesai"
}

# -----------------------
# TUNING NGINX
# -----------------------
tune_nginx() {
    log "INFO" "Memulai tuning Nginx..."
    
    local nginx_conf="/etc/nginx/nginx.conf"
    
    # Backup konfigurasi asli
    cp "$nginx_conf" "$nginx_conf.bak_$BACKUP_TIMESTAMP"
    
    # Buat konfigurasi Nginx yang optimal
    cat > "$nginx_conf" <<EOF
user $WEB_USER;
worker_processes $NGINX_WORKER_PROCESSES;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;

events {
    worker_connections $NGINX_WORKER_CONNECTIONS;
    multi_accept on;
    use epoll;
}

http {
    ##
    # Basic Settings
    ##
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;
    client_max_body_size 64M;

    ##
    # Buffers
    ##
    client_body_buffer_size 16K;
    client_header_buffer_size 1k;
    large_client_header_buffers 4 8k;

    ##
    # Timeouts
    ##
    client_body_timeout 60;
    client_header_timeout 60;
    send_timeout 60;
    keepalive_requests 1000;

    ##
    # Gzip
    ##
    gzip on;
    gzip_disable "msie6";
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

    ##
    # File Cache
    ##
    open_file_cache max=200000 inactive=20s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;

    ##
    # Virtual Host Configs
    ##
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
    
    # Test konfigurasi
    if ! nginx -t; then
        log "ERROR" "Konfigurasi Nginx tidak valid! Mengembalikan backup..."
        cp "$nginx_conf.bak_$BACKUP_TIMESTAMP" "$nginx_conf"
        nginx -t || {
            log "ERROR" "Gagal mengembalikan konfigurasi Nginx"
            exit 1
        }
        log "INFO" "Konfigurasi Nginx berhasil dikembalikan"
        return 1
    fi
    
    log "SUCCESS" "Tuning Nginx selesai"
}

# -----------------------
# TUNING SISTEM
# -----------------------
tune_system() {
    log "INFO" "Memulai tuning sistem..."
    
    # File descriptor limits
    grep -q "$WEB_USER.*nofile" /etc/security/limits.conf || {
        echo "$WEB_USER soft nofile 65535" >> /etc/security/limits.conf
        echo "$WEB_USER hard nofile 65535" >> /etc/security/limits.conf
    }
    
    # Kernel parameters
    cat >> /etc/sysctl.conf <<EOF

# Kernel Tuning
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 300
net.ipv4.ip_local_port_range = 1024 65535
fs.file-max = 2097152
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
    
    # Adjust swappiness based on disk type
    if [[ $SERVER_DISK_TYPE == "HDD" ]]; then
        echo "vm.swappiness=30" >> /etc/sysctl.conf
    else
        echo "vm.swappiness=10" >> /etc/sysctl.conf
    fi
    
    # Terapkan pengaturan kernel
    sysctl -p
    
    log "SUCCESS" "Tuning sistem selesai"
}

# -----------------------
# RESTART SERVICES
# -----------------------
restart_services() {
    log "INFO" "Restarting services..."
    
    systemctl restart "php${PHP_VERSION}-fpm" && \
    log "INFO" "PHP-FPM berhasil di-restart" || \
    log "ERROR" "Gagal restart PHP-FPM"
    
    systemctl restart nginx && \
    log "INFO" "Nginx berhasil di-restart" || \
    log "ERROR" "Gagal restart Nginx"
    
    log "SUCCESS" "Services berhasil di-restart"
}

# -----------------------
# MONITORING SUGGESTIONS
# -----------------------
show_monitoring_suggestions() {
    log "INFO" "\n=== REKOMENDASI MONITORING ==="
    log "INFO" "1. Perintah untuk memeriksa performa:"
    log "INFO" "   - PHP-FPM: systemctl status php${PHP_VERSION}-fpm"
    log "INFO" "   - Nginx: systemctl status nginx && nginx -t"
    log "INFO" "   - Penggunaan memory: free -h && htop"
    
    log "INFO" "\n2. Perintah untuk debug:"
    log "INFO" "   - PHP-FPM: tail -f /var/log/php${PHP_VERSION}-fpm.log"
    log "INFO" "   - Nginx: tail -f /var/log/nginx/error.log"
    log "INFO" "   - Sistem: dmesg | tail -20"
    
    log "INFO" "\n3. Tools monitoring yang disarankan:"
    log "INFO" "   - htop: untuk monitor CPU/Memory"
    log "INFO" "   - nmon: untuk monitor sistem secara real-time"
    log "INFO" "   - netdata: untuk monitoring komprehensif"
}

# -----------------------
# MAIN PROGRAM
# -----------------------
main() {
    init_logging
    clear
    
    echo -e "\n\e[44m=== SERVER TUNING SCRIPT (NGINX) ===\e[0m"
    echo -e "Versi: 2.0 | Oleh: DevOps Team\n"
    
    # Deteksi sistem
    detect_system
    
    # Backup konfigurasi
    backup_configs
    
    # Kalkulasi resource
    calculate_resources
    
    # Konfirmasi sebelum tuning
    echo -e "\n\e[43m=== KONFIGURASI YANG AKAN DITERAPKAN ===\e[0m"
    echo -e "PHP-FPM:"
    echo -e "  max_children: ${PM_MAX_CHILDREN}"
    echo -e "  start_servers: ${PM_START_SERVERS}"
    echo -e "  memory_limit: ${PHP_MEMORY_LIMIT}"
    echo -e "Nginx:"
    echo -e "  worker_processes: ${NGINX_WORKER_PROCESSES}"
    echo -e "  worker_connections: ${NGINX_WORKER_CONNECTIONS}"
    echo -e "\nEstimasi kapasitas: ~${EXPECTED_USERS} user concurrent"
    
    read -p "Lanjutkan tuning? (y/n) " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 0
    
    # Proses tuning
    tune_php
    tune_nginx
    tune_system
    restart_services
    
    # Hasil akhir
    echo -e "\n\e[42m=== TUNING SELESAI ===\e[0m"
    log "SUCCESS" "Semua tuning telah diterapkan!"
    log "INFO" "Detail log: ${LOG_FILE}"
    log "INFO" "Backup tersimpan di: ${BACKUP_DIR}/server-tuning-backup-${BACKUP_TIMESTAMP}.tar.gz"
    
    # Rekomendasi tambahan
    show_monitoring_suggestions
    
    # Saran untuk beban tinggi
    if [[ $EXPECTED_USERS -gt 5000 ]]; then
        echo -e "\n\e[43m=== REKOMENDASI UNTUK BEBAN TINGGI ===\e[0m"
        echo -e "1. Pertimbangkan untuk menggunakan:"
        echo -e "   - Load balancer (HAProxy/Nginx)"
        echo -e "   - Database server terpisah"
        echo -e "   - Redis/Memcached untuk caching"
        echo -e "   - CDN untuk aset statis"
    fi
    
    echo -e "\n\e[44m=== SELESAI ===\e[0m\n"
}

# Jalankan program utama
main
