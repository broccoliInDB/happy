#!/usr/bin/env bash
#
# self-host-postgres.sh
# ---------------------
# Prepare an external Postgres for a self-hosted Happy server and print the
# exact `happy server` command to launch against it.
#
# WHY THIS EXISTS
#   The self-host CLI (`happy server`) defaults to an embedded PGlite database.
#   PGlite + pglite-prisma-adapter@0.7.2 (which wants prisma>=7.1.0 while the
#   server pins 6.19.2) corrupts `Bytes` columns (e.g. Session.dataEncryptionKey)
#   on `findMany`, which breaks the mobile app's session list. Switching to a real
#   Postgres uses Prisma's native query engine and sidesteps the broken adapter.
#
#   packages/happy-cli/src/commands/server.ts is already patched so that, when
#   DATABASE_URL is set in the environment, it spawns happy-server with
#   DB_PROVIDER=postgres instead of pglite. This script stands up that Postgres
#   and hands you the launch command.
#
# MIGRATIONS (now handled by the CLI)
#   `happy server` runs a `migrate` step on startup. That step used to be
#   hardcoded to PGlite and ignored DATABASE_URL, so this script migrated
#   Postgres itself. That gap is now fixed in the server code:
#   packages/happy-server/sources/standalone.ts -> runMigrations() detects
#   DATABASE_URL and runs `prisma migrate deploy` against the external Postgres.
#   So this script no longer migrates — the printed/launched `happy server`
#   command does it. (prisma migrate deploy is idempotent regardless.)
#
# SAFETY
#   - Postgres is bound to 127.0.0.1 only; it is never exposed on the tailnet.
#   - Idempotent: re-running reuses the existing container/volume.
#   - This script does NOT start the Happy server by default — it prints the
#     command so you stay in control. Pass --run to launch it immediately.
#
set -euo pipefail

# ----------------------------------------------------------------------------
# CONFIG — edit these before the first run
# ----------------------------------------------------------------------------

# The mini's Tailscale IP (or MagicDNS name). REQUIRED — leave empty and the
# script will tell you to set it. Example: TAILNET_IP=100.100.100.100
TAILNET_IP="${TAILNET_IP:-}"

# Port the Happy server listens on (mobile app connects here, via your HTTPS proxy).
HAPPY_PORT="${HAPPY_PORT:-3005}"

# Postgres container settings.
# DB name / user mirror packages/happy-server's `pnpm db` script
# (POSTGRES_DB=handy, default superuser `postgres`) so the DATABASE_URL matches
# what the project expects. Migrations don't depend on these names, but keeping
# them consistent avoids surprises.
PG_PORT="${PG_PORT:-5432}"
PG_DB="${PG_DB:-handy}"
PG_USER="${PG_USER:-postgres}"

# Set a strong password BEFORE the first run — it is baked into the data volume
# when the container is first created, so changing it later means recreating the
# container + volume. Generate one with:  openssl rand -hex 16
PG_PASSWORD="${PG_PASSWORD:-REPLACE_WITH_A_STRONG_PASSWORD}"

# Docker object names.
PG_CONTAINER="${PG_CONTAINER:-happy-postgres}"
PG_VOLUME="${PG_VOLUME:-happy-pgdata}"

# Postgres image. The Prisma datasource provider is `postgresql` and the
# committed migrations use only standard SQL (no CREATE EXTENSION, no
# version-specific features — verified by grep), so any modern major works.
# 16 is a safe, current stable; bump freely. Nothing in the repo pins a version.
PG_IMAGE="${PG_IMAGE:-postgres:16}"

# ----------------------------------------------------------------------------
# Derived values
# ----------------------------------------------------------------------------

# The server connects over localhost, so credentials never leave the machine.
DATABASE_URL="postgres://${PG_USER}:${PG_PASSWORD}@localhost:${PG_PORT}/${PG_DB}"

RUN_SERVER=0
for arg in "$@"; do
    case "$arg" in
        --run) RUN_SERVER=1 ;;
        -h|--help)
            echo "Usage: $0 [--run]"
            echo "  (default)  Prepare Postgres + migrate, then PRINT the happy server command."
            echo "  --run      Same, but also launch the Happy server at the end."
            exit 0
            ;;
        *) echo "Unknown arg: $arg" >&2; exit 1 ;;
    esac
done

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# (1) Preflight
# ----------------------------------------------------------------------------

if ! command -v docker >/dev/null 2>&1; then
    die "docker not found. Install Docker Desktop (macOS: https://docs.docker.com/desktop/install/mac-install/) and re-run."
fi

if ! docker info >/dev/null 2>&1; then
    die "docker is installed but the daemon isn't running. Start Docker Desktop and re-run."
