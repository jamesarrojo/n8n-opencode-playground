#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# n8n OpenCode Community Node Deployment
#
# Usage:
#   ./deploy-opencode-node.sh n8n-nodes-opencode-X.Y.Z.tgz
#
# Must be run from the directory containing compose.yaml.
#
# IMPORTANT:
#   - Does NOT run npm install inside the n8n container.
#   - Preserves existing package-local runtime dependencies.
#   - Creates a backup outside node_modules.
#   - Automatically rolls back if deployment/restart fails.
# ============================================================

SERVICE="n8n"
PACKAGE_NAME="n8n-nodes-opencode"

NODES_DIR="/home/node/.n8n/nodes"
PACKAGE_DIR="${NODES_DIR}/node_modules/${PACKAGE_NAME}"
ROOT_PACKAGE_JSON="${NODES_DIR}/package.json"

CONTAINER_TGZ="/tmp/${PACKAGE_NAME}-deploy.tgz"
STAGING_DIR="/tmp/${PACKAGE_NAME}-deploy"
PRESERVED_DEPS="/tmp/${PACKAGE_NAME}-preserved-node_modules"
BACKUP_DIR="/tmp/${PACKAGE_NAME}-backup"

DEPLOY_STARTED=false
BACKUP_CREATED=false
ROLLBACK_RUNNING=false


# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

log() {
    printf '\n==> %s\n' "$*"
}

die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}


# ------------------------------------------------------------
# Rollback
# ------------------------------------------------------------

rollback() {
    local exit_code=$?

    # Avoid recursive rollback if rollback itself fails.
    if [ "$ROLLBACK_RUNNING" = true ]; then
        printf '\nERROR: Rollback itself encountered an error.\n' >&2
        printf 'Backup has been preserved at: %s\n' "$BACKUP_DIR" >&2
        exit "$exit_code"
    fi

    # Nothing has been modified yet.
    if [ "$DEPLOY_STARTED" != true ] || [ "$BACKUP_CREATED" != true ]; then
        exit "$exit_code"
    fi

    ROLLBACK_RUNNING=true
    trap - ERR

    printf '\n'
    printf '%s\n' "=============================================="
    printf '%s\n' " DEPLOYMENT FAILED - STARTING ROLLBACK"
    printf '%s\n' "=============================================="

    log "Restoring previous OpenCode package"

    if ! docker compose exec -T "$SERVICE" sh -c "
        set -e

        test -d '$BACKUP_DIR/package'
        test -f '$BACKUP_DIR/root-package.json'

        rm -rf '$PACKAGE_DIR'
        cp -a '$BACKUP_DIR/package' '$PACKAGE_DIR'

        cp '$BACKUP_DIR/root-package.json' \
           '$ROOT_PACKAGE_JSON'
    "; then
        printf '\nERROR: Could not restore the backup.\n' >&2
        printf 'Backup preserved at: %s\n' "$BACKUP_DIR" >&2
        exit "$exit_code"
    fi

    log "Restarting n8n with restored package"

    if ! docker compose restart "$SERVICE"; then
        printf '\nERROR: Package was restored, but n8n restart failed.\n' >&2
        printf 'Backup preserved at: %s\n' "$BACKUP_DIR" >&2
        exit "$exit_code"
    fi

    sleep 8

    printf '\n'
    printf '%s\n' "=============================================="
    printf '%s\n' " ROLLBACK COMPLETED"
    printf '%s\n' " Previous OpenCode package has been restored."
    printf '%s\n' "=============================================="
    printf '\n'

    echo "Recent n8n logs after rollback:"
    docker compose logs --since=30s "$SERVICE" || true

    printf '\nBackup preserved at: %s\n' "$BACKUP_DIR"
    printf 'Inspect it before deleting it manually.\n'

    exit "$exit_code"
}

trap rollback ERR


# ------------------------------------------------------------
# Input validation
# ------------------------------------------------------------

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 ${PACKAGE_NAME}-X.Y.Z.tgz"
    exit 1
fi

TGZ="$1"

[ -f "$TGZ" ] || die "Package not found: $TGZ"


# ------------------------------------------------------------
# Make sure we're in the Compose directory
# ------------------------------------------------------------

