#!/bin/bash

# Text colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values for IP addresses
SITE1_IP1=${1:-"192.168.90.6"}
SITE1_IP2=${2:-"192.168.90.7"}
SITE1_PORT="5432"
SITE2_PORT="5433"

# Log function
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
    exit 1
}

# Configure PostgreSQL settings
configure_postgres() {
    local host=$1
    local port=$2
    
    log "Configuring PostgreSQL at ${host}:${port}..."
    
    # Set wal_level to logical
    psql -h "$host" -p "$port" -U postgres -c "
        ALTER SYSTEM SET wal_level = logical;
    "
    
    # Check current wal_level
    local current_wal_level=$(psql -h "$host" -p "$port" -U postgres -t -c "SHOW wal_level;")
    if [[ $current_wal_level == *"logical"* ]]; then
        log "WAL level already set to logical on ${host}:${port}"
        return 0
    fi
    
    # Restart PostgreSQL to apply changes
    if [ "$port" = "$SITE2_PORT" ]; then
        log "Restarting PostgreSQL on second instance..."
        ssh "$SITE1_IP2" "sudo systemctl restart postgresql@15-second"
    else
        log "Restarting PostgreSQL on first instance..."
        ssh "$SITE1_IP1" "sudo systemctl restart postgresql@15-main"
    fi
    
    # Wait for PostgreSQL to restart
    log "Waiting for PostgreSQL to restart..."
    for i in {1..30}; do
        if psql -h "$host" -p "$port" -U postgres -c "SELECT 1;" >/dev/null 2>&1; then
            break
        fi
        sleep 1
        if [ $i -eq 30 ]; then
            error "Timeout waiting for PostgreSQL to restart on ${host}:${port}"
        fi
    done
    
    # Verify wal_level
    local wal_level=$(psql -h "$host" -p "$port" -U postgres -t -c "SHOW wal_level;")
    if [[ $wal_level != *"logical"* ]]; then
        error "Failed to set wal_level to logical on ${host}:${port}"
    fi
    log "Successfully configured PostgreSQL on ${host}:${port}"
}

# Test database connection
test_connection() {
    local host=$1
    local port=$2
    log "Testing connection to PostgreSQL at ${host}:${port}..."
    
    if ! psql -h "$host" -p "$port" -U postgres -c "SELECT version();" > /dev/null 2>&1; then
        error "Failed to connect to PostgreSQL at ${host}:${port}"
    fi
    log "Successfully connected to PostgreSQL at ${host}:${port}"
}

