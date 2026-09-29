# Use Debian slim as lightweight Linux base
# Note: We only install Docker CLI to use host's Docker daemon via mounted socket
FROM debian:trixie-slim

# Fail fast inside RUN pipelines (curl | sh, | tee, …)
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Parameterize tool versions for easier updates
# Pin releases for reproducible builds; override with --build-arg.
# CLAUDE_CODE_VERSION pins the CLI release (update with --build-arg
# CLAUDE_BUILD_TIME to bust the installer cache; see `update`). Avoid `latest`
# in production builds: a moving tag breaks reproducibility and widens
# supply-chain exposure if a tag is ever mutated.
# See: https://code.claude.com/docs/en/setup#install-a-specific-version
ARG NVM_VERSION=v0.40.8
# Claude Code CLI release; override with --build-arg CLAUDE_CODE_VERSION=x.y.z
ARG CLAUDE_CODE_VERSION=2.1.284

# Install base dependencies and useful CLI tools for coding agents
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    bash \
    ca-certificates \
    zip \
    unzip \
    wget \
    gnupg \
    lsb-release \
    apt-transport-https \
    ripgrep \
    fd-find \
    jq \
    tree \
    less \
    procps \
    openssh-client \
    python3 \
    python3-venv \
    socat \
    && rm -rf /var/lib/apt/lists/*

# Install Docker CLI only (uses host Docker daemon via mounted socket)
# We don't need docker-ce (daemon) or containerd.io since we use the host's Docker
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && \
    apt-get install -y docker-ce-cli docker-buildx-plugin docker-compose-plugin && \
    rm -rf /var/lib/apt/lists/*

# Create non-root user
# Note: Docker socket group membership is granted at run time by the wrapper
# (config-lib.sh) with `--group-add <socket GID>`; the entrypoint never runs as
# root and does not edit /etc/group.
# There is intentionally no sudo: the agent must never gain root, so neither a
# sudoers entry nor the sudo binary (a setuid-root vector) is installed.
RUN useradd -m -s /bin/bash -u 1000 coder

# System-wide git identity for the agent runner (official Claude runner recipe).
# Per-project identity still comes from the mounted ~/.gitconfig or repo config.
RUN git config --system user.name "Claude" \
    && git config --system user.email "noreply@anthropic.com" \
    && git config --system --add safe.directory '*'

# Install NVM and Node.js LTS as coder user
USER coder
WORKDIR /home/coder
ENV NVM_DIR="/home/coder/.nvm"
RUN curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash && \
    bash -c "source $NVM_DIR/nvm.sh && \
    nvm install --lts && \
    nvm alias default node && \
    nvm use default && \
    ln -sf \$(dirname \$(which node)) $NVM_DIR/default"

# Install uv (Python package manager) as coder user
# See: https://docs.astral.sh/uv/getting-started/installation/
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# Add nvm, node, uv, ~/.composio and ~/.local/bin to PATH
# Node.js is available via the NVM default symlink created above.
# ~/.local/bin holds user-installed CLIs (uv tools, LSP servers, formatters).
# ~/.composio holds the Composio CLI and its login, mounted read-write from the
# host via mount.composio in the wrapper config, so `composio` resolves on PATH.
# NOTE: No npm/pnpm global install is used for Claude Code itself (no official
# npm support); the native installer below is the only supported path.
ENV PATH="$NVM_DIR/default:/home/coder/.composio:/home/coder/.local/bin:$PATH"

# Install Claude Code natively with a pinned version (official installer).
# See: https://code.claude.com/docs/en/setup#install-a-specific-version
# The channel/version chosen at install time becomes the auto-update default,
# but auto-updates are disabled at runtime via env.DISABLE_AUTOUPDATER=1 in the
# managed settings.json (see config-lib.sh).
# ARG CLAUDE_BUILD_TIME is only passed during 'update' to bust cache
# ARG CLAUDE_CODE_VERSION pins the release; defaults to 2.1.284 for regular builds
ARG CLAUDE_BUILD_TIME=0
RUN curl -fsSL https://claude.ai/install.sh | bash -s "${CLAUDE_CODE_VERSION}" && claude --version

# Create the writable home tree, owned by coder and group-writable (g+rwX) so
# the wrapper can grant any host UID access with `--group-add coder` (a name
# resolved against the container's /etc/group, hence gid 1000). Runs as coder:
# it owns the tree, so no root step is needed and the image stays non-root.
# NOTE: LSP servers and formatters are NOT baked in here; they live in
# CCODE_HOME/home/.local/bin on the host (see lib/config-lib.sh
# ensure_lsp_formatters) so they persist across rebuilds and stay out of the
# host XDG dirs.
RUN mkdir -p /home/coder/.claude/hooks-guard && \
    mkdir -p /home/coder/.claude/plugins && \
    mkdir -p /home/coder/.claude/skills && \
    mkdir -p /home/coder/.claude/agents && \
    mkdir -p /home/coder/.claude/commands && \
    mkdir -p /home/coder/.local/bin && \
    mkdir -p /home/coder/.local/share/claude && \
    mkdir -p /home/coder/.local/state/claude && \
    mkdir -p /home/coder/.cache/claude && \
    mkdir -p /home/coder/.npm && \
    chown -R coder:coder /home/coder && \
    chmod -R g+rwX /home/coder

# Default working directory; entrypoint.sh cd's into the project (CLAUDE_DOCKERIZED_WORKDIR,
# falling back to the Docker --workdir set by the wrapper).
WORKDIR /

# Copy entrypoint script. COPY is not subject to USER (files are created
# root-owned) and preserves the source mode, and entrypoint.sh is committed as
# 0755, so no root step and no chmod are required. The script stays root-owned
# in root-owned /usr/local/bin, so the runtime user cannot modify it.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# entrypoint.sh performs no privilege changes.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# Default command is to run claude
CMD ["claude"]
