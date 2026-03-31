FROM node:22-slim

# System deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Google Workspace CLI (pinned to match host), Claude Code CLI, and tsx
RUN npm install -g @anthropic-ai/claude-code @googleworkspace/cli tsx

# Create job user (non-root)
RUN useradd -m -s /bin/bash jobuser

# Create directory structure
RUN mkdir -p /workspace/quarantine/{context,memory/people,memory/projects,state} \
    /workspace/scripts \
    /workspace/.claude/skills \
    /config \
    /secrets \
    && chown -R jobuser:jobuser /workspace /config /secrets

# Install slack_pull.ts local deps (dotenv, "type":"module" for ESM)
COPY --chown=jobuser:jobuser scripts-package.json /workspace/scripts/package.json
RUN cd /workspace/scripts && npm install --omit=dev 2>/dev/null

# Copy shared Claude settings (locked to quarantine writes only)
COPY settings.json /workspace/.claude/settings.json

# Copy the guard hook
COPY guard-secrets-ingest.sh /workspace/.claude/scripts/guard-secrets-ingest.sh
RUN chmod +x /workspace/.claude/scripts/guard-secrets-ingest.sh

USER jobuser
WORKDIR /workspace

# No ENTRYPOINT — run-job.sh passes the entrypoint via docker compose command
