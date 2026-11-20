#!/usr/bin/env bash
# Local Supabase-compatible stack for rv Cloud development and tests.
#
# Prefer `npx supabase start` when your machine can pull Supabase's images;
# this script is the lighter fallback it was built for: a Postgres you
# already run, plus GoTrue, PostgREST and Mailpit from Docker Hub, behind a
# small gateway with Supabase's URL layout.
#
#   scripts/dev-stack.sh up       start everything and apply migrations
#   scripts/dev-stack.sh migrate  apply bootstrap and migrations
#   scripts/dev-stack.sh reset    drop the public schema and re-apply migrations
#   scripts/dev-stack.sh down     stop the containers and the gateway
#
# Needs: psql, docker, node, and Postgres reachable at $DB_URL.
set -euo pipefail

cd "$(dirname "$0")/.."

DB_URL="${DB_URL:-postgres://postgres@127.0.0.1:54322/postgres}"
DB_HOST_URL="${DB_HOST_URL:-127.0.0.1:54322/postgres}"
JWT_SECRET="${JWT_SECRET:-super-secret-jwt-token-with-at-least-32-characters-long}"
SITE_URL="${SITE_URL:-http://localhost:3000}"
GOTRUE_IMAGE="supabase/gotrue:v2.180.0"
POSTGREST_IMAGE="postgrest/postgrest:v13.0.7"
MAILPIT_IMAGE="axllent/mailpit:v1.27"
STATE_DIR="${STATE_DIR:-.dev-stack}"

psql_db() { psql "$DB_URL" -v ON_ERROR_STOP=1 -q "$@"; }

migrate() {
  psql_db -f supabase/dev/bootstrap.sql
  for f in supabase/migrations/*.sql; do
    echo "applying $f"
    psql_db -f "$f"
  done
  psql_db -c "notify pgrst, 'reload schema'"
}

up() {
  mkdir -p "$STATE_DIR"
  psql_db -f supabase/dev/bootstrap.sql

  docker rm -f rv-mail rv-auth rv-rest >/dev/null 2>&1 || true
  docker run -d --name rv-mail --network host "$MAILPIT_IMAGE" \
    --smtp 127.0.0.1:54325 --listen 127.0.0.1:54324 >/dev/null

  docker run -d --name rv-auth --network host \
    -e GOTRUE_API_HOST=127.0.0.1 -e PORT=54329 \
    -e API_EXTERNAL_URL=http://127.0.0.1:54321/auth/v1 \
    -e GOTRUE_DB_DRIVER=postgres \
    -e DATABASE_URL="postgres://supabase_auth_admin:postgres@${DB_HOST_URL}?search_path=auth" \
    -e GOTRUE_SITE_URL="$SITE_URL" \
    -e GOTRUE_URI_ALLOW_LIST="${SITE_URL}/**,http://127.0.0.1:3000/**" \
    -e GOTRUE_JWT_SECRET="$JWT_SECRET" -e GOTRUE_JWT_EXP=3600 -e GOTRUE_JWT_AUD=authenticated \
    -e GOTRUE_JWT_ADMIN_ROLES=service_role -e GOTRUE_DISABLE_SIGNUP=false \
    -e GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated \
    -e GOTRUE_EXTERNAL_EMAIL_ENABLED=true -e GOTRUE_MAILER_AUTOCONFIRM=false \
    -e GOTRUE_SMTP_HOST=127.0.0.1 -e GOTRUE_SMTP_PORT=54325 \
    -e GOTRUE_SMTP_ADMIN_EMAIL=noreply@rv.local -e GOTRUE_SMTP_SENDER_NAME="rv Cloud" \
    -e GOTRUE_MAILER_URLPATHS_CONFIRMATION=/auth/v1/verify \
    -e GOTRUE_MAILER_URLPATHS_MAGIC_LINK=/auth/v1/verify \
    -e GOTRUE_MAILER_URLPATHS_RECOVERY=/auth/v1/verify \
    -e GOTRUE_MAILER_URLPATHS_INVITE=/auth/v1/verify \
    -e GOTRUE_RATE_LIMIT_EMAIL_SENT=1000 \
    "$GOTRUE_IMAGE" >/dev/null

  echo "waiting for GoTrue migrations"
  for _ in $(seq 1 60); do
    curl -sf http://127.0.0.1:54329/health >/dev/null && break
    sleep 1
  done

  for f in supabase/migrations/*.sql; do
    echo "applying $f"
    psql_db -f "$f"
  done

  docker run -d --name rv-rest --network host \
    -e PGRST_DB_URI="postgres://authenticator:postgres@${DB_HOST_URL}" \
    -e PGRST_DB_SCHEMAS=public -e PGRST_DB_ANON_ROLE=anon \
    -e PGRST_JWT_SECRET="$JWT_SECRET" -e PGRST_SERVER_PORT=54330 \
    -e PGRST_SERVER_HOST=127.0.0.1 -e PGRST_DB_CHANNEL_ENABLED=true \
    "$POSTGREST_IMAGE" >/dev/null

  if [ -f "$STATE_DIR/gateway.pid" ] && kill -0 "$(cat "$STATE_DIR/gateway.pid")" 2>/dev/null; then
    kill "$(cat "$STATE_DIR/gateway.pid")"
  fi
  nohup node scripts/dev-gateway.mjs >"$STATE_DIR/gateway.log" 2>&1 &
  echo $! >"$STATE_DIR/gateway.pid"

  for _ in $(seq 1 30); do
    curl -sf http://127.0.0.1:54321/rest/v1/ >/dev/null && break
    sleep 1
  done

  node scripts/dev-keys.mjs "$JWT_SECRET" >"$STATE_DIR/keys.env"
  cat <<EOF

rv Cloud dev stack is up.
  API (Supabase URL)  http://127.0.0.1:54321
  Mail (Mailpit)      http://127.0.0.1:54324
  Postgres            $DB_URL
Keys for .env.local are in $STATE_DIR/keys.env
EOF
}

reset() {
  psql_db -c "drop schema if exists public cascade; create schema public; grant all on schema public to postgres;"
  migrate
}

down() {
  docker rm -f rv-mail rv-auth rv-rest >/dev/null 2>&1 || true
  if [ -f "$STATE_DIR/gateway.pid" ]; then
    kill "$(cat "$STATE_DIR/gateway.pid")" 2>/dev/null || true
    rm -f "$STATE_DIR/gateway.pid"
  fi
}

case "${1:-up}" in
  up) up ;;
  migrate) migrate ;;
  reset) reset ;;
  down) down ;;
  *) echo "usage: $0 up|migrate|reset|down" >&2; exit 2 ;;
esac
