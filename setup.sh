#!/bin/sh
set -e  # エラーが発生したら即停止

# カラー出力用の設定
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ログ関数（printf使用でPOSIX準拠）
log_info() {
    printf "${GREEN}[INFO]${NC} %s\n" "$1"
}

log_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1"
}

log_warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

# クリーンアップ関数（インストール失敗時）
cleanup_on_error() {
    log_error "Installation failed. Cleaning up..."

    # Stop and disable supervisor service if it was started
    if systemctl is-active --quiet rapidpen-supervisor 2>/dev/null; then
        systemctl stop rapidpen-supervisor
        log_info "  Stopped rapidpen-supervisor service"
    fi

    if systemctl is-enabled --quiet rapidpen-supervisor 2>/dev/null; then
        systemctl disable rapidpen-supervisor
        log_info "  Disabled rapidpen-supervisor service"
    fi

    # Remove supervisor systemd service file
    if [ -f /etc/systemd/system/rapidpen-supervisor.service ]; then
        rm /etc/systemd/system/rapidpen-supervisor.service
        log_info "  Removed rapidpen-supervisor service file"
    fi

    # Stop and disable fluent-bit service if it was started
    if systemctl is-active --quiet rapidpen-fluent-bit 2>/dev/null; then
        systemctl stop rapidpen-fluent-bit
        log_info "  Stopped rapidpen-fluent-bit service"
    fi

    if systemctl is-enabled --quiet rapidpen-fluent-bit 2>/dev/null; then
        systemctl disable rapidpen-fluent-bit
        log_info "  Disabled rapidpen-fluent-bit service"
    fi

    # Remove fluent-bit systemd service file
    if [ -f /etc/systemd/system/rapidpen-fluent-bit.service ]; then
        rm /etc/systemd/system/rapidpen-fluent-bit.service
        log_info "  Removed rapidpen-fluent-bit service file"
    fi

    # Reload systemd
    systemctl daemon-reload

    # Remove upgrade check script
    if [ -f /usr/local/bin/rapidpen-supervisor-check-upgrade.sh ]; then
        rm /usr/local/bin/rapidpen-supervisor-check-upgrade.sh
        log_info "  Removed upgrade check script"
    fi

    # Remove configuration directories
    if [ -d /etc/rapidpen ]; then
        rm -rf /etc/rapidpen
        log_info "  Removed /etc/rapidpen/"
    fi

    # Remove log directories
    if [ -d /var/log/rapidpen ]; then
        rm -rf /var/log/rapidpen
        log_info "  Removed /var/log/rapidpen/"
    fi

    # Remove supervisor Docker image
    if [ -n "$SUPERVISOR_IMAGE" ]; then
        if docker image inspect "$SUPERVISOR_IMAGE" >/dev/null 2>&1; then
            docker rmi "$SUPERVISOR_IMAGE" >/dev/null 2>&1
            log_info "  Removed Docker image: $SUPERVISOR_IMAGE"
        fi
    fi

    # Remove fluent-bit Docker image
    if docker image inspect fluent/fluent-bit:latest >/dev/null 2>&1; then
        docker rmi fluent/fluent-bit:latest >/dev/null 2>&1
        log_info "  Removed Docker image: fluent/fluent-bit:latest"
    fi

    log_error "Cleanup completed. Please resolve the issue and try again."
}

echo "==========================="
echo "  RapidPen Edge Installer  "
echo "==========================="
echo ""

# 1. root権限チェック（POSIX準拠）
log_info "Checking root privileges..."
if [ "$(id -u)" -ne 0 ]; then
   log_error "This script must be run as root (use sudo)"
   echo "Usage: sudo sh $0"
   exit 1
fi
log_info "✓ Running as root"

# 2. Dockerの存在確認と環境検出
log_info "Checking Docker installation..."

# Dockerバイナリパス検出
DOCKER_BIN=$(command -v docker 2>/dev/null) || DOCKER_BIN=""
if [ -z "$DOCKER_BIN" ]; then
    log_error "Docker is not installed"
    echo ""
    echo "Please install Docker first:"
    echo "  Ubuntu/Debian: sudo apt-get install docker.io"
    echo "  Or visit: https://docs.docker.com/engine/install/"
    exit 1
