#!/bin/sh
set -e  # Exit on error

# Color output settings
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions (POSIX-compliant printf)
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
echo "  RapidPen Edge Uninstaller               "
echo "==========================================="
echo ""

# 1. Root privilege check (POSIX-compliant)
log_info "Checking root privileges..."
if [ "$(id -u)" -ne 0 ]; then
   log_error "This script must be run as root (use sudo)"
   echo "Usage: sudo sh $0"
   exit 1
fi
log_info "✓ Running as root"

# 2. Confirmation prompt
echo ""
log_warn "This will remove RapidPen Supervisor and all related files."
log_warn "The following will be removed:"
echo "  - systemd service (rapidpen-supervisor)"
echo "  - Docker container (rapidpen-supervisor)"
echo "  - Configuration files (/etc/rapidpen/)"
echo "  - Log files (/var/log/rapidpen/)"
echo ""
printf "Are you sure you want to continue? [y/N]: "
read -r CONFIRM

if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    log_info "Uninstallation cancelled"
    exit 0
fi

echo ""
log_info "Starting uninstallation..."

# 3. Stop, disable, and remove systemd service
if [ -f "/etc/systemd/system/rapidpen-supervisor.service" ]; then
    log_info "Stopping and disabling systemd service..."

    # Stop service
    systemctl stop rapidpen-supervisor 2>/dev/null || true
    log_info "  Service stopped"

    # Disable service
    systemctl disable rapidpen-supervisor 2>/dev/null || true
    log_info "  Service disabled"

    # Remove service file
    rm -f /etc/systemd/system/rapidpen-supervisor.service
    log_info "  Service file removed"

    # Reload systemd
    systemctl daemon-reload
    log_info "  Systemd daemon reloaded"
else
    log_warn "systemd service not found (skipping)"
fi

# 4. Stop and remove Docker container
log_info "Cleaning up Docker resources..."

if command -v docker > /dev/null 2>&1; then
    # Stop and remove container
    if docker ps -a 2>/dev/null | grep -q rapidpen-supervisor; then
        docker rm -f rapidpen-supervisor > /dev/null 2>&1
        log_info "  Container removed"
    else
        log_warn "  Container not found (skipping)"
    fi
else
    log_warn "  Docker not found (skipping container cleanup)"
fi

# Note: Docker images are preserved (may be used elsewhere)
log_info "  Note: Docker images are preserved"

# 5. Remove files and directories
log_info "Removing files and directories..."

# Configuration directory
if [ -d "/etc/rapidpen" ]; then
    rm -rf /etc/rapidpen
    log_info "  Removed /etc/rapidpen/"
else
    log_warn "  /etc/rapidpen/ not found"
fi

# Log directory
if [ -d "/var/log/rapidpen" ]; then
    rm -rf /var/log/rapidpen
    log_info "  Removed /var/log/rapidpen/"
else
    log_warn "  /var/log/rapidpen/ not found"
fi

# Uninstall command itself
if [ -f "/usr/bin/rapidpen-uninstall" ]; then
    rm -f /usr/bin/rapidpen-uninstall
    log_info "  Removed /usr/bin/rapidpen-uninstall"
else
    log_warn "  /usr/bin/rapidpen-uninstall not found"
fi

# 6. Completion message
echo ""
echo "==========================================="
log_info "Uninstallation completed successfully!"
echo "==========================================="
echo ""
echo "RapidPen Supervisor has been removed from your system."
echo "To reinstall, run: sudo sh install.sh"
echo ""