if [ ! -f "compose.yaml" ] && [ ! -f "compose.yml" ] &&
   [ ! -f "docker-compose.yaml" ] && [ ! -f "docker-compose.yml" ]; then
    die "No Compose file found in the current directory."
fi


# ------------------------------------------------------------
# Locate n8n
# ------------------------------------------------------------

log "Locating n8n container"

CONTAINER_ID="$(docker compose ps -q "$SERVICE")"

[ -n "$CONTAINER_ID" ] ||
    die "Could not find the n8n container."

RUNNING="$(docker inspect -f '{{.State.Running}}' "$CONTAINER_ID")"

[ "$RUNNING" = "true" ] ||
    die "n8n container is not running."

echo "Container: $CONTAINER_ID"


# ------------------------------------------------------------
# Copy artifact
# ------------------------------------------------------------

log "Copying package into n8n container"

docker cp "$TGZ" "${CONTAINER_ID}:${CONTAINER_TGZ}"


# ------------------------------------------------------------
# Extract artifact
# ------------------------------------------------------------

log "Extracting package"

docker compose exec -T "$SERVICE" sh -c "
    set -e

    rm -rf '$STAGING_DIR'
    mkdir -p '$STAGING_DIR'

    tar -xzf '$CONTAINER_TGZ' -C '$STAGING_DIR'

    test -f '$STAGING_DIR/package/package.json'
"


# ------------------------------------------------------------
# Read artifact metadata
# ------------------------------------------------------------

log "Inspecting package metadata"

PACKAGE_INFO="$(
docker compose exec -T "$SERVICE" node -e "
const fs = require('fs');

const p = JSON.parse(
    fs.readFileSync(
        '$STAGING_DIR/package/package.json',
        'utf8'
    )
);

console.log(p.name + ' ' + p.version);
"
)"

PACKAGE_INFO="$(printf '%s' "$PACKAGE_INFO" | tr -d '\r')"

ARTIFACT_NAME="${PACKAGE_INFO%% *}"
ARTIFACT_VERSION="${PACKAGE_INFO#* }"

[ "$ARTIFACT_NAME" = "$PACKAGE_NAME" ] ||
    die "Unexpected package name: $ARTIFACT_NAME"

[ -n "$ARTIFACT_VERSION" ] ||
    die "Could not determine package version."

echo "Package: $ARTIFACT_NAME"
echo "Version: $ARTIFACT_VERSION"


# ------------------------------------------------------------
# Verify expected OpenCode files/fixes
# ------------------------------------------------------------

log "Verifying OpenCode package"

docker compose exec -T "$SERVICE" sh -c "
    set -e

    NEW='$STAGING_DIR/package'

    test -f \
        \"\$NEW/dist/credentials/OpenCodeApi.credentials.js\"

    test -f \
        \"\$NEW/dist/nodes/LmChatOpenCode/OpenCodeChatModel.js\"

    grep -q '/global/health' \
        \"\$NEW/dist/credentials/OpenCodeApi.credentials.js\"

    grep -q 'JSON.stringify({})' \
        \"\$NEW/dist/nodes/LmChatOpenCode/OpenCodeChatModel.js\"
"

echo "OpenCode compatibility checks: OK"


# ------------------------------------------------------------
# Verify current installation
# ------------------------------------------------------------

log "Checking current installation"

docker compose exec -T "$SERVICE" sh -c "
    set -e

    test -d '$PACKAGE_DIR'
    test -f '$PACKAGE_DIR/package.json'
    test -f '$ROOT_PACKAGE_JSON'

    test -d '$PACKAGE_DIR/node_modules'

    test -f \
        '$PACKAGE_DIR/node_modules/@langchain/core/package.json'
"

CURRENT_VERSION="$(
docker compose exec -T "$SERVICE" node -e "
const fs = require('fs');

const p = JSON.parse(
    fs.readFileSync(
        '$PACKAGE_DIR/package.json',
        'utf8'
    )
);

console.log(p.version);
"
)"

CURRENT_VERSION="$(printf '%s' "$CURRENT_VERSION" | tr -d '\r')"

echo "Current version: $CURRENT_VERSION"
echo "New version:     $ARTIFACT_VERSION"


