#!/bin/bash

# PostgreSQL Active-Active Installation and Optimization Script

# Text colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values for IP addresses
SITE1_IP1=${1:-"192.168.90.6"}
SITE1_IP2=${2:-"192.168.90.7"}
SITE1_SUBNET=${3:-"192.168.90.0/24"}
PG_PASSWORD=${4:-"postgres"}

# Configuration variables
SITE1_PORT="5432"
SITE2_PORT="5433"
PG_BIN="/usr/lib/postgresql/15/bin"

# Log function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

# Show script usage
show_usage() {
    echo "Usage: $0 [site1_ip1] [site1_ip2] [subnet] [postgres_password]"
    echo ""
    echo "Parameters:"
    echo "  site1_ip1         First IP address for Site 1 (default: 192.168.90.6)"
    echo "  site1_ip2         Second IP address for Site 1 (default: 192.168.90.7)"
    echo "  subnet            Subnet for trusted connections (default: 192.168.90.0/24)"
    echo "  postgres_password PostgreSQL password (default: postgres)"
    echo ""
    echo "Example:"
    echo "  $0 192.168.90.6 192.168.90.7 192.168.90.0/24 mypassword"
    exit 1
}

# Show configuration
show_config() {
    log "Configuration:"
    echo -e "Site 1 - IP1: $SITE1_IP1"
    echo -e "Site 1 - IP2: $SITE1_IP2"
    echo -e "Trusted Subnet: $SITE1_SUBNET"
    echo -e "PostgreSQL Password will be set to: $PG_PASSWORD"
    echo ""
    read -p "Press Enter to continue or Ctrl+C to cancel..."
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    error "Please run as root or with sudo"
fi

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$NAME
    VERSION=$VERSION_ID
elif [ -f /etc/redhat-release ]; then
    OS="Red Hat"
elif [ "$(uname)" == "Darwin" ]; then
    OS="macOS"
    VERSION=$(sw_vers -productVersion)
else
    error "Unsupported operating system"
fi

log "Detected OS: $OS $VERSION"

# Install PostgreSQL
install_postgresql() {
    log "Installing PostgreSQL..."
    
    case $OS in
        "Ubuntu")
            # Add PostgreSQL repository
            if [ ! -f /etc/apt/sources.list.d/pgdg.list ]; then
                echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list
                wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
            fi
            
            # Update package list and install PostgreSQL
            apt-get update
            apt-get install -y postgresql-15 postgresql-contrib-15
            ;;
            
        "macOS")
            # Check if Homebrew is installed
            if ! command -v brew >/dev/null 2>&1; then
                error "Homebrew is required for macOS installation. Please install it first."
            fi
            
            # Install PostgreSQL using Homebrew
            brew install postgresql@15
            ;;
            
        *)
            error "Unsupported operating system: $OS"
            ;;
    esac
    
    # Verify installation
    if [ ! -f "${PG_BIN}/initdb" ]; then
        error "PostgreSQL installation failed. initdb not found at ${PG_BIN}"
    fi
    
    log "PostgreSQL installed successfully"
}

# Setup postgres user
setup_postgres_user() {
    log "Setting up postgres user..."
    
    # Check if postgres user exists
    if ! id -u postgres >/dev/null 2>&1; then
        # Create postgres group if it doesn't exist
        if ! getent group postgres >/dev/null 2>&1; then
            groupadd postgres
        fi
        
        # Create postgres user
        useradd -r -g postgres -d /var/lib/postgresql -s /bin/bash postgres
    fi
    
    # Create postgres home directory
    install -d -m 755 -o postgres -g postgres /var/lib/postgresql
    
    log "Postgres user setup completed"
}

