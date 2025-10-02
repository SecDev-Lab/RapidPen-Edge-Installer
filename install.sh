#!/bin/sh
#
# RapidPen Edge Installer - Bootstrap Script
#
# This script downloads the latest installer archive and runs the actual setup.
# Usage: curl -fsSL https://raw.githubusercontent.com/SecDev-Lab/RapidPen-Edge-Installer/main/install.sh | sudo sh
#

set -e  # Exit on error

# Color output settings
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    printf "${GREEN}[INFO]${NC} %s\n" "$1"
}

log_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1"
}

log_warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

echo "==========================================="
echo "  RapidPen Edge Installer (Bootstrap)     "
echo "==========================================="
echo ""

# Root privilege check
log_info "Checking root privileges..."
if [ "$(id -u)" -ne 0 ]; then
   log_error "This script must be run as root (use sudo)"
   echo "Usage: curl -fsSL https://raw.githubusercontent.com/SecDev-Lab/RapidPen-Edge-Installer/main/install.sh | sudo sh"
   exit 1
fi
log_info "✓ Running as root"

# Check required commands
log_info "Checking required commands..."
for cmd in curl tar; do
    if ! command -v "$cmd" > /dev/null 2>&1; then
        log_error "$cmd is required but not installed"
        echo "Please install $cmd first:"
        echo "  Ubuntu/Debian: sudo apt-get install $cmd"
        exit 1
    fi
done
log_info "✓ Required commands available"

# Download and extract installer
REPO="SecDev-Lab/RapidPen-Edge-Installer"
BRANCH="main"
RELEASE_URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"

log_info "Downloading installer from GitHub..."
TMPDIR=$(mktemp -d /tmp/rapidpen-installer.XXXXXX)

if ! curl -fsSL "$RELEASE_URL" | tar xz -C "$TMPDIR" --strip-components=1 2>/dev/null; then
    log_error "Failed to download or extract installer"
    log_error "  Tried: $RELEASE_URL"
    rm -rf "$TMPDIR"
    exit 1
fi

log_info "✓ Installer downloaded to $TMPDIR"

# Run actual installer
log_info "Running setup script..."
echo ""

cd "$TMPDIR"
if [ -f "setup.sh" ]; then
    sh setup.sh "$@"
    SETUP_EXIT_CODE=$?
else
    log_error "setup.sh not found in the installer archive"
    cd /
    rm -rf "$TMPDIR"
    exit 1
fi

# Cleanup
log_info "Cleaning up temporary files..."
cd /
rm -rf "$TMPDIR"

# Exit with setup.sh's exit code
exit $SETUP_EXIT_CODE