fi

# Dockerバージョン確認（情報のみ）
DOCKER_VERSION=$("$DOCKER_BIN" --version 2>/dev/null | cut -d' ' -f3 | cut -d',' -f1) || DOCKER_VERSION=""
if [ -z "$DOCKER_VERSION" ]; then
    log_error "Docker is installed but not responding"
    echo ""
    echo "Please check if Docker daemon is running:"
    echo "  sudo systemctl status docker"
    exit 1
fi
log_info "✓ Docker found (version: $DOCKER_VERSION)"
log_info "  Docker binary: $DOCKER_BIN"

# Docker socket検出
log_info "Detecting Docker socket..."
DOCKER_SOCK=""

# 標準パスを確認
for sock_path in /var/run/docker.sock /run/docker.sock; do
    if [ -S "$sock_path" ]; then
        DOCKER_SOCK="$sock_path"
        break
    fi
done

# 見つからない場合はエラー
if [ -z "$DOCKER_SOCK" ]; then
    log_error "Docker socket not found"
    echo ""
    echo "Expected locations:"
    echo "  - /var/run/docker.sock"
    echo "  - /run/docker.sock"
    echo ""
    echo "Please check your Docker installation"
    exit 1
fi

log_info "✓ Docker socket found: $DOCKER_SOCK"

# Dockerデーモンの起動確認
log_info "Verifying Docker daemon is running..."
if ! "$DOCKER_BIN" info > /dev/null 2>&1; then
    log_error "Docker daemon is not running"
    echo ""
    echo "Please start Docker:"
    echo "  sudo systemctl start docker"
    echo ""
    echo "To enable Docker on boot:"
    echo "  sudo systemctl enable docker"
    exit 1
fi
log_info "✓ Docker daemon is running"

# 3. 必要なディレクトリ作成
log_info "Creating required directories..."

# /var/log/rapidpen/supervisor - Supervisorログ用
if [ ! -d "/var/log/rapidpen/supervisor" ]; then
    mkdir -p /var/log/rapidpen/supervisor
    log_info "  Created /var/log/rapidpen/supervisor/"
else
    log_info "  /var/log/rapidpen/supervisor/ already exists"
fi

# /var/log/rapidpen/operator - Operatorログ用
if [ ! -d "/var/log/rapidpen/operator" ]; then
    mkdir -p /var/log/rapidpen/operator
    chmod 777 /var/log/rapidpen/operator
    log_info "  Created /var/log/rapidpen/operator/"
else
    log_info "  /var/log/rapidpen/operator/ already exists"
fi

# 4. InstallerConfig生成
log_info "Creating installer configuration file..."

CONFIG_FILE="/etc/rapidpen/supervisor/installer_config.json"

# 設定ディレクトリが存在しない場合は作成
if [ ! -d "/etc/rapidpen/supervisor" ]; then
    mkdir -p /etc/rapidpen/supervisor
    chmod 700 /etc/rapidpen/supervisor
    log_info "  Created /etc/rapidpen/supervisor/"
else
    log_info "  /etc/rapidpen/supervisor/ already exists"
fi

# supervisor_id_candidate生成（デフォルト：sup-hostname）
DEFAULT_HOSTNAME=$(hostname)
SUPERVISOR_ID_CANDIDATE="sup-${DEFAULT_HOSTNAME}"

# InstallerConfig JSON を作成（テンプレートから生成）
SCRIPT_DIR=$(dirname "$0")
INSTALLER_CONFIG_TEMPLATE="$SCRIPT_DIR/templates/installer_config.json.template"

