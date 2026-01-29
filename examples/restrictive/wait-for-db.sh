#!/bin/sh
# wait-for-db.sh - Wait for PostgreSQL to be ready to accept connections

set -e

cmd="$@"

max_retries=30
retry_interval=2

# If DATABASE_URL is set, use it directly with psql
if [ -n "$DATABASE_URL" ]; then
  echo "Waiting for PostgreSQL using DATABASE_URL..."

  for i in $(seq 1 $max_retries); do
    if psql "$DATABASE_URL" -c '\q' 2>/dev/null; then
      echo "PostgreSQL is ready!"
      exec $cmd
    fi

    echo "PostgreSQL is unavailable - retry $i/$max_retries"
    sleep $retry_interval
  done
else
  # Fall back to DB_HOST if DATABASE_URL is not set
  echo "Waiting for PostgreSQL at $DB_HOST..."

  for i in $(seq 1 $max_retries); do
    if PGPASSWORD=$DB_PASSWORD psql -h "$DB_HOST" -U "$DB_USERNAME" -d postgres -c '\q' 2>/dev/null; then
      echo "PostgreSQL is ready!"
      exec $cmd
    fi

    echo "PostgreSQL is unavailable - retry $i/$max_retries"
    sleep $retry_interval
  done
fi

echo "PostgreSQL did not become ready in time"
exit 1
