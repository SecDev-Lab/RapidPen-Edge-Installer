#!/bin/sh
#
# RapidPen Supervisor Upgrade Check Script
#
# This script is executed by systemd ExecStartPre to check if a supervisor upgrade is required.
# It reads the state.json file and performs the upgrade if target_image_tag is set.
#

set -e  # Exit on error

STATE_FILE="/etc/rapidpen/supervisor/state.json"
LOG_PREFIX="[UPGRADE CHECK]"

# Logging functions
log_info() {
    echo "$LOG_PREFIX [INFO] $1"
}

log_error() {
    echo "$LOG_PREFIX [ERROR] $1" >&2
}

# Check if state.json exists
if [ ! -f "$STATE_FILE" ]; then
    log_error "State file not found: $STATE_FILE"
    exit 1
fi

# jq execution helper function
jq_exec() {
    if command -v jq > /dev/null 2>&1; then
        # Use local jq
        jq "$@"
    else
        # Use Docker container to run jq
        docker run --rm -i imega/jq "$@"
    fi
}

# Read current image_tag and target_image_tag from state.json
log_info "Reading state.json..."

IMAGE_TAG=$(cat "$STATE_FILE" | jq_exec -r '.image_tag // empty')
TARGET_IMAGE_TAG=$(cat "$STATE_FILE" | jq_exec -r '.target_image_tag // empty')

if [ -z "$IMAGE_TAG" ]; then
    log_error "image_tag is not set in state.json"
    exit 1
fi

log_info "Current image_tag: $IMAGE_TAG"
log_info "Target image_tag: ${TARGET_IMAGE_TAG:-null}"

# Check if upgrade is required
if [ -z "$TARGET_IMAGE_TAG" ] || [ "$TARGET_IMAGE_TAG" = "null" ]; then
    log_info "No upgrade required"
    exit 0
fi

# Check if target_image_tag is different from image_tag
if [ "$TARGET_IMAGE_TAG" = "$IMAGE_TAG" ]; then
    log_info "Target image tag is same as current image tag, clearing target_image_tag"
    # Clear target_image_tag
    TMP_FILE=$(mktemp)
    cat "$STATE_FILE" | jq_exec '.target_image_tag = null' > "$TMP_FILE"
    mv "$TMP_FILE" "$STATE_FILE"
    chmod 600 "$STATE_FILE"
    exit 0
fi

# Upgrade is required
log_info "Upgrade required: $IMAGE_TAG -> $TARGET_IMAGE_TAG"

# Construct full image name
FULL_IMAGE_NAME="ghcr.io/secdev-lab/rapidpen-supervisor:$TARGET_IMAGE_TAG"

# Pull new image
log_info "Pulling new image: $FULL_IMAGE_NAME"
if ! docker pull "$FULL_IMAGE_NAME"; then
    log_error "Failed to pull image: $FULL_IMAGE_NAME"
    log_info "Falling back to current version: $IMAGE_TAG"

    # target_image_tag をクリアして現行バージョンで起動
    TMP_FILE=$(mktemp)
    cat "$STATE_FILE" | jq_exec '.target_image_tag = null' > "$TMP_FILE"
    mv "$TMP_FILE" "$STATE_FILE"
    chmod 600 "$STATE_FILE"

    exit 0  # 成功として終了し、現行バージョンで起動
fi

log_info "Image pulled successfully"

# Update state.json: image_tag = target_image_tag, target_image_tag = null
log_info "Updating state.json..."
TMP_FILE=$(mktemp)
cat "$STATE_FILE" | jq_exec --arg new_tag "$TARGET_IMAGE_TAG" \
    '.image_tag = $new_tag | .target_image_tag = null' > "$TMP_FILE"

# Atomic replace
mv "$TMP_FILE" "$STATE_FILE"
chmod 600 "$STATE_FILE"

log_info "Upgrade completed successfully"
log_info "New image_tag: $TARGET_IMAGE_TAG"

exit 0