if [ -f "$INSTALLER_CONFIG_TEMPLATE" ]; then
    sed -e "s|{{SUPERVISOR_ID_CANDIDATE}}|$SUPERVISOR_ID_CANDIDATE|g" \
        -e "s|{{LOG_DIR_SUPERVISOR}}|/var/log/rapidpen/supervisor|g" \
        -e "s|{{LOG_DIR_OPERATOR_BASE}}|/var/log/rapidpen/operator|g" \
        "$INSTALLER_CONFIG_TEMPLATE" > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    log_info "  Created installer configuration: $CONFIG_FILE"
    log_info "  Supervisor ID: $SUPERVISOR_ID_CANDIDATE"
else
    log_error "Template not found: $INSTALLER_CONFIG_TEMPLATE"
    exit 1
fi

# 5. RapidPen Cloud接続情報の入力
log_info "Configuring RapidPen Cloud connection..."

# API Key入力（必須）
if [ -n "$RAPIDPEN_API_KEY" ]; then
    # 環境変数から取得（テスト用）
    log_info "  Using API Key from environment variable"
else
    # ユーザーから入力
    echo ""
    echo "Please enter your RapidPen Cloud API Key:"
    echo "(You can obtain this from RapidPen Cloud Web UI)"
    printf "API Key: "
    read -r RAPIDPEN_API_KEY < /dev/tty

    # 空チェック
    while [ -z "$RAPIDPEN_API_KEY" ]; do
        log_error "API Key cannot be empty"
        printf "API Key: "
        read -r RAPIDPEN_API_KEY < /dev/tty
    done

    log_info "  API Key configured"
fi

# Base URL入力（オプション、デフォルト値あり）
DEFAULT_BASEURL="https://api.rapidpen.app/api/edge/supervisor"

if [ -n "$RAPIDPEN_BASEURL" ]; then
    # 環境変数から取得（テスト用）
    log_info "  Using Base URL from environment variable: $RAPIDPEN_BASEURL"
else
    # ユーザーから入力
    echo ""
    echo "RapidPen Cloud Base URL (default: $DEFAULT_BASEURL)"
    echo "(Press Enter to use default, or enter custom URL)"
    printf "Base URL: "
    read -r RAPIDPEN_BASEURL < /dev/tty

    # 空の場合はデフォルト値を使用
    if [ -z "$RAPIDPEN_BASEURL" ]; then
        RAPIDPEN_BASEURL="$DEFAULT_BASEURL"
        log_info "  Using default base URL: $RAPIDPEN_BASEURL"
    else
        log_info "  Using custom base URL: $RAPIDPEN_BASEURL"
    fi
fi

# 6. SupervisorState 初期ファイル作成（後でimage_tagを更新）
log_info "Creating initial supervisor state file..."

STATE_FILE="/etc/rapidpen/supervisor/state.json"
STATE_TEMPLATE="$SCRIPT_DIR/templates/state.json.template"

# 仮のimage_tagで初期化（後でGHCRから取得したタグに更新）
if [ -f "$STATE_TEMPLATE" ]; then
    sed -e "s|{{IMAGE_TAG}}|PLACEHOLDER|g" \
        -e "s|{{RAPIDPEN_CLOUD_API_KEY}}|$RAPIDPEN_API_KEY|g" \
        -e "s|{{RAPIDPEN_CLOUD_BASEURL}}|$RAPIDPEN_BASEURL|g" \
        "$STATE_TEMPLATE" > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
    log_info "  Created supervisor state: $STATE_FILE (image_tag will be updated after fetching image)"
else
    log_error "Template not found: $STATE_TEMPLATE"
    exit 1
fi

# 6. Supervisorイメージの最新版を取得
log_info "Fetching latest supervisor image from GHCR..."

# jq 実行用のヘルパー関数
jq_exec() {
    if command -v jq > /dev/null 2>&1; then
        # ローカルのjqを使用
        jq "$@"
    else
        # Dockerコンテナでjqを実行
        if ! docker run --rm -i imega/jq "$@" 2>/dev/null; then
            log_error "Failed to execute jq (neither local jq nor Docker jq available)"
            return 1
        fi
    fi
}

# curlチェック（必須）
if ! command -v curl > /dev/null 2>&1; then
    log_error "curl is required but not installed"
    echo "Please install curl first:"
    echo "  Ubuntu/Debian: sudo apt-get install curl"
    exit 1
