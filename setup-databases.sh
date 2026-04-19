#!/bin/bash
# ============================================================================
# MusicTwins: Automated Database Setup Script
# Initializes PostgreSQL + MongoDB with all schemas, roles, indexes
# Usage: ./setup-databases.sh [local|staging|production]
# ============================================================================

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

ENVIRONMENT="${1:-local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env.${ENVIRONMENT}"
DEFAULT_ENV="${SCRIPT_DIR}/.env.example"

POSTGRES_INIT_SCRIPT="${SCRIPT_DIR}/init-postgres.sql"
MONGODB_INIT_SCRIPT="${SCRIPT_DIR}/init-mongodb.js"
DOCKER_COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"

LOG_FILE="${SCRIPT_DIR}/setup-${ENVIRONMENT}-$(date +%Y%m%d_%H%M%S).log"
DOCKER_COMPOSE_TIMEOUT=120

# ============================================================================
# COLORS & LOGGING
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
  echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

success() {
  echo -e "${GREEN}[✓]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
  echo -e "${RED}[✗]${NC} $1" | tee -a "$LOG_FILE"
  exit 1
}

warn() {
  echo -e "${YELLOW}[!]${NC} $1" | tee -a "$LOG_FILE"
}

# ============================================================================
# VALIDATION
# ============================================================================

validate_environment() {
  log "Validating setup for environment: $ENVIRONMENT"
  
  # Check environment file
  if [ ! -f "$ENV_FILE" ] && [ "$ENVIRONMENT" != "local" ]; then
    warn "Environment file not found: $ENV_FILE"
    log "Using .env.example as template..."
    cp "$DEFAULT_ENV" "$ENV_FILE"
    error "Please edit $ENV_FILE with correct values and run again"
  fi
  
  if [ "$ENVIRONMENT" = "local" ] && [ ! -f "$ENV_FILE" ]; then
    log "Creating .env.local from example..."
    cp "$DEFAULT_ENV" "$ENV_FILE"
  fi
  
  # Check required files
  [ -f "$POSTGRES_INIT_SCRIPT" ] || error "PostgreSQL init script not found: $POSTGRES_INIT_SCRIPT"
  [ -f "$MONGODB_INIT_SCRIPT" ] || error "MongoDB init script not found: $MONGODB_INIT_SCRIPT"
  [ -f "$DOCKER_COMPOSE_FILE" ] || error "Docker Compose file not found: $DOCKER_COMPOSE_FILE"
  
  # Check Docker
  docker --version > /dev/null 2>&1 || error "Docker is not installed"
  docker-compose --version > /dev/null 2>&1 || error "Docker Compose is not installed"
  
  success "All validations passed"
}

# ============================================================================
# DOCKER SETUP
# ============================================================================

start_docker_services() {
  log "Starting Docker services..."
  
  cd "$SCRIPT_DIR"
  
  # Stop existing services (graceful)
  if docker-compose -f "$DOCKER_COMPOSE_FILE" ps | grep -q "Up"; then
    warn "Existing services found. Stopping them..."
    docker-compose -f "$DOCKER_COMPOSE_FILE" down --timeout=30 2>&1 | tee -a "$LOG_FILE"
  fi
  
  # Start services
  log "Bringing up PostgreSQL, MongoDB, and auxiliary services..."
  docker-compose --env-file "$ENV_FILE" \
                 -f "$DOCKER_COMPOSE_FILE" \
                 up -d \
                 2>&1 | tee -a "$LOG_FILE"
  
  success "Docker services started"
}

wait_for_postgres() {
  log "Waiting for PostgreSQL to be ready..."
  
  local max_retries=30
  local retry=0
  
  while [ $retry -lt $max_retries ]; do
    if docker exec musictwins_postgres pg_isready -U postgres > /dev/null 2>&1; then
      success "PostgreSQL is ready"
      return 0
    fi
    
    retry=$((retry + 1))
    echo "  Attempt $retry/$max_retries..." | tee -a "$LOG_FILE"
    sleep 4
  done
  
  error "PostgreSQL failed to start after ${max_retries} attempts"
}

wait_for_mongodb() {
  log "Waiting for MongoDB to be ready..."
  
  local max_retries=30
  local retry=0
  
  while [ $retry -lt $max_retries ]; do
    if docker exec musictwins_mongodb mongosh --eval "db.adminCommand({ping: 1})" > /dev/null 2>&1; then
      success "MongoDB is ready"
      return 0
    fi
    
    retry=$((retry + 1))
    echo "  Attempt $retry/$max_retries..." | tee -a "$LOG_FILE"
    sleep 4
  done
  
  error "MongoDB failed to start after ${max_retries} attempts"
}

# ============================================================================
# SCHEMA INITIALIZATION
# ============================================================================

initialize_postgres_schema() {
  log "Initializing PostgreSQL schema..."
  
  # Extract variables from .env for template substitution
  source "$ENV_FILE" 2>/dev/null || true
  
  # Check if schema already exists
  if docker exec musictwins_postgres psql -U postgres -l | grep -q "$DB_NAME"; then
    warn "Database $DB_NAME already exists"
    read -p "Drop and reinitialize? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log "Skipping PostgreSQL schema initialization"
      return 0
    fi
    
    # Drop database
    docker exec musictwins_postgres psql -U postgres -c "DROP DATABASE IF EXISTS \"$DB_NAME\";" 2>&1 | tee -a "$LOG_FILE"
  fi
  
  # Create database
  docker exec musictwins_postgres psql -U postgres \
    -c "CREATE DATABASE \"$DB_NAME\" OWNER postgres;" \
    2>&1 | tee -a "$LOG_FILE"
  
  # Apply init script with environment variable substitution
  docker exec -i musictwins_postgres psql -U postgres -d "$DB_NAME" \
    -v APP_PASSWORD="'$DB_PASSWORD'" \
    -v READONLY_PASSWORD="'$DB_READONLY_PASSWORD'" \
    < "$POSTGRES_INIT_SCRIPT" \
    2>&1 | tee -a "$LOG_FILE"
  
  success "PostgreSQL schema initialized"
}

