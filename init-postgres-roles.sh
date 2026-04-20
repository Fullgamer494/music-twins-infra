#!/bin/bash
# ==================================================
# MusicTwins: Crear roles de PostgreSQL desde env vars
# Se ejecuta en /docker-entrypoint-initdb.d/ DESPUÉS del .sql
# ==================================================

set -e

DB_APP_USER="${DB_USER:-musictwins_app}"
DB_APP_PASSWORD="${DB_PASSWORD:-changeme}"

echo "[roles] Creando usuario de aplicación: $DB_APP_USER"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  -- Usuario de la app (lectura y escritura)
  DO \$\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = '$DB_APP_USER') THEN
      CREATE USER $DB_APP_USER WITH PASSWORD '$DB_APP_PASSWORD';
    END IF;
  END \$\$;

  GRANT USAGE ON SCHEMA public TO $DB_APP_USER;
  GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO $DB_APP_USER;
  GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO $DB_APP_USER;
  GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO $DB_APP_USER;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO $DB_APP_USER;

  -- Usuario de solo lectura (auditoría/analytics)
  DO \$\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = 'musictwins_readonly') THEN
      CREATE USER musictwins_readonly WITH PASSWORD '${DB_READONLY_PASSWORD:-readonlypass}';
    END IF;
  END \$\$;

  GRANT USAGE ON SCHEMA public TO musictwins_readonly;
  GRANT SELECT ON ALL TABLES IN SCHEMA public TO musictwins_readonly;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO musictwins_readonly;
EOSQL

echo "[roles] ✅ Roles creados correctamente"