fi

# Supervisorバージョン決定（GitHub Releaseから取得）
RELEASE_URL="https://github.com/SecDev-Lab/RapidPen-Edge-Installer/releases/download/supervisor-latest/supervisor-version.txt"

log_info "Fetching latest supervisor version from GitHub Release..."
SUPERVISOR_VERSION=$(curl -fsSL "$RELEASE_URL" 2>/dev/null)

if [ -z "$SUPERVISOR_VERSION" ]; then
    log_error "Failed to fetch latest supervisor version"
    log_error "  Tried: $RELEASE_URL"
    log_error "  Please check your internet connection"
    exit 1
fi

log_info "Latest supervisor version: $SUPERVISOR_VERSION"

# Supervisorイメージを構築
SUPERVISOR_IMAGE="ghcr.io/secdev-lab/rapidpen-supervisor:$SUPERVISOR_VERSION"
log_info "Supervisor image: $SUPERVISOR_IMAGE"

# Supervisorイメージをpull
log_info "Pulling supervisor image (this may take a moment)..."
if docker pull "$SUPERVISOR_IMAGE" > /dev/null 2>&1; then
    log_info "✓ Image pulled successfully"
else
    log_error "Failed to pull supervisor image: $SUPERVISOR_IMAGE"
    log_error "Please check your internet connection and Docker configuration"
    exit 1
fi

# 7. state.jsonのimage_tagを更新
log_info "Updating supervisor state with image tag..."
IMAGE_TAG="$SUPERVISOR_VERSION"  # バージョン文字列をそのまま使用（例: edge-v1.0.0）

# JSONファイルの更新（PLACEHOLDER → 実際のタグ）
if [ -f "$STATE_TEMPLATE" ]; then
    sed -e "s|{{IMAGE_TAG}}|$IMAGE_TAG|g" \
        -e "s|{{RAPIDPEN_CLOUD_API_KEY}}|$RAPIDPEN_API_KEY|g" \
        -e "s|{{RAPIDPEN_CLOUD_BASEURL}}|$RAPIDPEN_BASEURL|g" \
        "$STATE_TEMPLATE" > "$STATE_FILE"
    log_info "  Updated image tag: $IMAGE_TAG"
else
    log_error "Template not found: $STATE_TEMPLATE"
    exit 1
fi

# 7.5. アップグレードチェックスクリプトをインストール
log_info "Installing upgrade check script..."

UPGRADE_SCRIPT_TEMPLATE="$SCRIPT_DIR/templates/rapidpen-supervisor-check-upgrade.sh"
UPGRADE_SCRIPT_TARGET="/usr/local/bin/rapidpen-supervisor-check-upgrade.sh"

if [ -f "$UPGRADE_SCRIPT_TEMPLATE" ]; then
    # スクリプトをコピー
    cp "$UPGRADE_SCRIPT_TEMPLATE" "$UPGRADE_SCRIPT_TARGET"
    # 実行権限を設定
    chmod 755 "$UPGRADE_SCRIPT_TARGET"
    log_info "  Installed upgrade check script: $UPGRADE_SCRIPT_TARGET"
else
    log_error "Upgrade check script template not found: $UPGRADE_SCRIPT_TEMPLATE"
    exit 1
fi

# 8. systemdサービスファイルをインストール
log_info "Installing systemd service..."

# systemctlの存在確認
if ! command -v systemctl > /dev/null 2>&1; then
    log_error "systemctl is not available"
    echo ""
    echo "This installer requires systemd."
    echo "For non-systemd systems, manual installation is required."
    exit 1
fi

# サービステンプレートファイルの場所を探す
SCRIPT_DIR=$(dirname "$0")
SERVICE_TEMPLATE="$SCRIPT_DIR/templates/rapidpen-supervisor.service.template"

if [ ! -f "$SERVICE_TEMPLATE" ]; then
    log_error "Service template not found at $SERVICE_TEMPLATE"
    exit 1
fi

