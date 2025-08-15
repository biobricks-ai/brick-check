#!/usr/bin/env bash
set -e

# GCloud VM Deployment Script for Brick Check Pipeline
# This script sets up and runs the containerized pipeline on a GCloud Compute VM

echo "🚀 Starting GCloud VM deployment for Brick Check Pipeline..."

# Configuration
PROJECT_DIR="/opt/brick-check"
LOG_DIR="/var/log/brick-check"
SERVICE_NAME="brick-check"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        log_error "This script should not be run as root for security reasons."
        log_info "Please run as a regular user with sudo privileges."
        exit 1
    fi
}

# Function to install dependencies
install_dependencies() {
    log_info "Installing system dependencies..."
    
    # Update system
    sudo apt-get update
    
    # Install Docker if not present
    if ! command -v docker &> /dev/null; then
        log_info "Installing Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        sudo usermod -aG docker $USER
        rm get-docker.sh
    else
        log_success "Docker already installed"
    fi
    
    # Install Docker Compose if not present
    if ! command -v docker-compose &> /dev/null; then
        log_info "Installing Docker Compose..."
        sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
    else
        log_success "Docker Compose already installed"
    fi
    
    # Install additional monitoring tools
    sudo apt-get install -y htop iotop nethogs jq curl wget git
    
    log_success "Dependencies installed successfully"
}

# Function to setup project directory
setup_project() {
    log_info "Setting up project directory..."
    
    # Create project directory if it doesn't exist
    if [ ! -d "$PROJECT_DIR" ]; then
        sudo mkdir -p "$PROJECT_DIR"
        sudo chown -R $USER:$USER "$PROJECT_DIR"
    fi
    
    # Create log directories
    sudo mkdir -p "$LOG_DIR"/{aggregated,fluentd}
    sudo chown -R $USER:$USER "$LOG_DIR"
    
    # Copy project files to deployment directory
    if [ "$PWD" != "$PROJECT_DIR" ]; then
        log_info "Copying project files to $PROJECT_DIR..."
        rsync -av --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' . "$PROJECT_DIR/"
    fi
    
    cd "$PROJECT_DIR"
    log_success "Project setup complete"
}

# Function to setup environment
setup_environment() {
    log_info "Setting up environment configuration..."
    
    # Check if .env file exists
    if [ ! -f ".env" ]; then
        log_warning ".env file not found. Creating template..."
        cat > .env << EOF
# GitHub Personal Access Token (required for GitHub CLI API access)
GITHUB_TOKEN=your_github_token_here

# Optional: DVC remote configuration
# DVC_REMOTE_URL=s3://your-bucket/path

# Optional: Slack webhook for notifications
# SLACK_WEBHOOK_URL=https://hooks.slack.com/your/webhook/url
EOF
        log_error "Please edit .env file with your GitHub token and other configuration"
        log_info "Edit: $PROJECT_DIR/.env"
        exit 1
    fi
    
    # Source environment variables
    set -a
    source .env
    set +a
    
    # Validate required environment variables
    if [ -z "$GITHUB_TOKEN" ] || [ "$GITHUB_TOKEN" = "your_github_token_here" ]; then
        log_error "GITHUB_TOKEN is not properly configured in .env file"
        exit 1
    fi
    
    log_success "Environment configuration validated"
}

# Function to setup logging
setup_logging() {
    log_info "Setting up logging infrastructure..."
    
    # Create log rotation configuration
    sudo tee /etc/logrotate.d/brick-check > /dev/null << EOF
$LOG_DIR/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 644 $USER $USER
    postrotate
        /usr/bin/systemctl reload rsyslog > /dev/null 2>&1 || true
    endscript
}
EOF
    
    # Configure rsyslog for brick-check
    sudo tee /etc/rsyslog.d/30-brick-check.conf > /dev/null << EOF
# Brick Check Pipeline Logging
local0.*    $LOG_DIR/syslog.log
& stop
EOF
    
    sudo systemctl restart rsyslog
    
    log_success "Logging infrastructure configured"
}