# Create systemd service files
create_systemd_services() {
    log "Creating systemd service files..."
    
    # Main instance service file
    cat > /etc/systemd/system/postgresql@15-main.service << EOF
[Unit]
Description=PostgreSQL Cluster 15-main
AssertPathExists=/var/lib/postgresql/15/main
RequiresMountsFor=/var/lib/postgresql/15/main
After=network.target

[Service]
Type=forking
User=postgres
Group=postgres
Environment=PGDATA=/var/lib/postgresql/15/main

ExecStart=/usr/lib/postgresql/15/bin/pg_ctl start -D /var/lib/postgresql/15/main -s -w -t 300
ExecStop=/usr/lib/postgresql/15/bin/pg_ctl stop -D /var/lib/postgresql/15/main -s -m fast
ExecReload=/usr/lib/postgresql/15/bin/pg_ctl reload -D /var/lib/postgresql/15/main -s

TimeoutSec=300

[Install]
WantedBy=multi-user.target
EOF

    # Second instance service file
    cat > /etc/systemd/system/postgresql@15-second.service << EOF
[Unit]
Description=PostgreSQL Cluster 15-second
AssertPathExists=/var/lib/postgresql/15/second
RequiresMountsFor=/var/lib/postgresql/15/second
After=network.target

[Service]
Type=forking
User=postgres
Group=postgres
Environment=PGDATA=/var/lib/postgresql/15/second

ExecStart=/usr/lib/postgresql/15/bin/pg_ctl start -D /var/lib/postgresql/15/second -s -w -t 300
ExecStop=/usr/lib/postgresql/15/bin/pg_ctl stop -D /var/lib/postgresql/15/second -s -m fast
ExecReload=/usr/lib/postgresql/15/bin/pg_ctl reload -D /var/lib/postgresql/15/second -s

TimeoutSec=300

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd
    systemctl daemon-reload
    
    log "Systemd service files created successfully"
}