# ------------------------------------------------------------
# Prevent accidental same-version deployment
# ------------------------------------------------------------

if [ "$CURRENT_VERSION" = "$ARTIFACT_VERSION" ]; then
    die "Version $ARTIFACT_VERSION is already installed."
fi


# ------------------------------------------------------------
# Create rollback backup
#
# IMPORTANT:
# This lives in /tmp, NOT inside node_modules.
# ------------------------------------------------------------

log "Creating rollback backup"

docker compose exec -T "$SERVICE" sh -c "
    set -e

    rm -rf '$BACKUP_DIR'
    mkdir -p '$BACKUP_DIR'

    cp -a '$PACKAGE_DIR' \
          '$BACKUP_DIR/package'

    cp '$ROOT_PACKAGE_JSON' \
       '$BACKUP_DIR/root-package.json'

    test -f '$BACKUP_DIR/package/package.json'
    test -f '$BACKUP_DIR/root-package.json'
"

BACKUP_CREATED=true

echo "Backup: $BACKUP_DIR"


# ------------------------------------------------------------
# Begin transaction
# ------------------------------------------------------------

DEPLOY_STARTED=true


# ------------------------------------------------------------
# Preserve runtime dependencies and replace package
# ------------------------------------------------------------

log "Deploying $PACKAGE_NAME $ARTIFACT_VERSION"

docker compose exec -T "$SERVICE" sh -c "
    set -e

    CURRENT='$PACKAGE_DIR'
    NEW='$STAGING_DIR/package'
    DEPS='$PRESERVED_DEPS'

    rm -rf \"\$DEPS\"

    # Preserve package-local runtime dependencies.
    mv \"\$CURRENT/node_modules\" \"\$DEPS\"

    # Remove old application package.
    rm -rf \"\$CURRENT\"

    # Move new application package into place.
    mv \"\$NEW\" \"\$CURRENT\"

    # Restore existing runtime dependencies.
    mv \"\$DEPS\" \"\$CURRENT/node_modules\"

    # Confirm LangChain survived.
    test -f \
        \"\$CURRENT/node_modules/@langchain/core/package.json\"
"


# ------------------------------------------------------------
# Update n8n's community-node metadata
# ------------------------------------------------------------

log "Updating n8n community-node metadata"

docker compose exec -T "$SERVICE" node -e "
const fs = require('fs');

const path = '$ROOT_PACKAGE_JSON';
const pkg = JSON.parse(
    fs.readFileSync(path, 'utf8')
);

pkg.dependencies = pkg.dependencies || {};

pkg.dependencies['$PACKAGE_NAME'] =
    '$ARTIFACT_VERSION';

fs.writeFileSync(
    path,
    JSON.stringify(pkg, null, 2) + '\n'
);
"


# ------------------------------------------------------------
# Verify installed state BEFORE restart
# ------------------------------------------------------------

log "Verifying deployed installation"

docker compose exec -T "$SERVICE" node -e "
const fs = require('fs');

const installed = JSON.parse(
    fs.readFileSync(
        '$PACKAGE_DIR/package.json',
        'utf8'
    )
);

const root = JSON.parse(
    fs.readFileSync(
        '$ROOT_PACKAGE_JSON',
        'utf8'
    )
);

const installedVersion = installed.version;

const metadataVersion =
    root.dependencies &&
    root.dependencies['$PACKAGE_NAME'];

console.log(
    'Installed package: $PACKAGE_NAME ' +
    installedVersion
);

console.log(
    'n8n metadata:      $PACKAGE_NAME ' +
    metadataVersion
);

if (installedVersion !== '$ARTIFACT_VERSION') {
    throw new Error(
        'Installed package version does not match artifact.'
    );
}

if (metadataVersion !== '$ARTIFACT_VERSION') {
    throw new Error(
        'n8n metadata version does not match artifact.'
    );
}
"

docker compose exec -T "$SERVICE" sh -c "
    set -e

    test -f \
        '$PACKAGE_DIR/node_modules/@langchain/core/package.json'

    grep -q '/global/health' \
        '$PACKAGE_DIR/dist/credentials/OpenCodeApi.credentials.js'

    grep -q 'JSON.stringify({})' \
        '$PACKAGE_DIR/dist/nodes/LmChatOpenCode/OpenCodeChatModel.js'