# Create test table and data
setup_test_data() {
    local host=$1
    local port=$2
    log "Creating test data on ${host}:${port}..."
    
    # Drop and create database (outside transaction)
    psql -h "$host" -p "$port" -U postgres -c "DROP DATABASE IF EXISTS replication_test;"
    psql -h "$host" -p "$port" -U postgres -c "CREATE DATABASE replication_test;"
    
    # Create table and insert data
    psql -h "$host" -p "$port" -U postgres -d replication_test -c "
        CREATE TABLE test_table (
            id SERIAL PRIMARY KEY,
            data TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        
        INSERT INTO test_table (data) VALUES 
            ('Test data 1 from ${host}:${port}'),
            ('Test data 2 from ${host}:${port}'),
            ('Test data 3 from ${host}:${port}');
    "
    
    if [ $? -ne 0 ]; then
        error "Failed to create test data on ${host}:${port}"
    fi
    log "Test data created successfully on ${host}:${port}"
}

# Setup replication
setup_replication() {
    local source_host=$1
    local source_port=$2
    local target_host=$3
    local target_port=$4
    
    log "Setting up replication between ${source_host}:${source_port} and ${target_host}:${target_port}..."
    
    # Create publication on source (outside transaction)
    psql -h "$source_host" -p "$source_port" -U postgres -d replication_test -c "DROP PUBLICATION IF EXISTS pub_test;"
    psql -h "$source_host" -p "$source_port" -U postgres -d replication_test -c "CREATE PUBLICATION pub_test FOR ALL TABLES;"
    
    # Create database on target (outside transaction)
    psql -h "$target_host" -p "$target_port" -U postgres -c "DROP DATABASE IF EXISTS replication_test;"
    psql -h "$target_host" -p "$target_port" -U postgres -c "CREATE DATABASE replication_test;"
    
    # Create table structure on target
    psql -h "$target_host" -p "$target_port" -U postgres -d replication_test -c "
        CREATE TABLE test_table (
            id SERIAL PRIMARY KEY,
            data TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
    "
    
    # Create subscription (outside transaction)
    psql -h "$target_host" -p "$target_port" -U postgres -d replication_test -c "DROP SUBSCRIPTION IF EXISTS sub_test;"
    psql -h "$target_host" -p "$target_port" -U postgres -d replication_test -c "
        CREATE SUBSCRIPTION sub_test 
        CONNECTION 'host=${source_host} port=${source_port} user=postgres dbname=replication_test password=postgres' 
        PUBLICATION pub_test;
    "
    
    log "Replication setup completed"
}

# Setup bidirectional replication
setup_bidirectional_replication() {
    local host1=$1
    local port1=$2
    local host2=$3
    local port2=$4
    
    log "Setting up bi-directional replication..."
    
    # Setup replication from host1 to host2
    setup_replication "$host1" "$port1" "$host2" "$port2"
    
    # Setup replication from host2 to host1 (reverse direction)
    psql -h "$host2" -p "$port2" -U postgres -d replication_test -c "DROP PUBLICATION IF EXISTS pub_test_reverse;"
    psql -h "$host2" -p "$port2" -U postgres -d replication_test -c "CREATE PUBLICATION pub_test_reverse FOR ALL TABLES;"
    
    psql -h "$host1" -p "$port1" -U postgres -d replication_test -c "DROP SUBSCRIPTION IF EXISTS sub_test_reverse;"
    psql -h "$host1" -p "$port1" -U postgres -d replication_test -c "
        CREATE SUBSCRIPTION sub_test_reverse 
        CONNECTION 'host=${host2} port=${port2} user=postgres dbname=replication_test password=postgres' 
        PUBLICATION pub_test_reverse;
    "
    
    log "Bi-directional replication setup completed"
}

# Verify replication
verify_replication() {
    local source_host=$1
    local source_port=$2
    local target_host=$3
    local target_port=$4
    local wait_time=5
    
    log "Verifying replication from ${source_host}:${source_port} to ${target_host}:${target_port}..."
    log "Waiting ${wait_time} seconds for replication to sync..."
    sleep $wait_time
    
    # Get data from source
    local source_data=$(psql -h "$source_host" -p "$source_port" -U postgres -d replication_test -t -c "SELECT COUNT(*), MAX(data) FROM test_table;")
    
    # Get data from target
    local target_data=$(psql -h "$target_host" -p "$target_port" -U postgres -d replication_test -t -c "SELECT COUNT(*), MAX(data) FROM test_table;")
    
    if [ "$source_data" != "$target_data" ]; then
        error "Data mismatch between ${source_host}:${source_port} and ${target_host}:${target_port}"
    fi
    log "Data successfully replicated from ${source_host}:${source_port} to ${target_host}:${target_port}"
}

# Test bi-directional replication
test_bidirectional_replication() {
    local host1=$1
    local port1=$2
    local host2=$3
    local port2=$4
    
    log "Testing bi-directional replication between ${host1}:${port1} and ${host2}:${port2}..."
    
    # Insert data from first instance
    psql -h "$host1" -p "$port1" -U postgres -d replication_test -c "
        INSERT INTO test_table (data) VALUES ('Bi-directional test from ${host1}:${port1}');
    "
    
    # Insert data from second instance
    psql -h "$host2" -p "$port2" -U postgres -d replication_test -c "
        INSERT INTO test_table (data) VALUES ('Bi-directional test from ${host2}:${port2}');
    "
    
    # Wait for replication
    sleep 5
    
    # Verify data on both instances
    local count1=$(psql -h "$host1" -p "$port1" -U postgres -d replication_test -t -c "SELECT COUNT(*) FROM test_table;")
    local count2=$(psql -h "$host2" -p "$port2" -U postgres -d replication_test -t -c "SELECT COUNT(*) FROM test_table;")
    
    if [ "$count1" != "$count2" ]; then
        error "Bi-directional replication failed. Data count mismatch: ${count1} vs ${count2}"
    fi
    log "Bi-directional replication test successful"
}

# Main test sequence
main() {
    log "Starting replication tests..."
    
    # Test connections
    test_connection "$SITE1_IP1" "$SITE1_PORT"
    test_connection "$SITE1_IP2" "$SITE2_PORT"
    
    # Configure PostgreSQL on both instances
    configure_postgres "$SITE1_IP1" "$SITE1_PORT"
    configure_postgres "$SITE1_IP2" "$SITE2_PORT"
    
    # Setup test data on first instance
    setup_test_data "$SITE1_IP1" "$SITE1_PORT"
    
    # Setup bi-directional replication
    setup_bidirectional_replication "$SITE1_IP1" "$SITE1_PORT" "$SITE1_IP2" "$SITE2_PORT"
    
    # Wait for replication to initialize
    log "Waiting for replication to initialize..."
    sleep 10
    
    # Verify replication to second instance
    verify_replication "$SITE1_IP1" "$SITE1_PORT" "$SITE1_IP2" "$SITE2_PORT"
    
    # Test bi-directional replication
    test_bidirectional_replication "$SITE1_IP1" "$SITE1_PORT" "$SITE1_IP2" "$SITE2_PORT"
    
    log "All replication tests completed successfully!"
    log "You can manually verify the data with:"
    log "psql -h ${SITE1_IP1} -p ${SITE1_PORT} -U postgres -d replication_test -c 'SELECT * FROM test_table;'"
    log "psql -h ${SITE1_IP2} -p ${SITE2_PORT} -U postgres -d replication_test -c 'SELECT * FROM test_table;'"
}

# Run tests
main "$@"
