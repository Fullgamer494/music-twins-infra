#!/bin/bash
# ============================================================================
# MusicTwins: Backup & Disaster Recovery Strategy
# PostgreSQL + MongoDB backup and restoration procedures
# ============================================================================

set -euo pipefail

# ============================================================================
# CONFIGURATION: Load from environment variables
# ============================================================================

DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-musictwins}"
DB_USER="${DB_USER:-musictwins_app}"
DB_PASSWORD="${DB_PASSWORD:-}"

MONGO_HOST="${MONGO_HOST:-localhost}"
MONGO_PORT="${MONGO_PORT:-27017}"
MONGO_DB_NAME="${MONGO_DB_NAME:-musictwins}"
MONGO_USER="${MONGO_USER:-musictwins_app}"
MONGO_PASSWORD="${MONGO_PASSWORD:-}"
MONGO_AUTH_SOURCE="${MONGO_AUTH_SOURCE:-musictwins}"

BACKUP_DIR="${BACKUP_DIR:-./backups}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
BACKUP_COMPRESS="${BACKUP_COMPRESS:-true}"
BACKUP_PARALLEL_JOBS="${BACKUP_PARALLEL_JOBS:-4}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${BACKUP_DIR}/backup_${TIMESTAMP}.log"

# ============================================================================
# UTILITIES
# ============================================================================

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error() {
  echo "[ERROR] $1" | tee -a "$LOG_FILE"
  exit 1
}

create_backup_dir() {
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
}

# ============================================================================
# POSTGRESQL: BACKUP PROCEDURES
# ============================================================================

backup_postgres_full() {
  local backup_file="${BACKUP_DIR}/postgres_full_${TIMESTAMP}.sql"
  
  log "Starting PostgreSQL full backup..."
  
  PGPASSWORD="$DB_PASSWORD" pg_dump \
    --host "$DB_HOST" \
    --port "$DB_PORT" \
    --username "$DB_USER" \
    --database "$DB_NAME" \
    --verbose \
    --format plain \
    > "$backup_file" 2>> "$LOG_FILE" || error "PostgreSQL backup failed"
  
  if [ "$BACKUP_COMPRESS" = "true" ]; then
    gzip "$backup_file"
    backup_file="${backup_file}.gz"
    log "Compressed backup: $backup_file"
  fi
  
  log "PostgreSQL full backup completed: $backup_file ($(du -h "$backup_file" | cut -f1))"
  echo "$backup_file"
}

backup_postgres_custom() {
  local backup_file="${BACKUP_DIR}/postgres_custom_${TIMESTAMP}.dump"
  
  log "Starting PostgreSQL custom format backup (faster, smaller)..."
  
  PGPASSWORD="$DB_PASSWORD" pg_dump \
    --host "$DB_HOST" \
    --port "$DB_PORT" \
    --username "$DB_USER" \
    --database "$DB_NAME" \
    --format custom \
    --file "$backup_file" \
    --verbose \
    --jobs "$BACKUP_PARALLEL_JOBS" \
    2>> "$LOG_FILE" || error "PostgreSQL backup failed"
  
  log "PostgreSQL custom backup completed: $backup_file ($(du -h "$backup_file" | cut -f1))"
  echo "$backup_file"
}

backup_postgres_directory() {
  local backup_dir="${BACKUP_DIR}/postgres_dir_${TIMESTAMP}"
  mkdir -p "$backup_dir"
  
  log "Starting PostgreSQL directory format backup (fastest, parallel)..."
  
  PGPASSWORD="$DB_PASSWORD" pg_dump \
    --host "$DB_HOST" \
    --port "$DB_PORT" \
    --username "$DB_USER" \
    --database "$DB_NAME" \
    --format directory \
    --file "$backup_dir" \
    --verbose \
    --jobs "$BACKUP_PARALLEL_JOBS" \
    2>> "$LOG_FILE" || error "PostgreSQL backup failed"
  
  if [ "$BACKUP_COMPRESS" = "true" ]; then
    tar -czf "${backup_dir}.tar.gz" -C "$(dirname "$backup_dir")" "$(basename "$backup_dir")"
    rm -rf "$backup_dir"
    log "PostgreSQL directory backup completed: ${backup_dir}.tar.gz ($(du -h "${backup_dir}.tar.gz" | cut -f1))"
    echo "${backup_dir}.tar.gz"
  else
    log "PostgreSQL directory backup completed: $backup_dir ($(du -sh "$backup_dir" | cut -f1))"
    echo "$backup_dir"
  fi
}