# jq コマンドを決定
if command -v jq > /dev/null 2>&1; then
    JQ_COMMAND="jq"
else
    JQ_COMMAND="docker run --rm -i imega/jq"
fi

# テンプレートから生成
sed -e "s|{{DOCKER_BIN}}|$DOCKER_BIN|g" \
    -e "s|{{DOCKER_SOCK}}|$DOCKER_SOCK|g" \
    -e "s|{{JQ_COMMAND}}|$JQ_COMMAND|g" \
    "$SERVICE_TEMPLATE" > /etc/systemd/system/rapidpen-supervisor.service
log_info "  Created service file at /etc/systemd/system/rapidpen-supervisor.service"
log_info "  Using Docker binary: $DOCKER_BIN"
log_info "  Using Docker socket: $DOCKER_SOCK"
log_info "  Using jq command: $JQ_COMMAND"

# systemdをリロード
systemctl daemon-reload
log_info "  Reloaded systemd daemon"

# サービスを有効化（自動起動）
systemctl enable rapidpen-supervisor
log_info "  Enabled rapidpen-supervisor service (auto-start on boot)"

# サービスを起動
systemctl start rapidpen-supervisor
log_info "  Started rapidpen-supervisor service"

# 9. Observability設定（Fluent Bit setup）
log_info "Setting up observability (Fluent Bit for log collection)..."

# 9.1 Observability設定ディレクトリ作成
OBSERVABILITY_DIR="/etc/rapidpen/edge-observability"
if [ ! -d "$OBSERVABILITY_DIR" ]; then
    mkdir -p "$OBSERVABILITY_DIR"
    chmod 700 "$OBSERVABILITY_DIR"
    log_info "  Created $OBSERVABILITY_DIR/"
else
    log_info "  $OBSERVABILITY_DIR/ already exists"
fi

# 9.2 Hub APIからObservability設定取得
log_info "Fetching observability configuration from RapidPen Hub..."

# Edge API Keyはstate.jsonから取得（既存のRAPIDPEN_CLOUD_API_KEYを流用）
EDGE_API_KEY=$(jq_exec -r '.rapidpen_cloud_api_key' "$STATE_FILE")

# Base URLからObservability APIエンドポイントを構築
# 例: https://api.rapidpen.app/api/edge/supervisor → https://api.rapidpen.app/api/edge/installer/v1/observability
OBSERVABILITY_API_URL=$(echo "$RAPIDPEN_BASEURL" | sed 's|/api/edge/supervisor|/api/edge/installer/v1/observability|')

# curlエラーをキャッチ（set -e でスクリプトが終了しないように）
OBSERVABILITY_RESPONSE=$(curl -fsSL \
    -H "X-API-Key: $EDGE_API_KEY" \
    "$OBSERVABILITY_API_URL" 2>&1) || {
    log_error "Failed to fetch observability configuration from Hub"
    log_error "  API URL: $OBSERVABILITY_API_URL"
    log_error "  Error: $(echo "$OBSERVABILITY_RESPONSE" | head -1)"
    log_error ""
    log_error "The Hub API endpoint '/api/edge/installer/v1/observability' is required."
    log_error "Please ensure the Hub is running the latest version that supports this endpoint."
    cleanup_on_error
    exit 1
}

if [ -z "$OBSERVABILITY_RESPONSE" ]; then
    # Already handled above, skip
    :
