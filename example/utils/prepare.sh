#!/bin/bash
# Applies the chat schema to a Supabase/Postgres database:
#   ./prepare.sh -h <host> -p <port> -d <database> -U <user>
# Asks for the database password once (or reads PGPASSWORD), and stops at the
# first failing script so the database is never left half prepared. Every
# script is idempotent: re-running is safe, also to migrate a v1 database.
set -euo pipefail

while getopts h:p:d:U: flag
do
    case "${flag}" in
        h) hostname=${OPTARG};;
        p) port=${OPTARG};;
        d) database=${OPTARG};;
        U) user=${OPTARG};;
        *) echo "usage: $0 -h host -p port -d database -U user" >&2; exit 1;;
    esac
done
: "${hostname:?-h host is required}" "${port:?-p port is required}" \
  "${database:?-d database is required}" "${user:?-U user is required}"

command -v psql >/dev/null 2>&1 || {
    echo "psql not found: install PostgreSQL client tools (https://www.postgresql.org/download/)" >&2
    exit 1
}

if [[ -z "${PGPASSWORD:-}" ]]; then
    read -rsp "Password for $user@$hostname: " PGPASSWORD
    echo
    export PGPASSWORD
fi

SQL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/sql" && pwd)"
for f in 01_database_schema.sql 02_database_trigger.sql 03_database_policy.sql \
         04_storage.sql 05_database_view.sql 99_database_schema_permission.sql; do
    echo "applying $f"
    psql -U "$user" -h "$hostname" -p "$port" -d "$database" \
         -v ON_ERROR_STOP=1 -q -f "$SQL_DIR/$f"
done
echo "done"
