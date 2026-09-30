#!/bin/bash
# doctor-container.sh - diagnostics run INSIDE the container by
# `claude-dockerized doctor` (passed as a bash -c script; never on the host).
# Read-only: it only reports what is actually usable and exits non-zero on a
# real failure (e.g. GPG enabled but the agent socket or public keyring is
# missing, so signed commits would fail).

status=0
note() { printf "%s\n" "$1"; }
echo "== guard hooks =="
if [ -x /home/coder/.claude/hooks-guard/claude-guard-bash.sh ] && [ -x /home/coder/.claude/hooks-guard/claude-guard-file.sh ]; then
    grep -m1 CLAUDE_DOCKERIZED_GUARD_VERSION /home/coder/.claude/hooks-guard/claude-guard-bash.sh || true
    if [ -f /home/coder/.claude/hooks-guard/policies/VERSION ]; then
        note "policies: v$(cat /home/coder/.claude/hooks-guard/policies/VERSION 2>/dev/null)"
    else
        note "policies: MISSING"; status=1
    fi
else
    note "MISSING guard hooks"; status=1
fi
echo "== managed settings =="
managed=/etc/claude-code/managed-settings.json
if [ -f "$managed" ]; then
    if grep -q DISABLE_AUTOUPDATER "$managed" 2>/dev/null; then
        note "auto-updates: disabled (managed policy)"
    else
        note "auto-updates: NOT disabled in $managed"; status=1
    fi
    if grep -q claude-guard-bash.sh "$managed" 2>/dev/null; then
        note "guard hooks: wired in the managed policy"
    else
        note "guard hooks: NOT wired in $managed"; status=1
    fi
    if touch "$managed" 2>/dev/null; then
        note "managed policy: WRITABLE (must be a read-only mount)"; status=1
    fi
else
    note "MISSING $managed"; status=1
fi
for f in "$managed" /home/coder/.claude/settings.json "${CLAUDE_DOCKERIZED_WORKDIR:-.}/.claude/settings.json" "${CLAUDE_DOCKERIZED_WORKDIR:-.}/.claude/settings.local.json"; do
    if [ -f "$f" ] && grep -q disableAllHooks "$f" 2>/dev/null; then
        note "disableAllHooks: PRESENT in $f"; status=1
    fi
done
us=/home/coder/.claude/settings.json
if [ ! -f "$us" ]; then
    note "MISSING user settings.json"; status=1
elif [ -w "$us" ]; then
    note "user settings: writable (/model and /config persist)"
else
    note "user settings: NOT writable (/model cannot save)"; status=1
fi
note "policy mode: $(cat /home/coder/.claude/hooks-guard/policy-mode 2>/dev/null || echo "MISSING")"
echo "== claude =="
claude --version 2>&1 || { note "claude binary: FAILED"; status=1; }
if command -v claude >/dev/null 2>&1; then
    claude doctor 2>&1 || note "(native claude doctor reported issues above)"
fi
echo "== ssh agent =="
if [ "${CLAUDE_DOCKERIZED_SSH_AGENT:-false}" != true ]; then
    note "ssh agent forwarding: disabled in wrapper config (skipped)"
elif [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
    ssh-add -l 2>&1 || true
else
    note "SSH_AUTH_SOCK is unset or not a socket"; status=1
fi
echo "== gnupg =="
if [ "${CLAUDE_DOCKERIZED_GPG_AGENT:-false}" != true ]; then
    note "gnupg forwarding: disabled in wrapper config (skipped)"
else
gpg_home="${GNUPGHOME:-$HOME/.gnupg}"
if [ -S "$gpg_home/S.gpg-agent" ]; then
    note "agent socket: ok"
else
    note "agent socket: MISSING ($gpg_home/S.gpg-agent)"; status=1
fi
if [ -f "$gpg_home/pubring.kbx" ] || [ -f "$gpg_home/public-keys.d/pubring.db" ]; then
    note "public keyring: ok"
else
    note "public keyring: MISSING (signed commits will fail)"; status=1
fi
if gpg --list-keys >/dev/null 2>&1; then
    note "list-keys: ok"
else
    note "list-keys: FAILED"; gpg --list-keys 2>&1 | head -3; status=1
fi
if ! gpg --list-secret-keys >/dev/null 2>&1; then
    note "list-secret-keys: none visible (the forwarded agent can still sign by key id)"
fi
signingkey=$(gpg --list-keys --with-colons 2>/dev/null | grep "^pub:" | head -n1 | cut -d: -f5)
if [ -n "$signingkey" ]; then
    if printf test | timeout 5 gpg --batch --local-user "$signingkey" --sign >/dev/null 2>&1; then
        note "sign probe: ok ($signingkey)"
    else
        note "sign probe: could not sign non-interactively ($signingkey); confirm with a real signed commit (pinentry runs on the host)"
    fi
else
    note "sign probe: skipped (no public key)"
fi
fi
echo "== config secrets =="
sc=/home/coder/.claude/settings.json
if [ -f "$sc" ] && grep -oE "\"(apiKey|api_key|token|secret|password|authorization)\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$sc" 2>/dev/null | grep -qvE "\\$|apiKeyHelper"; then
    note "inline secrets: FOUND in settings.json (move them to the env file or apiKeyHelper)"; status=1
else
    note "inline secrets: none"
fi
echo "== runtime hardening =="
note "profile: ${CLAUDE_DOCKERIZED_HARDENING:-off} (setting.hardening: off|standard|strict)"
if probe=$(mktemp -p /usr 2>/dev/null); then unlink "$probe"; note "root filesystem: writable"; else note "root filesystem: read-only"; fi
echo "== model =="
if [ -n "${CLAUDE_DOCKERIZED_MODEL:-}" ]; then
    note "model: ${CLAUDE_DOCKERIZED_MODEL} (wrapper default; /model still works)"
else
    note "model: default (not preset)"
fi
echo "== lsp / formatters =="
if [ "${CLAUDE_DOCKERIZED_LSP:-false}" = true ]; then
    for bin in gopls typescript-language-server pyright-langserver rust-analyzer; do
        if command -v "$bin" >/dev/null 2>&1; then note "lsp: $bin ok"; else note "lsp: $bin MISSING"; fi
    done
else
    note "lsp: disabled in wrapper config (skipped)"
fi
if [ "${CLAUDE_DOCKERIZED_FORMATTERS:-false}" = true ]; then
    for bin in ruff prettier; do
        if command -v "$bin" >/dev/null 2>&1; then note "formatter: $bin ok"; else note "formatter: $bin MISSING"; fi
    done
else
    note "formatters: disabled in wrapper config (skipped)"
fi
echo "== env file =="
if [ "${CLAUDE_DOCKERIZED_ENV_FILE:-no}" = yes ]; then
    note "env file: loaded (--env-file)"
else
    note "env file: not configured"
fi
echo "== result =="
if [ "$status" -eq 0 ]; then note "all good"; else note "problems detected"; fi
exit "$status"