else
    # レスポンスが有効なJSONか確認
    if echo "$OBSERVABILITY_RESPONSE" | jq_exec -e . > /dev/null 2>&1; then
        # 必須フィールド確認
        LOKI_ENDPOINT=$(echo "$OBSERVABILITY_RESPONSE" | jq_exec -r '.log_endpoint // empty')

        if [ -z "$LOKI_ENDPOINT" ]; then
            log_error "Invalid observability configuration received (missing log_endpoint)"
            log_error "  Please check the Hub API configuration."
            cleanup_on_error
            exit 1
        else
            # 9.3 レスポンスJSONをそのまま保存
            echo "$OBSERVABILITY_RESPONSE" > "$OBSERVABILITY_DIR/api-config.json"
            chmod 600 "$OBSERVABILITY_DIR/api-config.json"
            log_info "  Saved observability configuration to $OBSERVABILITY_DIR/api-config.json"

            # 9.4 Fluent Bit設定ファイル生成
            LOKI_HOST=$(echo "$LOKI_ENDPOINT" | sed -E 's|https?://([^/]+).*|\1|')
            LOKI_USER_ID=$(echo "$OBSERVABILITY_RESPONSE" | jq_exec -r '.log_user_id')
            LOKI_API_TOKEN=$(echo "$OBSERVABILITY_RESPONSE" | jq_exec -r '.log_api_token')

            FLUENT_BIT_CONFIG_TEMPLATE="$SCRIPT_DIR/templates/fluent-bit.conf.template"
            if [ -f "$FLUENT_BIT_CONFIG_TEMPLATE" ]; then
                sed -e "s|{{LOKI_ENDPOINT_HOST}}|$LOKI_HOST|g" \
                    -e "s|{{LOKI_USER_ID}}|$LOKI_USER_ID|g" \
                    -e "s|{{LOKI_API_TOKEN}}|$LOKI_API_TOKEN|g" \
                    -e "s|{{SUPERVISOR_ID}}|$SUPERVISOR_ID_CANDIDATE|g" \
                    "$FLUENT_BIT_CONFIG_TEMPLATE" > "$OBSERVABILITY_DIR/fluent-bit.conf"
                chmod 644 "$OBSERVABILITY_DIR/fluent-bit.conf"
                log_info "  Created Fluent Bit configuration: $OBSERVABILITY_DIR/fluent-bit.conf"
            else
                log_error "Template not found: $FLUENT_BIT_CONFIG_TEMPLATE"
                exit 1
            fi

            # 9.5 Fluent Bit systemd サービスインストール
            FLUENT_BIT_SERVICE_TEMPLATE="$SCRIPT_DIR/templates/rapidpen-fluent-bit.service.template"
            if [ -f "$FLUENT_BIT_SERVICE_TEMPLATE" ]; then
                sed -e "s|{{DOCKER_BIN}}|$DOCKER_BIN|g" \
                    "$FLUENT_BIT_SERVICE_TEMPLATE" > /etc/systemd/system/rapidpen-fluent-bit.service
                log_info "  Created service file at /etc/systemd/system/rapidpen-fluent-bit.service"

                # systemdをリロード
                systemctl daemon-reload
                log_info "  Reloaded systemd daemon"

                # サービスを有効化（自動起動）
                systemctl enable rapidpen-fluent-bit
                log_info "  Enabled rapidpen-fluent-bit service (auto-start on boot)"

                # Fluent Bitイメージをpull
                log_info "Pulling Fluent Bit image..."
                if docker pull fluent/fluent-bit:latest > /dev/null 2>&1; then
                    log_info "  ✓ Fluent Bit image pulled successfully"
                else
                    log_warn "Failed to pull Fluent Bit image"
                    log_warn "  Service will attempt to pull on first start"
                fi

                # サービスを起動
                systemctl start rapidpen-fluent-bit
                log_info "  Started rapidpen-fluent-bit service"
                log_info "  ✓ Observability setup completed"
            else
                log_error "Template not found: $FLUENT_BIT_SERVICE_TEMPLATE"
                exit 1
            fi
        fi
    else
        log_error "Received invalid JSON response from Hub API"
        log_error "  Please check the Hub API configuration."
        cleanup_on_error
        exit 1
    fi
fi

# 10. ログクリーンアップ（日次ローテーション + 7日保持）
log_info "Installing log cleanup timer..."

LOG_CLEANUP_SCRIPT_TEMPLATE="$SCRIPT_DIR/templates/rapidpen-log-cleanup.sh"
LOG_CLEANUP_SERVICE_TEMPLATE="$SCRIPT_DIR/templates/rapidpen-log-cleanup.service.template"
LOG_CLEANUP_TIMER_TEMPLATE="$SCRIPT_DIR/templates/rapidpen-log-cleanup.timer.template"
LOG_CLEANUP_SCRIPT_TARGET="/usr/local/bin/rapidpen-log-cleanup.sh"