initialize_mongodb_schema() {
  log "Initializing MongoDB schema..."
  
  # Extract variables from .env
  source "$ENV_FILE" 2>/dev/null || true
  
  # Wait for replica set initialization
  sleep 10
  
  # Create database and apply init script
  docker exec -e MONGO_DB_NAME="$MONGO_DB_NAME" \
              -e MONGO_USER="$MONGO_USER" \
              -e MONGO_PASSWORD="$MONGO_PASSWORD" \
              -e MONGO_MESSAGE_TTL_DAYS="${MONGO_MESSAGE_TTL_DAYS:-90}" \
              musictwins_mongodb \
              mongosh --eval "$(cat "$MONGODB_INIT_SCRIPT")" \
              2>&1 | tee -a "$LOG_FILE"
  
  success "MongoDB schema initialized"
}

# ============================================================================
# VERIFICATION
# ============================================================================

verify_postgres() {
  log "Verifying PostgreSQL..."
  
  source "$ENV_FILE" 2>/dev/null || true
  
  # Check tables
  local table_count=$(docker exec musictwins_postgres \
    psql -U "$DB_USER" -d "$DB_NAME" -t -c \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null || echo "0")
  
  log "PostgreSQL tables: $table_count"
  
  if [ "$table_count" -lt 7 ]; then
    error "PostgreSQL schema incomplete (expected >= 7 tables)"
  fi
  
  # List tables
  docker exec musictwins_postgres \
    psql -U "$DB_USER" -d "$DB_NAME" -c "\dt" \
    2>&1 | tee -a "$LOG_FILE"
  
  success "PostgreSQL verification complete"
}

verify_mongodb() {
  log "Verifying MongoDB..."
  
  source "$ENV_FILE" 2>/dev/null || true
  
  # Check collections
  local result=$(docker exec musictwins_mongodb \
    mongosh "$MONGO_DB_NAME" -u "$MONGO_USER" -p "$MONGO_PASSWORD" \
    --eval "JSON.stringify(db.getCollectionNames())" 2>/dev/null || echo "[]")
  
  log "MongoDB collections: $result"
  
  if ! echo "$result" | grep -q "messages"; then
    error "MongoDB schema incomplete (colección messages no encontrada)"
  fi
  
  # Check indexes
  docker exec musictwins_mongodb \
    mongosh "$MONGO_DB_NAME" -u "$MONGO_USER" -p "$MONGO_PASSWORD" \
    --eval "db.messages.getIndexes().forEach(idx => print(idx.name))" \
    2>&1 | tee -a "$LOG_FILE"
  
  success "MongoDB verification complete"
}

# ============================================================================
# CREDENTIALS OUTPUT
# ============================================================================

print_credentials() {
  source "$ENV_FILE" 2>/dev/null || true
  
  cat << EOF | tee -a "$LOG_FILE"

$(echo -e "${GREEN}========== DATABASE SETUP COMPLETE ==========${NC}")

PostgreSQL:
  Host: $DB_HOST
  Port: $DB_PORT
  Database: $DB_NAME
  App User: $DB_USER
  Admin User: $DB_ADMIN_USER
  
MongoDB:
  Host: $MONGO_HOST
  Port: $MONGO_PORT
  Database: $MONGO_DB_NAME
  App User: $MONGO_USER
  Auth Source: $MONGO_AUTH_SOURCE

Connection Strings:
  PostgreSQL: postgresql://$DB_USER:****@$DB_HOST:$DB_PORT/$DB_NAME
  MongoDB: mongodb://$MONGO_USER:****@$MONGO_HOST:$MONGO_PORT/$MONGO_DB_NAME?authSource=$MONGO_AUTH_SOURCE

Web Interfaces (dev only):
  Adminer (PostgreSQL): http://localhost:8080
  Mongo Express (MongoDB): http://localhost:8081

Next Steps:
  1. Add these connection strings to your application's .env
  2. Run backups: ./backup-restore.sh backup-all
  3. Monitor logs: docker-compose logs -f
  4. See README.md for more commands

$(echo -e "${GREEN}===========================================${NC}")
EOF
}

# ============================================================================
# CLEANUP & ERROR HANDLING
# ============================================================================

cleanup_on_error() {
  error_code=$?
  error "Setup failed with exit code $error_code"
  error "See logs: $LOG_FILE"
  exit $error_code
}

trap cleanup_on_error ERR

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
  echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║  MusicTwins Database Setup Automation  ║${NC}"
  echo -e "${BLUE}║  Environment: $ENVIRONMENT                       ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
  echo
  
  log "Setup log: $LOG_FILE"
  log "Starting initialization for $ENVIRONMENT environment..."
  
  validate_environment
  start_docker_services
  wait_for_postgres
  wait_for_mongodb
  
  log "Initializing schemas..."
  initialize_postgres_schema
  initialize_mongodb_schema
  
  log "Verifying installation..."
  sleep 5
  verify_postgres
  verify_mongodb
  
  print_credentials
  
  success "✓ All services initialized and ready!"
  exit 0
}

# Run main
main "$@"
