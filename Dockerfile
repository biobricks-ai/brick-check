FROM python:3.13-slim

# Set environment variables
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV UV_SYSTEM_PYTHON=1

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    curl \
    wget \
    parallel \
    build-essential \
    rsyslog \
    logrotate \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN (type -p wget >/dev/null || (apt update && apt install wget -y)) \
        && mkdir -p -m 755 /etc/apt/keyrings \
        && out=$(mktemp) && wget -nv -O$out https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        && cat $out | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
        && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
        && mkdir -p -m 755 /etc/apt/sources.list.d \
        && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
        && apt update \
        && apt install gh -y

# Install uv
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:$PATH"

# Install pipx and biobricks
RUN python -m pip install --user pipx \
    && python -m pipx ensurepath \
    && /root/.local/bin/pipx install biobricks
ENV PATH="/root/.local/bin:$PATH"

# Set working directory
WORKDIR /app

# Copy dependency files
COPY pyproject.toml uv.lock ./

# Install Python dependencies
RUN uv sync --frozen

# Copy project files
COPY . .

# Create necessary directories
RUN mkdir -p list info fail logs

# Set up git config (required for DVC)
RUN git config --global user.name "Docker User" \
    && git config --global user.email "docker@example.com"

# Create logging configuration
RUN echo '#!/bin/bash\n\
set -e\n\
\n\
# Create timestamp for this run\n\
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")\n\
LOG_DIR="/app/logs"\n\
\n\
# Ensure log directory exists\n\
mkdir -p "$LOG_DIR"\n\
\n\
# Function to log with timestamp\n\
log_with_timestamp() {\n\
    while IFS= read -r line; do\n\
        echo "$(date "+%Y-%m-%d %H:%M:%S") $line" | tee -a "$LOG_DIR/pipeline_${TIMESTAMP}.log"\n\
    done\n\
}\n\
\n\
# Function to log errors\n\
log_error() {\n\
    echo "$(date "+%Y-%m-%d %H:%M:%S") ERROR: $1" | tee -a "$LOG_DIR/pipeline_${TIMESTAMP}.log" "$LOG_DIR/errors.log"\n\
}\n\
\n\
# Function to log stage completion\n\
log_stage() {\n\
    echo "$(date "+%Y-%m-%d %H:%M:%S") STAGE: $1" | tee -a "$LOG_DIR/pipeline_${TIMESTAMP}.log" "$LOG_DIR/stages.log"\n\
}\n\
\n\
echo "Starting Brick Check Pipeline at $(date)" | log_with_timestamp\n\
echo "Logging to: $LOG_DIR/pipeline_${TIMESTAMP}.log" | log_with_timestamp\n\
\n\
# Execute the command with logging\n\
exec "$@" 2>&1 | log_with_timestamp\n\
' > /app/entrypoint-with-logging.sh \
    && chmod +x /app/entrypoint-with-logging.sh

# Default command with logging wrapper
ENTRYPOINT ["/app/entrypoint-with-logging.sh"]
CMD ["uv", "run", "dvc", "repro"] 