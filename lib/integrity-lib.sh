#!/bin/bash
# integrity-lib.sh - session integrity check (Blue team detection).
# Sourced by lib/config-lib.sh. Not executable directly; no `set -e`.
#
# Some read-write paths are executed or trusted outside the session that can
# write them: the project's git hooks/config run on the HOST (T-01), the
# generated home's ~/.local/bin, plugins, skills, agents, commands and MCP
# server entries run in every FUTURE session (T-05). No host CLI directory is
# mounted (T-02). The default profile keeps them writable, so the
# wrapper fingerprints them (sha256 of content, mode and symlink target; an
# mtime could be forged) before the session and reports every change after
# it, with a JSONL audit trail in $CONFIG_DIR/audit/sessions.jsonl.
# `setting.integrity_check=false` disables it.

# Emit "<kind> <sha256|-> <mode> <path> [-> target]" lines for one root.
# Usage: _integrity_walk <path>
_integrity_walk() {
    local root="$1"
    [ -e "$root" ] || [ -L "$root" ] || return 0
    find "$root" \( -type f -o -type l \) -print0 2>/dev/null | sort -z |
        while IFS= read -r -d '' f; do
            if [ -L "$f" ]; then
                printf 'link - - %s -> %s\n' "$f" "$(readlink "$f" 2>/dev/null)"
            else
                printf 'file %s %s %s\n' "$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)" \
                    "$(stat -c '%a' "$f" 2>/dev/null)" "$f"
            fi
        done
}

# Only the MCP server entries of ~/.claude.json (the rest is session state
# Claude Code rewrites on every start). Prints one fingerprint line.
# Usage: _integrity_mcp_servers <claude.json>
_integrity_mcp_servers() {
    local file="$1" servers=""
    [ -f "$file" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        servers=$(jq -cS '[.mcpServers // {}, ((.projects // {}) | map_values(.mcpServers // {}))]' "$file" 2>/dev/null)
    elif command -v node >/dev/null 2>&1; then
        servers=$(node -e '
const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const p = Object.fromEntries(Object.entries(d.projects ?? {}).map(([k, v]) => [k, v?.mcpServers ?? {}]));
const sort = (o) => (o && typeof o === "object" && !Array.isArray(o) ? Object.fromEntries(Object.keys(o).sort().map((k) => [k, sort(o[k])])) : o);
console.log(JSON.stringify(sort([d.mcpServers ?? {}, p])));' "$file" 2>/dev/null)
    fi
    [ -n "$servers" ] || servers="unparseable"
    printf 'mcp %s - %s#mcpServers\n' "$(printf '%s' "$servers" | sha256sum | cut -d' ' -f1)" "$file"
}

# Fingerprint every watched path into <out>.
# Usage: integrity_snapshot <project_dir> <out>
integrity_snapshot() {
    local project="$1" out="$2" rel
    {
        if [ -n "$project" ]; then
            for rel in .git/config .git/hooks .claude/settings.json .claude/settings.local.json \
                .mcp.json .envrc .vscode/tasks.json .vscode/settings.json; do
                _integrity_walk "$project/$rel"
            done
        fi
        for rel in .local/bin .claude/plugins .claude/skills .claude/agents .claude/commands .claude/.lsp.json; do
            _integrity_walk "$CCODE_HOME/$rel"
        done
        _integrity_mcp_servers "$CCODE_HOME/.claude.json"
    } >"$out" 2>/dev/null
    # Detection is best-effort: never abort a caller running under `set -e`.
    return 0
}

# Paths whose fingerprint differs between two snapshots (added, removed or
# changed), one per line, sorted and unique.
# Usage: integrity_changes <before> <after>
integrity_changes() {
    diff <(sort "$1") <(sort "$2") 2>/dev/null |
        sed -n 's/^[<>] [a-z]* [^ ]* [^ ]* \(.*\)$/\1/p' | sed 's/ -> .*$//' | sort -u
}

# Report the changes of one session: a warning per path on the terminal and
# one JSONL record in the audit log. Returns 0 when nothing changed.
# Usage: integrity_report <project_dir> <before> <after>
integrity_report() {
    local project="$1" before="$2" after="$3" changes
    changes=$(integrity_changes "$before" "$after")
    [ -n "$changes" ] || return 0

    config_warning "Session integrity: these persistent paths changed during the session:"
    local path
    while IFS= read -r path; do
        printf '  - %s\n' "$path" >&2
    done <<<"$changes"
    config_info "They run on the host or in later sessions: review them (git diff, cat) before trusting them."

    local audit_dir="$CONFIG_DIR/audit" json_paths
    mkdir -p "$audit_dir" 2>/dev/null && chmod 700 "$audit_dir" 2>/dev/null
    json_paths=$(printf '%s\n' "$changes" | _integrity_json_array)
    printf '{"time":"%s","project":%s,"changed":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(printf '%s' "$project" | _integrity_json_string)" "$json_paths" \
        >>"$audit_dir/sessions.jsonl" 2>/dev/null
    chmod 600 "$audit_dir/sessions.jsonl" 2>/dev/null
    return 1
}

# JSON-encode stdin as a string / as an array of lines (no external deps).
_integrity_json_string() {
    local s
    s=$(cat)
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\t'/\\t}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    printf '"%s"' "$s"
}
_integrity_json_array() {
    local line first=true
    printf '['
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        [ "$first" = true ] || printf ','
        first=false
        printf '%s' "$line" | _integrity_json_string
    done
    printf ']'
}

# Print the most recent audit record (or nothing). Usage: integrity_last_report
integrity_last_report() {
    local log="$CONFIG_DIR/audit/sessions.jsonl"
    if [ -s "$log" ]; then
        tail -n 1 "$log"
    fi
    return 0
}
