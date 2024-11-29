# PostgreSQL Active-Active Replication Setup

This repository contains scripts for setting up and testing PostgreSQL active-active (bi-directional) replication between two instances.

## System Requirements

- Ubuntu 22.04 or later
- PostgreSQL 15
- Systemd
- SSH access between servers
- Sudo privileges

## Network Setup

You need two servers with the following configuration:
- Server 1 (Primary): PostgreSQL running on port 5432
- Server 2 (Secondary): PostgreSQL running on port 5433

## Installation Steps

1. Clone this repository on both servers:
```bash
git clone <repository-url>
cd psql_active_active
```

2. Run the installation script on both servers:
```bash
# On Server 1 (replace with your actual IP addresses)
sudo ./install.sh 192.168.90.6 192.168.90.7 "192.168.90.0/24" "postgres"

# On Server 2 (replace with your actual IP addresses)
sudo ./install.sh 192.168.90.6 192.168.90.7 "192.168.90.0/24" "postgres"
```

The script will:
- Install PostgreSQL 15
- Configure systemd services
- Set up PostgreSQL instances with proper WAL settings
- Configure network access

## Testing Replication

After installation, test the replication setup:

```bash
sudo ./test.sh 192.168.90.6 192.168.90.7
```

The test script will:
1. Verify connectivity to both PostgreSQL instances
2. Create a test database and table
3. Set up bi-directional replication
4. Verify data replication in both directions

## Verification

You can manually verify the replication:

```bash
# Check data on Server 1
psql -h 192.168.90.6 -p 5432 -U postgres -d replication_test -c 'SELECT * FROM test_table;'

# Check data on Server 2
psql -h 192.168.90.7 -p 5433 -U postgres -d replication_test -c 'SELECT * FROM test_table;'
```

## Directory Structure

- `install.sh`: PostgreSQL installation and configuration script
- `test_replication.sh`: Replication testing script

## Configuration Details

### PostgreSQL Settings

Both instances are configured with:
- WAL level: logical
- Max WAL senders: 10
- Max replication slots: 10
- WAL keep size: 1GB

### Replication Setup

The setup uses PostgreSQL's logical replication with:
- Publications for each direction
- Subscriptions for bi-directional data flow
- Unique publication/subscription names to avoid conflicts

## Troubleshooting

1. Connection Issues:
   - Verify PostgreSQL is running: `systemctl status postgresql@15-main`
   - Check port accessibility: `telnet <ip-address> <port>`
   - Verify pg_hba.conf allows connections

2. Replication Issues:
   - Check WAL level: `SHOW wal_level;`
   - View replication status: `SELECT * FROM pg_stat_replication;`
   - Check publication: `\dRp+`
   - Check subscription: `\dRs+`

## Maintenance

To monitor replication:
```sql
-- Check replication lag
SELECT * FROM pg_stat_replication;

-- View active replication slots
SELECT * FROM pg_replication_slots;

-- Check publication tables
SELECT * FROM pg_publication_tables;
```

## Security Considerations

- The setup uses trust authentication for simplicity
- In production:
  - Use SSL/TLS encryption
  - Implement proper password authentication
  - Restrict network access
  - Use dedicated replication users

## Support

For issues or questions:
1. Check the troubleshooting section
2. Review PostgreSQL logs: `/var/log/postgresql/`
3. Open an issue in this repository

## License

This project is licensed under the MIT License - see the LICENSE file for details.