restore_postgres_full() {
  local backup_file="$1"
  
  [ -f "$backup_file" ] || error "Backup file not found: $backup_file"
  
  log "Starting PostgreSQL restore from: $backup_file"
  log "WARNING: This will overwrite existing data. Ensure backup exists first."
  
  # Check if compressed
  if [[ "$backup_file" == *.gz ]]; then
    zcat "$backup_file" | PGPASSWORD="$DB_PASSWORD" psql \
      --host "$DB_HOST" \
      --port "$DB_PORT" \
      --username "$DB_USER" \
      --dbname postgres \
      2>> "$LOG_FILE" || error "PostgreSQL restore failed"
  else
    PGPASSWORD="$DB_PASSWORD" psql \
      --host "$DB_HOST" \
      --port "$DB_PORT" \
      --username "$DB_USER" \
      --dbname postgres \
      < "$backup_file" \
      2>> "$LOG_FILE" || error "PostgreSQL restore failed"
  fi
  
  log "PostgreSQL restore completed"
}

restore_postgres_custom() {
  local backup_file="$1"
  
  [ -f "$backup_file" ] || error "Backup file not found: $backup_file"
  
  log "Starting PostgreSQL restore from custom format: $backup_file"
  
  PGPASSWORD="$DB_PASSWORD" pg_restore \
    --host "$DB_HOST" \
    --port "$DB_PORT" \
    --username "$DB_USER" \
    --dbname "$DB_NAME" \
    --verbose \
    --jobs "$BACKUP_PARALLEL_JOBS" \
    "$backup_file" \
    2>> "$LOG_FILE" || error "PostgreSQL restore failed"
  
  log "PostgreSQL restore completed"
}

# ============================================================================
# MONGODB: BACKUP PROCEDURES
# ============================================================================

backup_mongodb_dump() {
  local backup_dir="${BACKUP_DIR}/mongodb_dump_${TIMESTAMP}"
  mkdir -p "$backup_dir"
  
  log "Starting MongoDB dump backup..."
  
  if [ -n "$MONGO_PASSWORD" ]; then
    mongodump \
      --host "$MONGO_HOST:$MONGO_PORT" \
      --username "$MONGO_USER" \
      --password "$MONGO_PASSWORD" \
      --authenticationDatabase "$MONGO_AUTH_SOURCE" \
      --db "$MONGO_DB_NAME" \
      --out "$backup_dir" \
      --verbose \
      2>> "$LOG_FILE" || error "MongoDB backup failed"
  else
    mongodump \
      --host "$MONGO_HOST:$MONGO_PORT" \
      --db "$MONGO_DB_NAME" \
      --out "$backup_dir" \
      --verbose \
      2>> "$LOG_FILE" || error "MongoDB backup failed"
  fi
  
  if [ "$BACKUP_COMPRESS" = "true" ]; then
    tar -czf "${backup_dir}.tar.gz" -C "$(dirname "$backup_dir")" "$(basename "$backup_dir")"
    rm -rf "$backup_dir"
    log "MongoDB dump backup completed: ${backup_dir}.tar.gz ($(du -h "${backup_dir}.tar.gz" | cut -f1))"
    echo "${backup_dir}.tar.gz"
  else
    log "MongoDB dump backup completed: $backup_dir ($(du -sh "$backup_dir" | cut -f1))"
    echo "$backup_dir"
  fi
}

