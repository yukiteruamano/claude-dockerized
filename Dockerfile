# Use Debian slim as lightweight Linux base
# Note: We only install Docker CLI to use host's Docker daemon via mounted socket
# Pinned by digest (T-24): a tag can be re-pointed, a digest cannot. Dependabot
# (docker ecosystem) proposes digest bumps; `build --pull` never floats past it.
FROM debian:trixie-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4

# Fail fast inside RUN pipelines (curl | sh, | tee, …)
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Parameterize tool versions for easier updates
# Pin releases for reproducible builds; override with --build-arg. Avoid
# `latest` in production builds: a moving tag breaks reproducibility and
# widens supply-chain exposure if a tag is ever mutated (T-24).
# NVM is fetched by commit (NVM_COMMIT is the commit behind tag NVM_VERSION).
ARG NVM_VERSION=v0.40.8
ARG NVM_COMMIT=a885b885fef16fac4bc544188fb25e9e37ae83e8
# Node.js LTS line pinned to an exact release (was: whatever --lts resolved).
ARG NODE_VERSION=24.22.2
# uv pinned to an exact release, installed from its GitHub release tarball and
# checked against these sha256 (the published uv-<target>.tar.gz.sha256).
ARG UV_VERSION=0.13.7
ARG UV_SHA256_X86_64=c5221ff41b7892bfc223543883600125f6a47fe845093e0f5bdff4f359196d83
ARG UV_SHA256_AARCH64=71279f8d3c67241e807b9d8db872d1bf541579fb9f08b7d1eb1682196d1e57dc
# pnpm pinned to an exact release (project package manager, not the agent).
ARG PNPM_VERSION=12.16.1
# Fingerprint of Docker's apt signing key (docs.docker.com/engine/install/debian).
ARG DOCKER_APT_KEY_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88

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
# DOCKER_CLI=0 (setting.image_docker_cli=false) leaves it out entirely: it is
# only useful with the opt-in socket mount (setting.docker_socket).
ARG DOCKER_CLI=1
RUN if [ "$DOCKER_CLI" != 1 ]; then echo "Docker CLI skipped (DOCKER_CLI=$DOCKER_CLI)"; exit 0; fi && \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
    gpg --show-keys --with-colons /etc/apt/keyrings/docker.asc | awk -F: '$1=="fpr"{print $10}' | grep -qx "$DOCKER_APT_KEY_FPR" && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && \
    apt-get install -y docker-ce-cli docker-buildx-plugin docker-compose-plugin && \
    rm -rf /var/lib/apt/lists/*

# Create non-root user
# Note: Docker socket group membership is granted at run time by the wrapper
# (lib/mounts-lib.sh) with `--group-add <socket GID>`; the entrypoint never runs as
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
RUN curl -fsSL -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_COMMIT}/install.sh" | bash && \
    bash -c "source $NVM_DIR/nvm.sh && \
    nvm install ${NODE_VERSION} && \
    nvm alias default node && \
    nvm use default && \
    ln -sf \$(dirname \$(which node)) $NVM_DIR/default"

# Install pnpm (pinned) into the NVM Node as coder user. The version is asserted
# so a moved registry tag cannot slip a different release in.
RUN bash -c "source $NVM_DIR/nvm.sh && \
    npm install -g pnpm@${PNPM_VERSION} && \
    pnpm --version | grep -qx '${PNPM_VERSION}'"

# Install uv (Python package manager) as coder user from the release tarball:
# no piped installer script, and the archive must match the pinned sha256.
# See: https://docs.astral.sh/uv/getting-started/installation/#github-releases
RUN case "$(uname -m)" in \
        x86_64) uv_target=x86_64-unknown-linux-gnu uv_sha="${UV_SHA256_X86_64}" ;; \
        aarch64) uv_target=aarch64-unknown-linux-gnu uv_sha="${UV_SHA256_AARCH64}" ;; \
        *) echo "No pinned uv sha256 for $(uname -m)" >&2; exit 1 ;; \
    esac && \
    curl -fsSL -o /tmp/uv.tar.gz "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${uv_target}.tar.gz" && \
    echo "${uv_sha}  /tmp/uv.tar.gz" | sha256sum -c - && \
    mkdir -p /home/coder/.local/bin && \
    tar -xzf /tmp/uv.tar.gz -C /home/coder/.local/bin --strip-components=1 "uv-${uv_target}/uv" "uv-${uv_target}/uvx" && \
    rm -f /tmp/uv.tar.gz && \
    /home/coder/.local/bin/uv --version | grep -q "^uv ${UV_VERSION}"

# Add nvm, node and ~/.local/bin to PATH
# Node.js is available via the NVM default symlink created above.
# ~/.local/bin holds user-installed CLIs (LSP servers, formatters from the
# generated home, mounted read-write at runtime).
# /usr/local/bin holds the image-provided CLIs (see below); it is explicit here
# so resolution never depends on the inherited base-image PATH.
# NOTE: pnpm is a project tool; Claude Code itself is never installed through
# npm/pnpm (no official npm support): the native installer below is the only
# supported path.
ENV PATH="$NVM_DIR/default:/usr/local/bin:/home/coder/.local/bin:$PATH"

# Install Claude Code natively with a pinned version (official installer).
# See: https://code.claude.com/docs/en/setup#install-a-specific-version
# The channel/version chosen at install time becomes the auto-update default,
# but auto-updates are disabled at runtime via env.DISABLE_AUTOUPDATER=1 in the
# managed settings.json (see lib/layer-lib.sh).
# ARG CLAUDE_BUILD_TIME is only passed during 'update' to bust cache.
# ARG CLAUDE_CODE_VERSION pins the release (declared here, not at the top, so
# changing it only rebuilds from this layer on). The installed binary must
# report exactly that version, and, when the wrapper recorded its sha256 on an
# earlier build of the same version (CLAUDE_CODE_SHA256, trust on first use),
# the same bytes.
# The installer script itself is not pinned (it changes between releases);
# what it installs is: for the default release the binary must match the
# checksums of its manifest (downloads.claude.ai/claude-code-releases/
# <version>/manifest.json, platforms linux-x64 / linux-arm64), so the default
# build does not rely on first use. Bump them together with the version.
# See: https://code.claude.com/docs/en/setup#install-a-specific-version
ARG CLAUDE_CODE_VERSION=2.1.311
ARG CLAUDE_CODE_MANIFEST_VERSION=2.1.311
ARG CLAUDE_CODE_MANIFEST_SHA256_X64=86dc1fcc69498159eaf15f446613e847010f9036bfbbdffd4c49350be8489ada
ARG CLAUDE_CODE_MANIFEST_SHA256_ARM64=2e2496c9a8065df93acb0fca2d341f59a6b8777649b2e025ab8c9bcd5eef61f3
ARG CLAUDE_CODE_SHA256=
ARG CLAUDE_BUILD_TIME=0
RUN curl -fsSL https://claude.ai/install.sh | bash -s "${CLAUDE_CODE_VERSION}" && \
    claude --version | grep -q "^${CLAUDE_CODE_VERSION} " && \
    claude_bin="$(readlink -f "$(command -v claude)")" && \
    if [ "${CLAUDE_CODE_VERSION}" = "${CLAUDE_CODE_MANIFEST_VERSION}" ]; then \
        case "$(uname -m)" in \
            x86_64) manifest_sha="${CLAUDE_CODE_MANIFEST_SHA256_X64}" ;; \
            aarch64) manifest_sha="${CLAUDE_CODE_MANIFEST_SHA256_ARM64}" ;; \
            *) manifest_sha="" ;; \
        esac; \
        [ -z "${manifest_sha}" ] || echo "${manifest_sha}  ${claude_bin}" | sha256sum -c -; \
    fi && \
    if [ -n "${CLAUDE_CODE_SHA256}" ]; then \
        echo "${CLAUDE_CODE_SHA256}  ${claude_bin}" | sha256sum -c -; \
    fi

# Move image-provided CLIs out of the shadowed home bin dir.
# /home/coder/.local/bin is over-mounted at runtime with the generated home's
# .local/bin (read-write, hosts the opt-in LSP/formatter binaries), which would
# hide anything baked into the image there (claude, uv). /usr/local/bin is
# root-owned, on PATH, and never mounted over.
# The Claude installer lays down SYMLINKS into ~/.local/share/claude/versions/,
# and that tree is itself shadow-mounted at runtime (sessions dir), which would
# leave dangling links — so copy DEREFERENCED (-L), never move the links.
USER root
RUN set -e; \
    for b in /home/coder/.local/bin/*; do \
        if [ ! -e "$b" ] && [ ! -L "$b" ]; then continue; fi; \
        if [ -L "$b" ]; then echo "dereferencing $b -> $(readlink "$b")"; fi; \
        cp -aL "$b" /usr/local/bin/; \
        rm -rf "$b"; \
    done; \
    chown -R coder:coder /home/coder/.local/bin 2>/dev/null || true; \
    ls -la /usr/local/bin/claude; \
    test -f /usr/local/bin/claude && test ! -L /usr/local/bin/claude && test -x /usr/local/bin/claude; \
    command -v claude && command -v uv && claude --version

# Root-owned node for the guard hooks' trusted path (T-04). The hooks never
# use the inherited PATH (the session-writable ~/.local/bin comes first) and
# the NVM tree under the group-writable home can be modified by the session,
# so the policy evaluator runs from this read-only copy instead. Users keep
# the NVM node (and nvm switching) on their own PATH.
RUN install -d -m 0755 /usr/local/lib/claude-dockerized/bin && \
    install -m 0755 "$(readlink -f /home/coder/.nvm/default/node)" /usr/local/lib/claude-dockerized/bin/node && \
    /usr/local/lib/claude-dockerized/bin/node --version

# STRIP_SETUID=1 (setting.image_strip_setuid=true) clears every setuid/setgid
# bit (su, passwd, mount, newgrp, ssh-keysign, ...). no_new_privileges already
# neutralizes them at runtime; this is defense in depth for runtimes where it
# is missing (T-21).
ARG STRIP_SETUID=0
RUN if [ "$STRIP_SETUID" = 1 ]; then \
        find / -xdev -perm /6000 -type f -exec chmod a-s {} + ; \
        test -z "$(find / -xdev -perm /6000 -type f -print -quit)"; \
    fi
USER coder

# Create the writable home tree, owned by coder and group-writable (g+rwX) so
# the wrapper can grant any host UID access with `--group-add coder` (a name
# resolved against the container's /etc/group, hence gid 1000). Runs as coder:
# it owns the tree, so no root step is needed and the image stays non-root.
# NOTE: LSP servers and formatters are NOT baked in here; they live in
# CCODE_HOME/home/.local/bin on the host (see lib/lsp-lib.sh
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