# Function to create systemd service
create_systemd_service() {
    log_info "Creating systemd service for automatic startup..."
    
    sudo tee /etc/systemd/system/${SERVICE_NAME}.service > /dev/null << EOF
[Unit]
Description=Brick Check Pipeline
Requires=docker.service
After=docker.service
StartLimitBurst=3
StartLimitInterval=60s

[Service]
Type=oneshot
RemainAfterExit=no
WorkingDirectory=$PROJECT_DIR
Environment=COMPOSE_PROJECT_NAME=brick-check
ExecStartPre=/usr/local/bin/docker-compose down --remove-orphans
ExecStart=/usr/local/bin/docker-compose up --build brick-check
ExecStop=/usr/local/bin/docker-compose down
TimeoutStartSec=0
Restart=on-failure
RestartSec=30
User=$USER
Group=docker

[Install]
WantedBy=multi-user.target
EOF

    # Create timer for scheduled runs
    sudo tee /etc/systemd/system/${SERVICE_NAME}.timer > /dev/null << EOF
[Unit]
Description=Run Brick Check Pipeline daily
Requires=${SERVICE_NAME}.service

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF
    
    sudo systemctl daemon-reload
    sudo systemctl enable ${SERVICE_NAME}.timer
    
    log_success "Systemd service and timer created"
}

# Function to setup monitoring
setup_monitoring() {
    log_info "Setting up monitoring and alerting..."
    
    # Create monitoring script
    tee "$PROJECT_DIR/monitor.sh" > /dev/null << 'EOF'
#!/bin/bash
# Monitoring script for Brick Check Pipeline

LOG_DIR="/var/log/brick-check"
PROJECT_DIR="/opt/brick-check"

# Check Docker containers
check_containers() {
    echo "=== Container Status ==="
    docker ps -a --filter "name=brick-check"
    echo ""
}

# Check disk usage
check_disk() {
    echo "=== Disk Usage ==="
    df -h "$PROJECT_DIR" "$LOG_DIR"
    echo ""
}

# Check recent logs
check_logs() {
    echo "=== Recent Pipeline Activity ==="
    if [ -f "$LOG_DIR/pipeline_"*.log ]; then
        tail -20 "$LOG_DIR"/pipeline_*.log | tail -20
    else
        echo "No pipeline logs found"
    fi
    echo ""
}

# Check for errors
check_errors() {
    echo "=== Recent Errors ==="
    if [ -f "$LOG_DIR/errors.log" ]; then
        tail -10 "$LOG_DIR/errors.log"
    else
        echo "No errors logged"
    fi
    echo ""
}

# Main monitoring function
main() {
    echo "Brick Check Pipeline Monitoring Report - $(date)"
    echo "================================================"
    check_containers
    check_disk
    check_logs
    check_errors
}

main "$@"
EOF
    
    chmod +x "$PROJECT_DIR/monitor.sh"
    
    # Add monitoring cron job
    (crontab -l 2>/dev/null; echo "*/15 * * * * $PROJECT_DIR/monitor.sh >> $LOG_DIR/monitoring.log 2>&1") | crontab -
    
    log_success "Monitoring setup complete"
}

# Function to start logging services
start_logging_services() {
    log_info "Starting logging services..."
    
    # Start Fluentd for log aggregation
    docker-compose up -d fluentd
    
    # Wait for Fluentd to be ready
    sleep 10
    
    if docker ps | grep -q brick-check-fluentd; then
        log_success "Fluentd logging service started"
    else
        log_warning "Fluentd service may not have started properly"
    fi
}

# Function to build and start the pipeline
start_pipeline() {
    log_info "Building and starting the pipeline..."
    
    # Build the Docker images
    docker-compose build --no-cache
    
    # Start the logging infrastructure first
    start_logging_services
    
    # Run the pipeline
    log_info "Running the Brick Check Pipeline..."
    docker-compose up brick-check
    
    log_success "Pipeline execution completed"
}

