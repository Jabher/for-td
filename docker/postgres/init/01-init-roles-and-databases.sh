#!/usr/bin/env bash
set -euo pipefail

APP_DB_USER="${APP_DB_USER:-ledger_runtime}"
APP_DB_PASSWORD="${APP_DB_PASSWORD:-ledger_runtime_secret}"
LEDGER_OWNER_ROLE="${LEDGER_OWNER_ROLE:-ledger_definer}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v app_user="$APP_DB_USER" \
  -v app_password="$APP_DB_PASSWORD" \
  -v owner_role="$LEDGER_OWNER_ROLE" <<-'EOSQL'
  SELECT format('CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT', :'owner_role')
  WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = :'owner_role') \gexec

  SELECT format('CREATE ROLE %I LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT', :'app_user', :'app_password')
  WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = :'app_user') \gexec

  SELECT format('ALTER ROLE %I WITH PASSWORD %L', :'app_user', :'app_password') \gexec

  SELECT format('CREATE DATABASE %I OWNER %I', 'taxdome_ledger_development', current_user)
  WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_database WHERE datname = 'taxdome_ledger_development') \gexec

  SELECT format('CREATE DATABASE %I OWNER %I', 'taxdome_ledger_test', current_user)
  WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_database WHERE datname = 'taxdome_ledger_test') \gexec
EOSQL
