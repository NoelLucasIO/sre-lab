#!/usr/bin/env bash
# Creates the Terraform state database + least-privilege role on the lab Postgres 18. Idempotent.
# Run on fedora as nlucas. Admin auth comes from ~/.pgpass or PGPASSWORD (never stored here).
# Output: ~/.config/terraform/pg.env  ->  PG_CONN_STR consumed by the Terraform pg backend.
set -euo pipefail

PGHOST=${PGHOST:-pgsql.noellucas.io}
PGPORT=${PGPORT:-5432}
ADMIN=${PGADMIN_USER:-postgres}
SSLMODE=${SSLMODE:-require}          # set SSLMODE=disable only if the server has no TLS yet
ROLE=tfstate DB=tfstate
SCHEMAS=(lab prod_lab)               # one schema per environment = separate state + separate lock space
ENV_DIR="$HOME/.config/terraform"
PW_FILE="$ENV_DIR/pg.password"
ENV_FILE="$ENV_DIR/pg.env"

die(){ printf '\e[1;31mERR\e[0m %s\n' "$*" >&2; exit 1; }
log(){ printf '\e[1;34m==>\e[0m %s\n' "$*"; }

command -v psql >/dev/null || die "psql missing: sudo dnf install -y postgresql"
admin(){ psql -X -v ON_ERROR_STOP=1 -q "host=$PGHOST port=$PGPORT user=$ADMIN dbname=${1:-postgres} sslmode=$SSLMODE" "${@:2}"; }
admin postgres -c 'select 1' >/dev/null 2>&1 \
  || die "admin connect failed (host=$PGHOST sslmode=$SSLMODE). Check ~/.pgpass, pg_hba, or SSLMODE."

install -d -m 0700 "$ENV_DIR"
[[ -s $PW_FILE ]] || ( umask 077; openssl rand -hex 32 >"$PW_FILE" )   # hex = URL-safe in conn_str
PW=$(<"$PW_FILE")

log "Role + database"
admin postgres -v pw="$PW" <<'SQL'
SELECT format('CREATE ROLE tfstate LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE CONNECTION LIMIT 10 PASSWORD %L', :'pw')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tfstate') \gexec
SELECT format('ALTER ROLE tfstate PASSWORD %L', :'pw') \gexec
SELECT 'CREATE DATABASE tfstate OWNER tfstate'
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'tfstate') \gexec
REVOKE ALL ON DATABASE tfstate FROM PUBLIC;
GRANT CONNECT, CREATE, TEMP ON DATABASE tfstate TO tfstate;
SQL

log "Schemas: ${SCHEMAS[*]}"
for s in "${SCHEMAS[@]}"; do
  admin "$DB" -c "CREATE SCHEMA IF NOT EXISTS $s AUTHORIZATION $ROLE"
done
admin "$DB" -c "REVOKE ALL ON SCHEMA public FROM PUBLIC"

( umask 077; printf 'PG_CONN_STR=postgres://%s:%s@%s:%s/%s?sslmode=%s\n' \
    "$ROLE" "$PW" "$PGHOST" "$PGPORT" "$DB" "$SSLMODE" >"$ENV_FILE" )

# Verify as the new role, not as admin.
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
psql -X -q "$PG_CONN_STR" -c "select current_user, current_database(), (select string_agg(nspname, ',') from pg_namespace where nspowner = 'tfstate'::regrole) as schemas"
log "Done. Use: set -a; source $ENV_FILE; set +a   (copy pg.env to the P620 with scp for local runs)"