backup_mongodb_snapshot() {
  local backup_file="${BACKUP_DIR}/mongodb_snapshot_${TIMESTAMP}.archive"
  
  log "Starting MongoDB snapshot (requires replica set and storage engine support)..."
  
  if [ -n "$MONGO_PASSWORD" ]; then
    mongodump \
      --host "$MONGO_HOST:$MONGO_PORT" \
      --username "$MONGO_USER" \
      --password "$MONGO_PASSWORD" \
      --authenticationDatabase "$MONGO_AUTH_SOURCE" \
      --db "$MONGO_DB_NAME" \
      --archive="$backup_file" \
      2>> "$LOG_FILE" || error "MongoDB snapshot backup failed"
  else
    mongodump \
      --host "$MONGO_HOST:$MONGO_PORT" \
      --db "$MONGO_DB_NAME" \
      --archive="$backup_file" \
      2>> "$LOG_FILE" || error "MongoDB snapshot backup failed"
  fi
  
  log "MongoDB snapshot backup completed: $backup_file ($(du -h "$backup_file" | cut -f1))"
  echo "$backup_file"
}

restore_mongodb_dump() {
  local backup_dir="$1"
  
  [ -d "$backup_dir" ] || [ -f "$backup_dir" ] || error "Backup path not found: $backup_dir"
  
  # Extract if compressed
  if [[ "$backup_dir" == *.tar.gz ]]; then
    backup_dir=$(mktemp -d)
    tar -xzf "$1" -C "$backup_dir"
    backup_dir="${backup_dir}/$(ls -1 "$backup_dir")"
  fi
  
  log "Starting MongoDB restore from: $backup_dir"
  
  if [ -n "$MONGO_PASSWORD" ]; then
    mongorestore \
      --host "$MONGO_HOST:$MONGO_PORT" \
      --username "$MONGO_USER" \
      --password "$MONGO_PASSWORD" \
      --authenticationDatabase "$MONGO_AUTH_SOURCE" \
      --db "$MONGO_DB_NAME" \
      --dir "$backup_dir/$MONGO_DB_NAME" \
      --verbose \
      2>> "$LOG_FILE" || error "MongoDB restore failed"
  else
    mongorestore \
      --host "$MONGO_HOST:$MONGO_PORT" \
      --db "$MONGO_DB_NAME" \
      --dir "$backup_dir/$MONGO_DB_NAME" \
      --verbose \
      2>> "$LOG_FILE" || error "MongoDB restore failed"
  fi
  
  log "MongoDB restore completed"
}

restore_mongodb_snapshot() {
  local backup_file="$1"
  
  [ -f "$backup_file" ] || error "Backup file not found: $backup_file"
  
  log "Starting MongoDB restore from snapshot: $backup_file"
  
  if [ -n "$MONGO_PASSWORD" ]; then
    mongorestore \
      --host "$MONGO_HOST:$MONGO_PORT" \
      --username "$MONGO_USER" \
      --password "$MONGO_PASSWORD" \
      --authenticationDatabase "$MONGO_AUTH_SOURCE" \
      --db "$MONGO_DB_NAME" \
      --archive="$backup_file" \
      --verbose \
      2>> "$LOG_FILE" || error "MongoDB restore failed"
  else
    mongorestore \
      --host "$MONGO_HOST:$MONGO_PORT" \
      --db "$MONGO_DB_NAME" \
      --archive="$backup_file" \
      --verbose \
      2>> "$LOG_FILE" || error "MongoDB restore failed"
  fi
  
  log "MongoDB restore completed"
}

# ============================================================================
# MAINTENANCE: Retention and cleanup
# ============================================================================

cleanup_old_backups() {
  log "Cleaning up backups older than $BACKUP_RETENTION_DAYS days..."
  
  find "$BACKUP_DIR" -type f -mtime "+$BACKUP_RETENTION_DAYS" -delete
  find "$BACKUP_DIR" -type d -mtime "+$BACKUP_RETENTION_DAYS" -delete
  
  log "Cleanup completed"
}

list_backups() {
  log "Available backups:"
  ls -lh "$BACKUP_DIR" 2>/dev/null | tail -n +2 || log "No backups found"
}

# ============================================================================
# VERIFICATION: Test backup integrity
# ============================================================================