"

echo "Package version:       OK"
echo "n8n metadata:          OK"
echo "@langchain/core:       OK"
echo "Credential fix:        OK"
echo "Session creation fix:  OK"


# ------------------------------------------------------------
# Restart n8n
# ------------------------------------------------------------

log "Restarting n8n"

docker compose restart "$SERVICE"


# ------------------------------------------------------------
# Wait for container
# ------------------------------------------------------------

log "Waiting for n8n to start"

STARTED=false

for attempt in $(seq 1 12); do

    sleep 5

    NEW_CONTAINER_ID="$(docker compose ps -q "$SERVICE")"

    if [ -z "$NEW_CONTAINER_ID" ]; then
        echo "Attempt $attempt/12: container not found yet..."
        continue
    fi

    RUNNING="$(
        docker inspect \
            -f '{{.State.Running}}' \
            "$NEW_CONTAINER_ID" \
            2>/dev/null || true
    )"

    if [ "$RUNNING" != "true" ]; then
        echo "Attempt $attempt/12: container not running yet..."
        continue
    fi

    # Check n8n itself, not merely Docker's container state.
    #
    # Node is guaranteed to exist in the n8n image, so this does
    # not depend on curl/wget being installed.
    if docker compose exec -T "$SERVICE" node -e "
const http = require('http');

const req = http.get(
    {
        host: '127.0.0.1',
        port: 5678,
        path: '/healthz',
        timeout: 3000
    },
    (res) => {
        res.resume();

        if (res.statusCode >= 200 &&
            res.statusCode < 500) {
            process.exit(0);
        }

        process.exit(1);
    }
);

req.on('timeout', () => {
    req.destroy();
    process.exit(1);
});

req.on('error', () => {
    process.exit(1);
});
"; then
        STARTED=true
        break
    fi

    echo "Attempt $attempt/12: n8n not ready yet..."
done


# ------------------------------------------------------------
# Fail -> trap triggers rollback
# ------------------------------------------------------------

if [ "$STARTED" != true ]; then
    echo "n8n failed readiness check." >&2
    false
fi


# ------------------------------------------------------------
# Post-restart verification
# ------------------------------------------------------------

log "n8n is responding"

docker compose exec -T "$SERVICE" node -e "
const fs = require('fs');

const installed = JSON.parse(
    fs.readFileSync(
        '$PACKAGE_DIR/package.json',
        'utf8'
    )
);

if (installed.version !== '$ARTIFACT_VERSION') {
    throw new Error(
        'Wrong OpenCode version after restart.'
    );
}

console.log(
    'OpenCode package after restart: ' +
    installed.version
);
"

docker compose exec -T "$SERVICE" sh -c "
    set -e

    test -f \
        '$PACKAGE_DIR/node_modules/@langchain/core/package.json'
"


# ------------------------------------------------------------
# Deployment succeeded.
# Disable rollback before cleanup.
# ------------------------------------------------------------

DEPLOY_STARTED=false
trap - ERR


# ------------------------------------------------------------
# Clean temporary deployment files
#
# Backup is deleted ONLY after successful restart + verification.
# ------------------------------------------------------------

log "Cleaning temporary files"

docker compose exec -T "$SERVICE" sh -c "
    rm -rf \
        '$STAGING_DIR' \
        '$PRESERVED_DEPS' \
        '$BACKUP_DIR'

    rm -f '$CONTAINER_TGZ'
"


# ------------------------------------------------------------
# Success
# ------------------------------------------------------------

printf '\n'
printf '%s\n' "=============================================="
printf '%s\n' " DEPLOYMENT COMPLETED SUCCESSFULLY"
printf '%s\n' "----------------------------------------------"
printf ' Package:   %s\n' "$PACKAGE_NAME"
printf ' Previous:  %s\n' "$CURRENT_VERSION"
printf ' Installed: %s\n' "$ARTIFACT_VERSION"
printf '%s\n' "=============================================="

echo
echo "Recent n8n logs:"
docker compose logs --since=30s "$SERVICE"