# Create necessary directories
setup_directories() {
    log "Setting up PostgreSQL directories..."
    
    # Stop PostgreSQL and clean up
    systemctl stop postgresql* || true
    pkill postgres || true
    sleep 2
    
    # Remove existing directories
    rm -rf /var/lib/postgresql/15/main
    rm -rf /var/lib/postgresql/15/second
    rm -rf /var/run/postgresql/*
    rm -rf /var/log/postgresql/*
    
    # Create directories with correct ownership
    for dir in \
        "/var/lib/postgresql/15/main" \
        "/var/lib/postgresql/15/second" \
        "/var/log/postgresql" \
        "/var/run/postgresql"; do
        install -d -m 700 -o postgres -g postgres "$dir"
    done
    
    # Adjust permissions for log and socket directories
    chmod 755 /var/log/postgresql
    chmod 775 /var/run/postgresql
    
    log "Directories created successfully"
}

# Initialize PostgreSQL
initialize_postgresql() {
    log "Initializing PostgreSQL databases..."
    
    # Initialize main instance
    if ! sudo -i -u postgres ${PG_BIN}/initdb -D /var/lib/postgresql/15/main --auth=trust; then
        error "Failed to initialize main instance"
    fi
    
    # Initialize second instance
    if ! sudo -i -u postgres ${PG_BIN}/initdb -D /var/lib/postgresql/15/second --auth=trust; then
        error "Failed to initialize second instance"
    fi
    
    log "PostgreSQL databases initialized successfully"
}

# Configure PostgreSQL
configure_postgresql() {
    log "Configuring PostgreSQL..."
    
    # Configure main instance
    configure_instance "main" "$SITE1_PORT" "/var/lib/postgresql/15/main"
    
    # Configure second instance
    configure_instance "second" "$SITE2_PORT" "/var/lib/postgresql/15/second"
    
    log "PostgreSQL configuration completed"
}

# Configure a single PostgreSQL instance
configure_instance() {
    local instance=$1
    local port=$2
    local data_dir=$3
    
    log "Configuring PostgreSQL ${instance} instance..."
    
    # Update postgresql.conf
    cat > "${data_dir}/postgresql.conf" << EOF
# Connection settings
listen_addresses = '*'
port = ${port}
max_connections = 100
unix_socket_directories = '/var/run/postgresql'

# Replication settings
wal_level = logical
max_wal_senders = 10
max_replication_slots = 10
wal_keep_size = '1GB'

# Resource usage
shared_buffers = '128MB'
work_mem = '32MB'
maintenance_work_mem = '64MB'
effective_cache_size = '512MB'

# Write ahead log
wal_sync_method = fsync
wal_compression = on
min_wal_size = '80MB'
max_wal_size = '1GB'

# Logging
log_destination = 'stderr'
logging_collector = on
log_directory = '/var/log/postgresql'
log_filename = 'postgresql-${instance}-%Y-%m-%d.log'
log_rotation_age = 1d
log_line_prefix = '%m [%p] '
log_timezone = 'UTC'
EOF

    # Update pg_hba.conf
    cat > "${data_dir}/pg_hba.conf" << EOF
# Local connections
local   all             postgres                                peer
local   all             all                                     peer

# IPv4 connections
host    all             all             127.0.0.1/32           trust
host    all             all             ${SITE1_SUBNET}        trust
host    replication     all             ${SITE1_SUBNET}        trust
EOF
}

# Start PostgreSQL
start_postgresql() {
    log "Starting PostgreSQL instances..."
    
    # Stop any running instances
    systemctl stop postgresql* || true
    pkill postgres || true
    sleep 2
    
    # Remove old socket files
    rm -f /var/run/postgresql/.s.PGSQL.* || true
    
    # Start main instance
    log "Starting main instance..."
    if ! systemctl start postgresql@15-main; then
        log "Checking main instance logs:"
        journalctl -u postgresql@15-main -n 20
        error "Failed to start main instance"
    fi
    sleep 5
    
    # Start second instance
    log "Starting second instance..."
    if ! systemctl start postgresql@15-second; then
        log "Checking second instance logs:"
        journalctl -u postgresql@15-second -n 20
        error "Failed to start second instance"
    fi
    sleep 5
    
    # Verify both instances are running
    if ! systemctl is-active --quiet postgresql@15-main || ! systemctl is-active --quiet postgresql@15-second; then
        error "One or both PostgreSQL instances failed to start"
    fi
    
    log "PostgreSQL instances started successfully"
}

# Set PostgreSQL password
set_postgres_password() {
    log "Setting PostgreSQL password..."
    
    # Wait for PostgreSQL to be ready
    sleep 5
    
    export PGPASSWORD="${PG_PASSWORD}"
    
    for SITE in "main" "second"; do
        SITE_PORT=$([[ "$SITE" == "main" ]] && echo "$SITE1_PORT" || echo "$SITE2_PORT")
        
        # Try to set password using host connection
        if ! sudo -u postgres psql -h localhost -p ${SITE_PORT} -c "ALTER USER postgres WITH PASSWORD '${PG_PASSWORD}';" 2>/dev/null; then
            # If host connection fails, try Unix socket
            if ! sudo -u postgres psql -p ${SITE_PORT} -c "ALTER USER postgres WITH PASSWORD '${PG_PASSWORD}';" 2>/dev/null; then
                warning "Could not set password for ${SITE} (port ${SITE_PORT})"
            fi
        fi
    done
}

# Main installation sequence
main() {
    # Show configuration and get confirmation
    show_config
    
    # Install PostgreSQL
    install_postgresql
    
    # Setup system
    setup_postgres_user
    setup_directories
    configure_system
    
    # Create systemd service files
    create_systemd_services
    
    # Initialize and configure PostgreSQL
    initialize_postgresql
    configure_postgresql
    
    # Start PostgreSQL instances
    start_postgresql
    
    # Set password if specified
    if [ "$PG_PASSWORD" != "postgres" ]; then
        set_postgres_password
    fi
    
    log "Installation completed successfully!"
    log "Main instance running on port ${SITE1_PORT}"
    log "Second instance running on port ${SITE2_PORT}"
}

# Run the installation
main "$@"