fi

if [ -z "${TAILNET_IP}" ]; then
    die "TAILNET_IP is empty. Set the mini's tailscale IP, e.g.:  TAILNET_IP=100.x.y.z $0"
fi

if [ "${PG_PASSWORD}" = "REPLACE_WITH_A_STRONG_PASSWORD" ]; then
    warn "PG_PASSWORD is still the placeholder. For a local-only (127.0.0.1) DB this is low-risk,"
    warn "but you should set a real one:  PG_PASSWORD=\$(openssl rand -hex 16) $0"
fi

# ----------------------------------------------------------------------------
# (2) Start-or-create the Postgres container (persistent named volume)
# ----------------------------------------------------------------------------

if docker ps --format '{{.Names}}' | grep -qx "${PG_CONTAINER}"; then
    log "Container '${PG_CONTAINER}' already running — reusing it."
elif docker ps -a --format '{{.Names}}' | grep -qx "${PG_CONTAINER}"; then
    log "Container '${PG_CONTAINER}' exists but is stopped — starting it."
    docker start "${PG_CONTAINER}" >/dev/null
else
    log "Creating container '${PG_CONTAINER}' (image ${PG_IMAGE}, volume ${PG_VOLUME})."
    # Bind to 127.0.0.1 only: Postgres must never be reachable over the tailnet.
    docker run -d \
        --name "${PG_CONTAINER}" \
        --restart unless-stopped \
        -e POSTGRES_USER="${PG_USER}" \
        -e POSTGRES_PASSWORD="${PG_PASSWORD}" \
        -e POSTGRES_DB="${PG_DB}" \
        -v "${PG_VOLUME}:/var/lib/postgresql/data" \
        -p "127.0.0.1:${PG_PORT}:5432" \
        "${PG_IMAGE}" >/dev/null
fi

# ----------------------------------------------------------------------------
# (3) Wait for Postgres to accept connections
# ----------------------------------------------------------------------------

log "Waiting for Postgres to accept connections..."
for i in $(seq 1 60); do
    if docker exec "${PG_CONTAINER}" pg_isready -U "${PG_USER}" -d "${PG_DB}" >/dev/null 2>&1; then
        log "Postgres is ready."
        break
    fi
    if [ "$i" -eq 60 ]; then
        die "Postgres did not become ready in 60s. Check: docker logs ${PG_CONTAINER}"
    fi
    sleep 1
done

# ----------------------------------------------------------------------------
# (4) Export DATABASE_URL (used by both migrate and the server)
# ----------------------------------------------------------------------------

export DATABASE_URL
log "DATABASE_URL set (postgres://${PG_USER}:***@localhost:${PG_PORT}/${PG_DB})."

# ----------------------------------------------------------------------------
# (5) Migrations are handled by `happy server` itself (see header).
# ----------------------------------------------------------------------------
# No `prisma migrate deploy` here: the CLI's startup `migrate` step now detects
# DATABASE_URL and migrates the external Postgres (standalone.ts runMigrations).
# Migrating here too would just double-run the same idempotent step. The printed
# (or --run) `happy server` command below applies the migrations.

# ----------------------------------------------------------------------------
# (6) Print (or run) the Happy server command
# ----------------------------------------------------------------------------

HAPPY_CMD=$(cat <<EOF
DATABASE_URL="${DATABASE_URL}" happy server \\
  --host "${TAILNET_IP}" \\
  --port "${HAPPY_PORT}" \\
  --i-understand-this-will-modify-default-happy-settings
EOF
)

echo
log "Postgres is up. Start the Happy server with (it migrates on startup):"
echo
echo "${HAPPY_CMD}"
echo

if [ "${RUN_SERVER}" -eq 1 ]; then
    log "--run passed: launching the Happy server now."
    exec happy server \
        --host "${TAILNET_IP}" \
        --port "${HAPPY_PORT}" \
        --i-understand-this-will-modify-default-happy-settings
fi

# ----------------------------------------------------------------------------
# (7) What to verify
# ----------------------------------------------------------------------------

cat <<EOF
What to verify after starting the server:
  - The startup banner prints:  db:  external postgres (DATABASE_URL)
    (NOT "embedded pglite" — if it says pglite, DATABASE_URL wasn't picked up.)
  - Migrations are present in Postgres:
      docker exec ${PG_CONTAINER} psql -U ${PG_USER} -d ${PG_DB} -c '\dt'
    (You should see Account, Session, Project, ... tables.)
  - In the mobile app, the session list loads without a 500 / without hanging
    (this was the original PGlite Bytes-column bug — gone on Postgres).
EOF