# Function to show deployment status
show_status() {
    log_info "Deployment Status:"
    echo ""
    echo "Project Directory: $PROJECT_DIR"
    echo "Log Directory: $LOG_DIR"
    echo "Service Name: $SERVICE_NAME"
    echo ""
    
    log_info "Docker Status:"
    docker ps -a --filter "name=brick-check"
    echo ""
    
    log_info "Service Status:"
    sudo systemctl status ${SERVICE_NAME}.service --no-pager -l || true
    sudo systemctl status ${SERVICE_NAME}.timer --no-pager -l || true
    echo ""
    
    log_info "Recent Logs:"
    if [ -f "$LOG_DIR/pipeline_"*.log ]; then
        echo "Latest pipeline log:"
        ls -la "$LOG_DIR"/pipeline_*.log | tail -1
        echo ""
        echo "Last 10 lines:"
        tail -10 "$LOG_DIR"/pipeline_*.log | tail -10
    fi
}

# Function to cleanup
cleanup() {
    log_info "Cleaning up..."
    docker-compose down --remove-orphans
    docker system prune -f
    log_success "Cleanup completed"
}

# Function to setup Google Cloud logging
setup_gcloud_logging() {
    log_info "Setting up Google Cloud Logging integration..."
    
    # Check if we're running on a GCP VM
    if curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/project/project-id &>/dev/null; then
        log_success "Running on Google Cloud VM - metadata service available"
        
        # Get project ID from metadata if not set
        if [ -z "$GOOGLE_CLOUD_PROJECT" ]; then
            GOOGLE_CLOUD_PROJECT=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/project/project-id)
            log_info "Auto-detected project ID: $GOOGLE_CLOUD_PROJECT"
            
            # Add to .env file
            echo "GOOGLE_CLOUD_PROJECT=$GOOGLE_CLOUD_PROJECT" >> .env
        fi
        
        # Get instance name
        INSTANCE_NAME=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/name)
        ZONE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone | cut -d'/' -f4)
        
        log_info "Instance: $INSTANCE_NAME in zone $ZONE"
        
    else
        log_warning "Not running on Google Cloud VM - Cloud Logging may not work"
        if [ -z "$GOOGLE_CLOUD_PROJECT" ]; then
            log_error "GOOGLE_CLOUD_PROJECT not set and not on GCP VM"
            log_info "Please set GOOGLE_CLOUD_PROJECT in .env file"
        fi
    fi
    
    # Install Google Cloud Logging agent
    if ! command -v google-fluentd &> /dev/null; then
        log_info "Installing Google Cloud Logging agent..."
        
        # Fix for Ubuntu 24.10 and newer - use the official installation method
        log_info "Adding Google Cloud repository and installing Ops Agent..."
        
        # Install required packages
        sudo apt-get update
        sudo apt-get install -y apt-transport-https ca-certificates gnupg lsb-release
        
        # Add Google Cloud public key
        curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /etc/apt/keyrings/cloud.google.gpg
        
        # Add Google Cloud repository for the correct Ubuntu version
        UBUNTU_CODENAME=$(lsb_release -cs)
        if [[ "$UBUNTU_CODENAME" == "plucky" ]]; then
            # Use jammy (22.04) repository for plucky (24.10) compatibility
            UBUNTU_CODENAME="jammy"
            log_info "Using jammy repository for Ubuntu 24.10 compatibility"
        fi
        
        echo "deb [signed-by=/etc/apt/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt google-cloud-ops-agent-${UBUNTU_CODENAME}-all main" | sudo tee /etc/apt/sources.list.d/google-cloud-ops-agent.list
        
        # Update and install
        sudo apt-get update
        sudo apt-get install -y google-cloud-ops-agent
        
        log_success "Google Cloud Ops Agent installed"
    else
        log_success "Google Cloud Logging agent already installed"
    fi
    
    # Configure the logging agent
    sudo tee /etc/google-cloud-ops-agent/config.yaml > /dev/null << EOF