verify_postgres_backup() {
  local backup_file="$1"
  
  [ -f "$backup_file" ] || error "Backup file not found: $backup_file"
  
  log "Verifying PostgreSQL backup: $backup_file"
  
  if [[ "$backup_file" == *.dump ]]; then
    pg_restore --list "$backup_file" > /dev/null || error "PostgreSQL backup is corrupted"
  elif [[ "$backup_file" == *.sql.gz ]]; then
    zcat "$backup_file" | head -n 10 > /dev/null || error "PostgreSQL backup is corrupted"
  else
    file "$backup_file" | grep -q "SQL" || error "PostgreSQL backup format unrecognized"
  fi
  
  log "PostgreSQL backup verification successful"
}

verify_mongodb_backup() {
  local backup_path="$1"
  
  [ -e "$backup_path" ] || error "Backup path not found: $backup_path"
  
  log "Verifying MongoDB backup: $backup_path"
  
  if [[ "$backup_path" == *.tar.gz ]]; then
    tar -tzf "$backup_path" > /dev/null || error "MongoDB backup is corrupted"
  elif [ -d "$backup_path" ]; then
    [ -d "$backup_path/$MONGO_DB_NAME" ] || error "MongoDB backup structure is invalid"
  fi
  
  log "MongoDB backup verification successful"
}

# ============================================================================
# MAIN: Command dispatcher
# ============================================================================

usage() {
  cat <<EOF
Usage: $0 <command> [options]

BACKUP COMMANDS:
  backup-postgres-full       Full SQL dump (largest, slowest)
  backup-postgres-custom     Custom format (medium size, faster restore)
  backup-postgres-dir        Directory format (fastest, parallel)
  backup-mongodb-dump        Standard MongoDB dump
  backup-mongodb-snapshot    MongoDB snapshot (requires replica set)
  backup-all                 Backup PostgreSQL + MongoDB
  
RESTORE COMMANDS:
  restore-postgres <file>    Restore PostgreSQL from backup
  restore-mongodb-dump <dir> Restore MongoDB from dump
  restore-mongodb-snap <file>Restore MongoDB from snapshot
  
MAINTENANCE:
  list-backups              Show all available backups
  cleanup                   Delete backups older than retention period
  verify-postgres <file>    Test PostgreSQL backup integrity
  verify-mongodb <path>     Test MongoDB backup integrity

ENVIRONMENT VARIABLES:
  DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD
  MONGO_HOST, MONGO_PORT, MONGO_DB_NAME, MONGO_USER, MONGO_PASSWORD
  BACKUP_DIR (default: ./backups)
  BACKUP_RETENTION_DAYS (default: 30)
  BACKUP_COMPRESS (default: true)

EXAMPLES:
  ./backup-restore.sh backup-all
  ./backup-restore.sh restore-postgres ./backups/postgres_custom_20240115_120000.dump
  DB_RETENTION_DAYS=90 ./backup-restore.sh backup-all && ./backup-restore.sh cleanup

EOF
  exit 1
}

main() {
  create_backup_dir
  
  case "${1:-}" in
    backup-postgres-full)
      backup_postgres_full
      ;;
    backup-postgres-custom)
      backup_postgres_custom
      ;;
    backup-postgres-dir)
      backup_postgres_directory
      ;;
    backup-mongodb-dump)
      backup_mongodb_dump
      ;;
    backup-mongodb-snapshot)
      backup_mongodb_snapshot
      ;;
    backup-all)
      backup_postgres_custom
      backup_mongodb_dump
      log "All backups completed successfully"
      ;;
    restore-postgres)
      restore_postgres_full "${2:-}"
      ;;
    restore-mongodb-dump)
      restore_mongodb_dump "${2:-}"
      ;;
    restore-mongodb-snap)
      restore_mongodb_snapshot "${2:-}"
      ;;
    list-backups)
      list_backups
      ;;
    cleanup)
      cleanup_old_backups
      ;;
    verify-postgres)
      verify_postgres_backup "${2:-}"
      ;;
    verify-mongodb)
      verify_mongodb_backup "${2:-}"
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"