if [ -f "$LOG_CLEANUP_SCRIPT_TEMPLATE" ] && [ -f "$LOG_CLEANUP_SERVICE_TEMPLATE" ] && [ -f "$LOG_CLEANUP_TIMER_TEMPLATE" ]; then
    # Install cleanup script
    cp "$LOG_CLEANUP_SCRIPT_TEMPLATE" "$LOG_CLEANUP_SCRIPT_TARGET"
    chmod 755 "$LOG_CLEANUP_SCRIPT_TARGET"
    log_info "  Installed cleanup script: $LOG_CLEANUP_SCRIPT_TARGET"

    # Install systemd service (no template variables to substitute)
    cp "$LOG_CLEANUP_SERVICE_TEMPLATE" /etc/systemd/system/rapidpen-log-cleanup.service
    log_info "  Created service file at /etc/systemd/system/rapidpen-log-cleanup.service"

    # Install systemd timer (no template variables to substitute)
    cp "$LOG_CLEANUP_TIMER_TEMPLATE" /etc/systemd/system/rapidpen-log-cleanup.timer
    log_info "  Created timer file at /etc/systemd/system/rapidpen-log-cleanup.timer"

    # Reload systemd and enable timer
    systemctl daemon-reload
    systemctl enable --now rapidpen-log-cleanup.timer
    log_info "  Enabled and started rapidpen-log-cleanup.timer (daily)"
    log_info "  ✓ Log cleanup setup completed"
else
    log_warn "Log cleanup templates not found (skipping)"
    log_warn "  Expected: $LOG_CLEANUP_SCRIPT_TEMPLATE"
    log_warn "  Expected: $LOG_CLEANUP_SERVICE_TEMPLATE"
    log_warn "  Expected: $LOG_CLEANUP_TIMER_TEMPLATE"
fi

# 11. アンインストーラーをシステムに配置
log_info "Installing uninstall command..."

UNINSTALL_SCRIPT="$SCRIPT_DIR/uninstall.sh"
UNINSTALL_TARGET="/usr/bin/rapidpen-uninstall"

if [ -f "$UNINSTALL_SCRIPT" ]; then
    # アンインストーラーをコピー
    cp "$UNINSTALL_SCRIPT" "$UNINSTALL_TARGET"
    # 実行権限を設定
    chmod 755 "$UNINSTALL_TARGET"
    log_info "  Installed uninstall command: rapidpen-uninstall"
else
    log_warn "Uninstall script not found at $UNINSTALL_SCRIPT"
    log_warn "Skipping uninstall command installation"
fi

# 12. 完了メッセージ
echo ""
echo "==========================================="
log_info "Installation completed successfully!"
echo "==========================================="
echo ""
echo "Services are now running!"
echo ""
echo "Useful commands:"
echo "  Supervisor:"
echo "    Check status: sudo systemctl status rapidpen-supervisor"
echo "    View logs:    sudo journalctl -u rapidpen-supervisor -f"
echo "    Stop:         sudo systemctl stop rapidpen-supervisor"
echo "    Restart:      sudo systemctl restart rapidpen-supervisor"
echo ""
echo "  Fluent Bit (Log Collection):"
echo "    Check status: sudo systemctl status rapidpen-fluent-bit"
echo "    View logs:    sudo journalctl -u rapidpen-fluent-bit -f"
echo "    Stop:         sudo systemctl stop rapidpen-fluent-bit"
echo "    Restart:      sudo systemctl restart rapidpen-fluent-bit"
echo ""
echo "  Log Cleanup (daily timer):"
echo "    Check timer:  sudo systemctl list-timers rapidpen-log-cleanup.timer"
echo "    Run manually: sudo systemctl start rapidpen-log-cleanup.service"
echo "    View logs:    sudo journalctl -u rapidpen-log-cleanup.service"
echo ""
echo "  Uninstall:    sudo rapidpen-uninstall"