logging:
  receivers:
    brick_check_files:
      type: files
      include_paths:
        - $LOG_DIR/pipeline_*.log
        - $LOG_DIR/errors.log
        - $LOG_DIR/stages.log
      exclude_paths: []
    brick_check_syslog:
      type: syslog
  processors:
    brick_check_parser:
      type: parse_regex
      field: message
      regex: '^(?P<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) (?P<level>\w+): (?P<msg>.*)'
      time_key: timestamp
      time_format: '%Y-%m-%d %H:%M:%S'
  service:
    pipelines:
      brick_check_pipeline:
        receivers: [brick_check_files]
        processors: [brick_check_parser]
      brick_check_syslog_pipeline:
        receivers: [brick_check_syslog]

metrics:
  receivers:
    hostmetrics:
      type: hostmetrics
      collection_interval: 60s
  service:
    pipelines:
      default_pipeline:
        receivers: [hostmetrics]
EOF
    
    # Restart the logging agent
    sudo systemctl restart google-cloud-ops-agent
    sudo systemctl enable google-cloud-ops-agent
    
    log_success "Google Cloud Logging configuration completed"
    log_info "Logs will appear in Cloud Logging under 'brick-check' labels"
}

# Function to verify Google Cloud integration
verify_gcloud_integration() {
    log_info "Verifying Google Cloud integration..."
    
    # Check if ops agent is running
    if sudo systemctl is-active --quiet google-cloud-ops-agent; then
        log_success "Google Cloud Ops Agent is running"
    else
        log_warning "Google Cloud Ops Agent is not running"
        sudo systemctl status google-cloud-ops-agent --no-pager -l
    fi
    
    # Test Cloud Logging connectivity
    if command -v gcloud &> /dev/null; then
        log_info "Testing Cloud Logging connectivity..."
        if gcloud logging write brick-check-test "Deployment test from $(hostname) at $(date)" --severity=INFO; then
            log_success "Successfully sent test log to Cloud Logging"
        else
            log_warning "Failed to send test log to Cloud Logging"
        fi
    else
        log_info "gcloud CLI not installed - skipping connectivity test"
    fi
    
    log_info "Google Cloud Console URLs:"
    echo "  • Logs: https://console.cloud.google.com/logs/query?project=$GOOGLE_CLOUD_PROJECT"
    echo "  • Monitoring: https://console.cloud.google.com/monitoring?project=$GOOGLE_CLOUD_PROJECT"
    echo "  • VM Instance: https://console.cloud.google.com/compute/instances?project=$GOOGLE_CLOUD_PROJECT"
}

# Main execution
main() {
    case "${1:-deploy}" in
        "deploy")
            check_root
            install_dependencies
            setup_project
            setup_environment
            setup_logging
            setup_gcloud_logging
            create_systemd_service
            setup_monitoring
            start_pipeline
            verify_gcloud_integration
            show_status
            ;;
        "start")
            cd "$PROJECT_DIR"
            setup_environment
            start_pipeline
            ;;
        "stop")
            cd "$PROJECT_DIR"
            docker-compose down
            ;;
        "status")
            show_status
            ;;
        "monitor")
            "$PROJECT_DIR/monitor.sh"
            ;;
        "logs")
            cd "$PROJECT_DIR"
            docker-compose logs -f
            ;;
        "cleanup")
            cd "$PROJECT_DIR"
            cleanup
            ;;
        "help"|"-h"|"--help")
            echo "Usage: $0 {deploy|start|stop|status|monitor|logs|cleanup|help}"
            echo ""
            echo "Commands:"
            echo "  deploy  - Full deployment setup (default)"
            echo "  start   - Start the pipeline"
            echo "  stop    - Stop the pipeline"
            echo "  status  - Show deployment status"
            echo "  monitor - Run monitoring checks"
            echo "  logs    - Show live logs"
            echo "  cleanup - Clean up Docker resources"
            echo "  help    - Show this help"
            ;;
        *)
            log_error "Unknown command: $1"
            echo "Use '$0 help' for usage information"
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@" 