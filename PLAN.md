# PLAN — `claude-dockerized` (Claude Code dockerizado)

> **Nota (2026-09-30):** registro histórico del port. El modelo de seguridad
> vigente (política gestionada en `/etc/claude-code/managed-settings.json`,
> guard fail-closed, perfiles de hardening, updates firmados, integridad de
> sesión) está en `SECURITY.md` y `docs/security/`; donde este plan difiera,
> manda la documentación actual.

> **Estado de implementación (2026-09-29): IMPLEMENTADO.** El port completo
> está aplicado en este checkout: `bin/claude-dockerized`, `lib/` (CCODE_*),
> `hooks/` nativos, `Dockerfile` con binario nativo v2.1.284, montajes finos
> opción A, `DISABLE_AUTOUPDATER=1`, LSP/formatters opt-in en el home
> generado, y suites `tests/claude-guard.test.mjs` +
> `tests/wrapper-args.test.sh` en verde. El resto de este documento conserva
> el plan original como referencia histórica.
>
> Estado original: **plan, sin implementar**. No tocar código hasta nuevas instrucciones.
> Idioma del plan: español. Nombres de archivos/símbolos en inglés original.
> Fecha: 2026-09-29 (rev.2 con decisiones vinculantes del usuario).
> Fuentes Claude Code: Context7 MCP (`/websites/code_claude`,
> `/llmstxt/code_claude_llms_txt`, `/anthropics/claude-code`) + `code.claude.com/docs`.

## 0. Decisiones vinculantes (rev.2 — cierran lo abierto en rev.1)

1. **Nombre: `claude-dockerized`.** En la implementación **toda** mención a
   OpenCode desaparece: código, variables, env, comentarios in-code, docs,
   mensajes, tests y artefactos. Ver tabla de renombrado §1.3. El §2 conserva
   nombres `opencode-*` solo como inventario del legado a portar.
2. **Instalación Claude solo binaria nativa, sin npm.**
   `npm i -g @anthropic-ai/claude-code` queda prohibido (sin soporte oficial).
3. **Imagen: `debian:trixie-slim` + NVM + Node.js `--lts` + `uv`.**
   Se mantiene la base y toolchain actuales; solo cambia el agente instalado.
4. **Toda persistencia Claude vive en el home generado** (`CCODE_HOME`,
   espejo de `/home/coder`). Cero toques a XDG del host.
5. **Toda la seguridad se porta a mecanismos nativos Claude Code**:
   `permissions.deny/ask`, hooks `PreToolUse`/`PostToolUse`, `sandbox`,
   `disableBypassPermissionsMode`, `CLAUDE.md` gestionado. Nada de plugin JS
   `permission.evaluate` (no existe en Claude).
6. **LSP y formatters nativos y opt-in**, instalados en el home generado
   (separación host/container), persistentes ante rebuild.
7. **Versión fijada: `v2.1.284` por `ARG CLAUDE_CODE_VERSION`** e instalación
   según `setup#install-a-specific-version`:
   `curl -fsSL https://claude.ai/install.sh | bash -s 2.1.284`.
   Verificación: `claude --version` → `2.1.284 (Claude Code)`. Nunca `latest`
   en prod. `update` reconstruye con `--build-arg` + bust-cache.
8. **Manejo remoto permitido por defecto en los tres modos**
   (`strict`, `balanced`, `none`). La seguridad existe para evitar desastres
   (ej. un `rm -rf $HOME` generado por el agente, malas prácticas, leaks),
   no para bloquear flujos remotos legítimos (git por SSH, MCP `http/sse`
   remotos, API endpoints, OAuth). Ningún modo bloquea esos flujos; solo
   bloquea destrucción/exfiltración/secretos.
9. **Claude Code no se autoactualiza.** `env.DISABLE_AUTOUPDATER=1` en el
   `settings.json` gestionado según `setup#disable-auto-updates`; verificado
   con `claude doctor` (`Auto-updates: disabled (set by env: …)`).
   La única vía de update es `claude-dockerized update` (rebuild).
   No setear `FORCE_AUTOUPDATE_PLUGINS=1` (los plugins tampoco se autoupdatean).
10. **Montajes opción A (decidido, sin fallback)**: montajes finos por
    archivo/dir, **nunca** `~/.claude/` entero. Detalle en §6.1.

### 1.3 Tabla de renombrado exhaustivo (aplicar en Fase 1, verificar con `grep`)

| Legado (prohibido en el nuevo código) | Nuevo (obligatorio) |
|---|---|
| `opencode-dockerized`, `opencode-*`, `OCD_*`, `ocd`, `ocd-run`, `ocd-auth` | `claude-dockerized`, `claude-*`, `CCODE_*`, `ccd`, `ccd-run`, `ccd-auth` |
| `bin/opencode-dockerized`, `IMAGE_NAME=opencode-dockerized:latest` | `bin/claude-dockerized`, `IMAGE_NAME=claude-dockerized:latest` |
| `~/.config/opencode-dockerized/`, `CONFIG_DIR` legado, `OCODE_HOME`, `OCODE_INSTALL_DIR`, `OCODE_BIN_DIR`, `OCODE_REPO_URL`, `OCODE_BIN_PATH_LINE` | `~/.config/claude-dockerized/`, `CCODE_HOME`, `CCODE_INSTALL_DIR`, `CCODE_BIN_DIR`, `CCODE_REPO_URL`, `CCODE_BIN_PATH_LINE` |
| `OPENCODE_WORKDIR`, `OPENCODE_CONFIG_CONTENT`, `OPENCODE_CONFIG_DIR`, `OPENCODE_DISABLE_AUTOUPDATE`, `OPENCODE_CLI_CONFIG_CONTENT`, `OPENCODE_DOCKERIZED_*`, `OPENCODE_DOCKERIZED_POLICY`, `OPENCODE_DOCKERIZED_GUARD_VERSION` | `CLAUDE_DOCKERIZED_WORKDIR` (workdir wrapper; no colisiona con `CLAUDE_CONFIG_DIR` nativo), sin equivalente inline (la inmutabilidad es montaje ro + protected paths + hooks), `env.DISABLE_AUTOUPDATER=1` en `settings.json`, `CLAUDE_DOCKERIZED_POLICY`, `CLAUDE_DOCKERIZED_GUARD_VERSION`, resto `CLAUDE_DOCKERIZED_*` (SSH/GPG/doctor flags) |
| `opencode.json`, `opencode.jsonc`, `cli.json`, `OPENCODE_VERSION`, `OPENCODE_BUILD_TIME`, `TMPDIR=/tmp/opencode`, `/tmp/opencode` | `settings.json` (+ `settings.local.json` proyecto, `managed-settings.json` enterprise opcional), `~/.claude.json`, `CLAUDE_CODE_VERSION=2.1.284`, `CLAUDE_BUILD_TIME`, `TMPDIR=/tmp/claude`, `/tmp/claude` |
| `AGENTS.md` gestionado (solo OpenCode), `plugins/security-guard.js`, `OPENCODE_DOCKERIZED_GUARD_VERSION` | `CLAUDE.md` gestionado (canónico Claude; `AGENTS.md` solo como alias symlink/documentado si se quiere compat), `hooks/claude-guard-bash.sh` + `hooks/claude-guard-file.sh`, `CLAUDE_DOCKERIZED_GUARD_VERSION` |
| `opencode auth login`, `opencode mcp *`, `opencode plugin *`, `opencode run/serve --standalone`, `opencode --version` | `claude auth login`, `claude mcp *`, `claude plugin *`, `claude [-p]`, `claude --version` |
| `setting.websearch_provider`, `setting.theme`, `OPENCODE_API_KEY`, `OPENCODE_*` env | eliminados; `setting.model`, `setting.cleanup_days`, `setting.lsp`, `setting.formatters` (nuevos, §7); secretos solo `ANTHROPIC_*` / `CLAUDE_CODE_OAUTH_TOKEN` vía `setting.env_file` |
| `install.sh` (`OCODE_*`), `run-simple.sh`, shims `opencode-dockerized.sh/setup.sh`, `completions/*opencode*`, `examples/config.example` con `setting.*` OpenCode | mismos archivos renombrados a `claude-dockerized` con `CCODE_*`; shims legado solo como redirect con warning o eliminados en major |

Criterio de aceptación del renombrado (Fase 1/7): `grep -rniE 'opencode|OCODE|OPENCODE' --exclude-dir=.git --exclude=PLAN.md .` vacío,
salvo `PLAN.md` §2 (histórico) y `policies/LICENSE.opencode-policy` +
`policies/README.md` (atribución del vendored, obligatoria por licencia MIT).

---

## 1. Objetivo y alcance

### 1.1 Objetivo

Distribuir `claude-dockerized`: wrapper que ejecuta **Claude Code v2.1.284
(binario nativo)** en Docker con el mismo nivel de aislamiento del proyecto
actual, con paridad en:

- Aislamiento: solo `$PROJECT_DIR` en rw, resto por montajes finos explícitos,
  usuario no-root (`--user uid:gid`, `--cap-drop=ALL`, `no-new-privileges`),
  socket Docker opt-in, `--network host|bridge`, límites `--memory/--cpus`.
- SSH y GPG desde el host **igual que hoy** (solo socket + material público,
  sin llaves privadas en el contenedor, relay `socat` para tmpfs, autostart +
  liveness probe, `doctor`).
- Persistencia total en `CCODE_HOME` ante `up/down/upgrade/rebuild`: login,
  `settings.json`, MCP (`~/.claude.json` + `.mcp.json` + OAuth), plugins, LSP
  (`.lsp.json` + binarios en `~/.local/bin` del home generado), formatters,
  sesiones/historial, skills/agents/commands/hooks.
- Capa de seguridad 100% nativa Claude y versionada (`config sync [--check]`,
  backups `.bak`, `VERSION` para policies, `GUARD_VERSION` para hooks).
- Manejo remoto funcional en `strict/balanced/none` (§0.8).
- Sin autoupdates (§0.9). Contratos testeados (`bash` + `node`, CI-parity con
  `shellcheck/hadolint`).

### 1.2 No-objetivos (esta fase)

- No endurecer con `--read-only` + tmpfs ni seccomp personalizado (hardening
  futuro; documentar en `SECURITY.md`).
- No firewall iptables / `--dangerously-skip-permissions` por defecto. El
  sandbox Docker sigue siendo la frontera; el `sandbox:` nativo es defensa en
  profundidad.
- No mover secretos fuera de `setting.env_file` + `docker --env-file`.
- No `managed-mcp.json` ni `allowManagedPermissionRulesOnly` por defecto
  (opt-in enterprise documentado).

---

## 2. Inventario del legado (qué se porta; nombres `opencode-*` solo aquí)

| Pieza legado | Responsabilidad | Destino en `claude-dockerized` |
|---|---|---|
| `Dockerfile` (debian:trixie-slim, NVM+node LTS, pnpm, uv, docker-ce-cli, user `coder:1000`, `ENTRYPOINT entrypoint.sh`, `CMD opencode`) | imagen reproducible | Nuevo `Dockerfile` §5: misma base/toolchain (sin instalador pnpm para el agente), Claude nativo v2.1.284. Reutilizar: no-sudo, `coder`, `g+rwX` + `--group-add coder`, capas por concern, `ARG` de versiones, limpieza apt |
| `entrypoint.sh` (resuelve `OPENCODE_WORKDIR`, `HOME=/home/coder`, PATH, `gpgconf --launch keyboxd`, `exec bash -c 'source nvm… cd WORKDIR exec "$@"'`) | arranque unprivileged | Gemelo con `CLAUDE_DOCKERIZED_WORKDIR`, misma lógica keyboxd + NVM/PATH, sin cambios de privilegios |
| `bin/opencode-dockerized` (~909 lín: `run/auth/models/exec/mcp/plugin/stats/debug/doctor/install/upgrade/update/version/config/clean`, `PRIVATE_SERVER_SCRIPT`, `DOCTOR_SCRIPT`, `DRY_RUN`, traps relay) | UX del wrapper | `bin/claude-dockerized`, mismo esqueleto, comandos remapeados a CLI `claude` (§7). Eliminar `PRIVATE_SERVER_SCRIPT` (Claude no tiene `serve`) |
| `lib/config-lib.sh` (~1500+ lín: `CONFIG_DIR/OCODE_HOME/GPG_RELAY_DIR`, `parse_config`, `build_*`, `ensure_opencode_dirs/dirs_dockerized_config`, `merge_opencode_permissions`, `sync/check_security_layer`, `resolve_gpg_*`, `start/stop_gpg_relay`, `validate_project_dir`, `dry_run_print`) | montajes/env/sync | Adaptar a `CCODE_*` + generadores `settings.json` + hooks (§6). Reutilizar **verbatim** donde sea agnóstico: `validate_project_dir`, `compute_container_path`, `sanitize_container_name`, `generate_random_suffix`, SSH/GPG relay/probe/mirror, `env_file_upsert`, `dry_run_print`, `relay_dir_ok/cleanup_stale_relays` |
| `lib/install-lib.sh` (wizard `--yes/--only config,completions,aliases,global[,path][,build]`, PATH `<install>/bin`, aliases `ocd/*`, completions, `ensure_git_upstream`) | install/repair | Misma estructura con `ccd/ccd-run/ccd-auth`, `CCODE_*`; invariantes: nada en `~/.local/bin`, bin/ solo el binario, idempotencia, `curl\|bash` auto-`--yes` |
| `plugins/security-guard.js` v17 (`OPENCODE_DOCKERIZED_GUARD_VERSION`, modos, `BALANCED_EXCLUDED_IDS`, `DENY_*`, `normalizeShell/normalizeLexical/tryRealpath`, hook `permission.evaluate`) | enforcement OpenCode V2 | **No reutilizable tal cual** (Claude no tiene ese hook JS). Portar reglas a hooks shell nativos + `permissions.deny` (§6.3–6.4). Reutilizar: `policies/*.json` + `VERSION`, semántica `balanced`, batería `DENY_*` |
| `policies/{unsafe-tool-patterns,prompt-injection-patterns,allow-patterns}.json` + `VERSION=2` | datos vendored `opencode-policy` | Reutilizar **sin cambios de formato** (`new RegExp(pattern, flags ?? "i")`, first-match, allowlist con veto si hay `[;&|\n\r]`) |
| `tests/security-guard.test.mjs` + `tests/wrapper-args.test.sh` | regresión | Portar a `tests/claude-guard.test.mjs` (hooks vía stdin JSON) + `tests/wrapper-args.test.sh` actualizado (§9) |
| `completions/*`, `examples/config.example`, `install.sh`, `run-simple.sh`, shims | distribución | Renombrar a `claude-dockerized` con `CCODE_REPO_URL/CCODE_INSTALL_DIR` |
| `README.md/SECURITY.md/CONTRIBUTING.md/AGENTS.md` | docs + reglas agente | Reescribir deltas Claude; la regla gestionada pasa a `CLAUDE.md` |

---

## 3. Fundamentos Claude Code (Context7 — lo que condiciona el diseño)

Vía `CONTEXT7_MCP_RESOLVE_LIBRARY_ID` → `/websites/code_claude` y
`CONTEXT7_MCP_QUERY_DOCS` (`code.claude.com/docs/en/*`):

1. **Instalación con versión fija — solo nativa** (`setup#install-a-specific-version`,
   `self-hosted-environments-deploy`).
   - `curl -fsSL https://claude.ai/install.sh | bash -s 2.1.284` (acepta número
     o canal `latest|stable`; el canal elegido queda como default de
     autoupdates — por eso fijamos número + desactivamos autoupdates).
   - Confirmación: `claude --version` → `2.1.284 (Claude Code)`.
   - Runner oficial de referencia: `debian:bookworm-slim` + `git curl
     ca-certificates openssh-client` + `git config --system user.name/email +
     safe.directory '*'` + `ENTRYPOINT ["claude"]`. Nosotros usamos
     **`debian:trixie-slim`** (decisión §0.3) con la misma receta.
   - Fleet pinning: build con versión fija o install fijo + autoupdates off;
     upgrade = instalar/rebuild + restart. Plugins tampoco autoupdatean salvo
     `FORCE_AUTOUPDATE_PLUGINS=1` (no lo seteamos).
   - **Prohibido npm** en este proyecto (decisión §0.2).
   - Hardening SDK (`agent-sdk/secure-deployment`): `--cap-drop ALL`,
     `no-new-privileges`, `--read-only`, `--tmpfs`, `--network none`,
     `--memory/--cpus/--pids-limit`, `--user 1000:1000`. Hacemos el subconjunto
     dev-compatible (sin `--read-only` por ahora).
2. **Desactivar autoupdates** (`setup#disable-auto-updates`).
   - `"env": {"DISABLE_AUTOUPDATER": "1"}` en `settings.json` (para la
     instalación nativa). Verificación: `claude doctor` →
     `Auto-updates: disabled (set by env: DISABLE_AUTOUPDATER)`.
   - `DISABLE_AUTOUPDATER` frena el check en background; `claude update` /
     `claude install` manuales siguen funcionando. `DISABLE_UPDATES` bloquearía
     hasta lo manual (no lo usamos: el wrapper actualiza vía rebuild).
   - El runner apaga autoupdate dentro de las sesiones que spawnea.
   - **Implicación**: plantilla gestionada siempre con ese `env`; `doctor` y
     `sync --check` lo exigen; `update` del wrapper es la única vía soportada.
3. **Auth / credenciales** (`authentication`, `env-vars`).
   - `claude auth login` (con pegado de código OAuth para WSL/SSH/contenedor).
   - Linux: `~/.claude/.credentials.json` modo `0600` (macOS Keychain, fallback
     al mismo archivo). Respeta `CLAUDE_CONFIG_DIR`.
   - Tipos: `claude.ai`, API Anthropic, Foundry/Bedrock/Vertex, `apiKeyHelper`
     (~5 min, `CLAUDE_CODE_API_KEY_HELPER_TTL_MS`), `ANTHROPIC_API_KEY /
     ANTHROPIC_AUTH_TOKEN / ANTHROPIC_BASE_URL`, `CLAUDE_CODE_OAUTH_TOKEN`
     (de `claude setup-token`, precede al keychain).
   - **Implicación**: `.credentials.json` vive en `CCODE_HOME` (rw, `0600`,
     montaje fino §6.1). Nunca loguearlo/catearlo; `doctor` solo reporta
     presencia + `0600` + login válido.
4. **Settings — jerarquía** (`settings`).
   - `managed` > CLI flags (`--settings`, `--model`) > project local
     (`.claude/settings.local.json`) > shared project (`.claude/settings.json`)
     > user (`~/.claude/settings.json`). `strict JSON`, verificar con `/status`.
   - Nuestra capa gestionada vive en nivel **user**
     (`/home/coder/.claude/settings.json`, montado **ro**). `managed-settings.json`
     solo como opt-in enterprise futuro.
5. **Permissions** (`settings`, `settings-example`).
   - `{"permissions": {"allow": ["Bash(npm run *)"], "ask": ["Bash(git push *)"], "deny": ["Read(./.env)", …]}}`.
   - Enterprise: `disableBypassPermissionsMode: "disable"`,
     `allowManagedPermissionRulesOnly`, `allowedMcpServers/…`,
     `strictKnownMarketplaces`, `sandbox{…}`, `requiredMinimumVersion`,
     `cleanupPeriodDays`.
   - Generamos `deny` (secretos, `rm -rf /`, `sudo`, `mkfs/dd/shutdown`,
     `docker -v /:/ --privileged`, metadata-IP) + `ask` (`git push`,
     `git reset --hard`, `docker system prune`) + `allow` mínimo.
     Primera capa; los hooks son la segunda.
6. **Hooks nativos** (`hooks-guide`, `sub-agents`, `server-managed-settings`).
   - Niveles: user > project > local > managed > `plugin hooks/hooks.json` >
     skill/subagent frontmatter. Ver con `/hooks`; `disableAllHooks:true` los
     apaga (lo detectamos en `doctor`/`sync --check`).
   - `PreToolUse` (bloqueable), `PostToolUse` (auditoría).
   - Protocolo: `{"matcher": "Bash|Edit|Write|Read|…", "hooks": [{"type":
     "command", "command": "/path/hook.sh"}]}`; stdin JSON
     (`.tool_input.command`, `.tool_input.file_path`…); **exit 2 + stderr =
     bloqueo con feedback**; exit 0 = sin objeción (sigue `permissions`).
   - Canónico: `INPUT=$(cat); COMMAND=$(echo "$INPUT" | jq -r
     '.tool_input.command')`; `… → echo … >&2; exit 2`. Condicional
     `"if": "Bash(git commit *)"` disponible.
   - Los scripts deben ser ejecutables, ro, sin red.
7. **MCP** (`mcp`, `managed-mcp`).
   - Scopes local/project/user; `claude mcp add/list/get/login/logout`;
     `claude mcp login <name>` OAuth sin sesión.
   - `.mcp.json` (proyecto), `~/.claude.json`, `managedMcpServers` (solo
     `http/sse`), `managed-mcp.json` (control exclusivo),
     `allowedMcpServers[]` por URL, `allowManagedMcpServersOnly`.
   - OAuth en keychain/credentials, nunca en config.
   - Política: `add/remove` host-only (config ro); `login/logout/list/get` sí
     dentro (tokens en dir rw). Los MCP **remotos** (`http/sse`) deben funcionar
     en los 3 modos (§0.8).
8. **Plugins** (`plugins`, `plugins-reference`).
   - `claude plugin install formatter@marketplace [--scope user|project|local]`;
     `extraKnownMarketplaces`, `enabledPlugins`, `strictKnownMarketplaces`.
   - `userConfig sensitive:true` → credential storage.
   - Plugins usuario en `~/.claude/plugins/` (rw persistido); el de seguridad
     son nuestros hooks ro, no un marketplace. `install/update/remove`
     host-only; `list/check` sí dentro.
9. **LSP / formatters** (`plugins`, `tools-reference`).
   - LSP vía plugins de inteligencia; custom con `.lsp.json`:
     `{"go": {"command": "gopls", "args": ["serve"], "extensionToLanguage":
     {".go": "go"}}}`. Binario instalado por el usuario; si falta →
     `/plugin` Errors (`Executable not found in $PATH`); config inválida → skip
     (`claude --debug`). Tool `LSP` inactivo sin plugin.
   - Formatters vía `enabledPlugins` + binarios.
   - En este proyecto: binarios en `CCODE_HOME/home/.local/bin` (rw, en PATH)
     + `.lsp.json` + plugins persistidos; flags `setting.lsp/formatters` (§6.5).
10. **Sandbox nativo y protected paths** (`sandboxing`, `sandbox-environments`).
    - `sandbox{enabled, filesystem{allowWrite,denyRead/allowRead}, network{…}}`.
    - Protected paths no eximibles: `.claude/settings*.json`,
      `.claude/skills|agents|commands|hooks`, `.mcp.json`, `workflows`,
      `scheduled_tasks.json`, `.bashrc/.zshrc`, `.gitconfig`, `.vscode/.idea`,
      `.git/hooks|config`, `HEAD/objects/refs/config`, y en `~/.claude`
      (o `CLAUDE_CONFIG_DIR`) casi todo + `~/.claude.json` + `.credentials.json`.
      Solo `filesystem.disabled` lo apaga (prohibido).
    - Generamos `sandbox.filesystem.allowWrite: ["/tmp/claude"]`; no intentar
      eximir protected paths.

---

## 4. Brechas legado → `claude-dockerized` (decisiones cerradas)

| Dimensión | Legado | `claude-dockerized` (obligatorio) |
|---|---|---|
| Instalación en imagen | `pnpm add -g @opencode/cli` (`ARG OPENCODE_VERSION/…_BUILD_TIME`) | **Solo nativa**: `ARG CLAUDE_CODE_VERSION=2.1.284`; `curl -fsSL https://claude.ai/install.sh \| bash -s ${CLAUDE_CODE_VERSION}`; `ARG CLAUDE_BUILD_TIME=0` (solo `update` lo pasa). Sin npm. `claude --version` debe dar `2.1.284 (Claude Code)` |
| Autoupdates | `OPENCODE_DISABLE_AUTOUPDATE=true` (env) | `env.DISABLE_AUTOUPDATER=1` en `settings.json` gestionado + verificación `claude doctor`. Sin `FORCE_AUTOUPDATE_PLUGINS=1` |
| Base/toolchain | debian:trixie-slim + NVM/node LTS + pnpm + uv | **debian:trixie-slim + NVM/node `--lts` + `uv`** (se mantienen). El instalador pnpm para el agente desaparece; pnpm solo se conserva si un formatter/LS lo requiere (documentar), no para instalar Claude |
| Config principal | `opencode.json` + `cli.json` + `OPENCODE_CONFIG_CONTENT` inline | `~/.claude/settings.json` (user, ro) + proyecto/local + `~/.claude.json`. Sin inline-env: inmutabilidad = montaje fino ro + protected paths + hooks |
| Permisos | `permissions: [{action,resource,effect}]` | `permissions: {allow[],ask[],deny[]}` (`Bash()/Read()/…`) + `disableBypassPermissionsMode: disable`. Generador `build_claude_settings_json` (plantilla + merge `template-wins` con `jq`/`node`) |
| Enforcement | plugin JS `permission.evaluate` | **100% nativo**: hooks shell `PreToolUse` (exit 2) + `permissions.deny` + `sandbox`. Portar `DENY_*` + vendored a los scripts |
| Auth | `opencode auth login` → share/opencode | `claude auth login` / `setup-token` → `~/.claude/.credentials.json (0600)` en `CCODE_HOME`. `doctor` verifica `0600` + login sin imprimir secretos |
| MCP | `opencode mcp …` | `claude mcp …`; `add/remove` host-only, `login/logout/list/get` dentro; remotos `http/sse` OK en 3 modos; persistir `~/.claude.json` + credenciales + `~/.mcp-auth/` |
| Plugins seguridad | `security-guard.js` | `hooks/claude-guard-*.sh` ro + `GUARD_VERSION`; plugin usuario en `~/.claude/plugins/` rw |
| LSP | removido | **Nativo opt-in** `setting.lsp`: `.lsp.json` + binarios en `home/.local/bin` + plugins prebuilt; `doctor` chequea `command -v` |
| Formatters | removido | **Nativo opt-in** `setting.formatters`: `enabledPlugins` + binarios en `home/.local/bin` |
| scratch | `/tmp/opencode`, `TMPDIR=/tmp/opencode` | `/tmp/claude`, `TMPDIR=/tmp/claude` (plantilla + hooks + docs; `grep` verifica cero `opencode`) |
| Servidor privado | `opencode serve` + `PRIVATE_SERVER_SCRIPT` | Eliminado; `claude` one-shot (`-p`, `--model`, `--output-format`) |
| `websearch_provider/theme` | soportados | **Eliminados**; nuevos `setting.model`, `setting.cleanup_days`, `setting.lsp`, `setting.formatters` (§7) |

---

## 5. Imagen Docker objetivo (vinculante)

```dockerfile
FROM debian:trixie-slim
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG NVM_VERSION=v0.40.8
ARG CLAUDE_CODE_VERSION=2.1.284
ARG CLAUDE_BUILD_TIME=0           # solo `update` lo pasa para bust cache
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl bash ca-certificates zip unzip wget gnupg lsb-release \
      apt-transport-https ripgrep fd-find jq tree less procps openssh-client \
      python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*
# Docker CLI solo (igual que hoy)
RUN install -m 0755 -d /etc/apt/keyrings && curl -fsSL …/docker.asc … \
 && apt-get install -y docker-ce-cli docker-buildx-plugin docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*
RUN useradd -m -s /bin/bash -u 1000 coder
# git sistema (receta oficial Claude runner)
RUN git config --system user.name "Claude" \
 && git config --system user.email "noreply@anthropic.com" \
 && git config --system --add safe.directory '*'
USER coder
WORKDIR /home/coder
ENV NVM_DIR="/home/coder/.nvm"
RUN curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash \
 && bash -c "source $NVM_DIR/nvm.sh && nvm install --lts && nvm alias default node && nvm use default && ln -sf \$(dirname \$(which node)) $NVM_DIR/default"
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="$NVM_DIR/default:/home/coder/.composio:/home/coder/.local/bin:$PATH"
# Claude Code nativo con versión fija (setup#install-a-specific-version). Sin npm.
RUN curl -fsSL https://claude.ai/install.sh | bash -s ${CLAUDE_CODE_VERSION} \
 && claude --version
# NOTA: LSP/formatters NO se instalan aquí como root del sistema.
# Sus binarios viven en CCODE_HOME/home/.local/bin (rw, §6.5) para separación
# host/container; la imagen solo garantiza node/uv/jq/gopls? No: ni gopls en
# imagen salvo que Fase 0 demuestre que cabe sin romper slim (si no, todo a home).
RUN mkdir -p /home/coder/.claude /home/coder/.local/bin \
 && mkdir -p /home/coder/.local/share/claude /home/coder/.local/state/claude /home/coder/.cache/claude \
 && mkdir -p /home/coder/.claude/plugins /home/coder/.claude/skills /home/coder/.claude/agents /home/coder/.claude/commands \
 && chown -R coder:coder /home/coder && chmod -R g+rwX /home/coder
WORKDIR /
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude"]
```

Notas vinculantes:

- Último `USER coder`, `chown coder:coder + chmod g+rwX /home/coder`, sin sudo,
  `COPY` root-owned en `/usr/local/bin` (invariantes ya auditados en tests).
- `hadolint` en verde; `ARG CLAUDE_CODE_VERSION` documentado en `README`.
- `uv`/NVM/`~/.composio`/`~/.local/bin` en PATH (entrypoint re-exporta
  `/home/coder/.local/bin`, donde viven también los binarios LSP/formatters del
  home generado).
- Prohibido `pnpm add -g` / `npm install -g` para Claude. Si un LS/formatter
  necesitara pnpm/npm una vez, hacerlo como `coder` contra el home generado,
  nunca global del sistema, y documentarlo.

`entrypoint.sh`:

- `CLAUDE_DOCKERIZED_WORKDIR="${CLAUDE_DOCKERIZED_WORKDIR:-$PWD}"`,
  `HOME=/home/coder`, `USER=coder`, `PATH=/home/coder/.local/bin:$PATH`,
  `NVM_DIR`, `gpgconf --launch keyboxd` cuando `GNUPGHOME` set,
  `exec bash -c 'source nvm… cd WORKDIR exec "$@"'`. Sin privilegios.
- **No** setear `CLAUDE_CONFIG_DIR` (el home generado ya es `/home/coder`; no
  romper el keying de Keychain/credentials).

---

## 6. Estado persistente y capa de seguridad (100% nativa)

### 6.1 Árbol host (todo en `CCODE_HOME`) + montajes finos opción A

```
~/.config/claude-dockerized/
│   config                  ← INI wrapper (setting.*/mount.*) — mismo formato, nuevos settings §7
│   env                     ← secrets dotenv 600 (docker --env-file, nunca montado)
│   settings.template.json  ← plantilla permissions+sandbox+hooks+env.DISABLE_AUTOUPDATER (user-level)
│   hooks/
│   │   claude-guard-bash.sh   ← PreToolUse matcher Bash
│   │   claude-guard-file.sh   ← PreToolUse matcher Read/Edit/Write/Glob/Grep
│   │   GUARD_VERSION            ← entero (ej. 1)
│   ├── policies/*.json + VERSION ← vendored, sin cambios de formato
│   ├── CLAUDE.md               ← reglas gestionadas canónicas
│
└── home/                        ← espejo /home/coder, montado por piezas (opción A)
    ├── .claude/settings.json       ← GENERADO ro — NO editar a mano
    ├── .claude/hooks-guard/*.sh    ← ro (scripts seguridad)
    ├── .claude/.credentials.json   ← rw 0600 (auth)
    ├── .claude/plugins/            ← rw (usuario)
    ├── .claude/skills agents/ commands/ ← rw (seed vacío)
    ├── .claude/.lsp.json           ← rw (LSP custom usuario, §6.5)
    ├── .claude.json                ← rw (MCP user-scope + estado)
    ├── .local/bin/                 ← rw (binarios LSP/formatters instalados por wrapper, §6.5; en PATH)
    ├── .local/share/claude/        ← rw (sesiones, transcripts)
    ├── .local/state/claude/        ← rw (historial, locks)
    ├── .cache/claude/              ← rw (cachés)
    ├── .mcp-auth/ (bajo $HOME, igual que hoy) ← rw
    └── .gnupg/ (espejo público)    ← rw solo con gpg_support
```

Tabla de montajes (opción A, cerrada — prohibido montar `~/.claude/` entero):

| Host (`CCODE_HOME/home/…`) | Contenedor | Modo | Propósito |
|---|---|---|---|
| `$PROJECT_DIR` | `$PROJECT_DIR` sin `$HOME` | rw | proyecto |
| `.claude/settings.json` | `/home/coder/.claude/settings.json` | ro | config gestionada (permissions+hooks+sandbox+`DISABLE_AUTOUPDATER`) |
| `.claude/hooks-guard/` | `/home/coder/.claude/hooks-guard/` | ro | scripts seguridad |
| `.claude/.credentials.json` | `/home/coder/.claude/.credentials.json` | rw | auth (asegurar `0600`, crear si falta) |
| `.claude/plugins/` `skills/` `agents/` `commands/` `.lsp.json` | mismas rutas | rw | plugins/LSP usuario |
| `.claude.json` | `/home/coder/.claude.json` | rw | MCP user-scope |
| `.local/bin/` | `/home/coder/.local/bin/` | rw | binarios LSP/formatters del home generado |
| `.local/share|state/claude/` `.cache/claude/` | mismas | rw | sesiones/historial/caché |
| `~/.mcp-auth/` | `/home/coder/.mcp-auth/` | rw | OAuth `mcp-remote` |
| `~/.config/claude-dockerized/home/.gnupg/` | `/home/coder/.gnupg/` | rw opt-in | espejo público + socket (nunca `private-keys-v1.d`) |
| (SSH) `$SSH_AUTH_SOCK` + `~/.ssh/config` `known_hosts` | mismas | mount/env + ro | git SSH sin llaves privadas |
| (`setting.docker_socket=true` solo) `/var/run/docker.sock` | `/var/run/docker.sock` | rw opt-in | root-equivalent, documentado |

`CONFIG_DIR` nunca se monta. `env` nunca se monta. `check`/`sync` verifican
whitelist de hermanos (actualizar el test que antes prohibía todo
`:/home/coder/.claude/`).

### 6.2 `settings.json` gestionado (plantilla, con anti-autoupdate)

Generar en host (`ensure_claude_managed_config`), merge `template-wins` con
`jq`/`node` (JSON real, no `awk`):

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "env": {"DISABLE_AUTOUPDATER": "1"},
  "permissions": {
    "allow": ["Bash(mkdir *)", "Bash(ls *)"],
    "ask": ["Bash(git push *)", "Bash(git reset --hard *)", "Bash(docker system prune *)"],
    "deny": [
      "Read(./.env)", "Read(./.env.*)", "Read(./*.pem)", "Read(./*.key)",
      "Read(./auth.json)", "Read(./credentials*)", "Read(./**/.ssh/**)",
      "Read(./**/private-keys-v1.d/**)",
      "Bash(sudo *)", "Bash(rm -rf /*)", "Bash(mkfs *)", "Bash(dd *)",
      "Bash(shutdown *)", "Bash(reboot *)", "Bash(docker * --privileged *)",
      "Bash(docker * -v /:/ *)", "Bash(curl *169.254.169.254*)"
    ],
    "disableBypassPermissionsMode": "disable"
  },
  "sandbox": {"enabled": true, "filesystem": {"allowWrite": ["/tmp/claude"]}},
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "/home/coder/.claude/hooks-guard/claude-guard-bash.sh"}]},
      {"matcher": "Read|Edit|Write|Glob|Grep", "hooks": [{"type": "command", "command": "/home/coder/.claude/hooks-guard/claude-guard-file.sh"}]}
    ]
  },
  "cleanupPeriodDays": 7
}
```

- `allowManagedPermissionRulesOnly` y `managed-mcp.json` **no** por defecto.
- Validar con `json_valid` antes de mover; `validate_claude_config` aborta con
  secretos literales. `sync --check` exige `DISABLE_AUTOUPDATER=1` y `doctor`
  lo confirma vía `claude doctor`.

### 6.3 Hooks de seguridad (port 1:1 de la batería `DENY_*`, modos intactos)

`claude-guard-bash.sh` (`matcher: Bash`): stdin JSON → `.tool_input.command` →
`normalizeShell` → allowlist (con veto `[;&|\n\r]`) → vendored
(`UNSAFE+INJECTION` filtrados por `CLAUDE_DOCKERIZED_POLICY`
`strict|balanced|none`; `none` = alias de `off`, skip vendored) first-match →
`DENY_BASH` + `DENY_SECRET_PATH` (sudo, `rm -rf /|/*|/..`, `mkfs/dd/shutdown`,
`chmod 777 /|/*|/..`, `chown /`, `>/dev/sd*`, `/proc/*/environ`, metadata-IP
literal+decimal+hex+octal, `docker -v /:/ --volume /:/ --mount source=/
--privileged`, `SECRET_PATH_RE`, `leakOf/leakReadOf` `.pem/.key/KEY_FILE/BARE_KEY`,
`source/.`, `<`, `openssl -in/-inkey/-text`, `ssh-keygen -y -f`, git-plumbing N4,
renamed-extractors N5, `private-keys-v1.d`, `gpg --export-secret*`, bare-dumps
+ `-p/-x/compgen`, `printenv *KEY|SECRET|TOKEN|…`, dumps intérpretes N1,
`ssh-add -DdxXe`, `gpgconf --kill/--reload`, `.env` no-`.example`) →
`echo … >&2; exit 2`, si no `exit 0`.

`claude-guard-file.sh` (`matcher: Read|Edit|Write|Glob|Grep`): `file_path ||
path || pattern` → `DENY_READ` sobre literal + `realpath` →
`Edit|Write` confinados a roots (`$CLAUDE_PROJECT_DIR`/cwd + `/tmp/claude`,
nunca `/`; normalizar `..`; `realpath` target + padre) → `exit 2` si fuera.

Cabecera `CLAUDE_DOCKERIZED_GUARD_VERSION=N`, `+x`, `bash -n` + `shellcheck`,
harness stdin-JSON en tests. `PostToolUse` audit opcional non-blocking a
`/tmp/claude/audit.log`. `doctor`: hooks presentes + `+x`, `jq`, `POLICY`
efectivo, `disableAllHooks` ausente.

### 6.4 `CLAUDE.md` gestionado + manejo remoto por defecto (§0.8)

Port de la regla actual con: scratch `/tmp/claude`, `setting.env_file`,
`{env:VAR}`/`apiKeyHelper`, `apt-get` bloqueado → `uv`, no tocar socket
directo, no `disableAllHooks:true`, MCP/plugins host-only, `/status|/sandbox`
para confirmar carga. Añadir sección **"Manejo remoto (siempre permitido)"**:
git SSH, MCP `http/sse` remotos, endpoints/API remotos y OAuth funcionan en
`strict/balanced/none`; lo que se bloquea en los 3 modos es destrucción
(`rm -rf /|/*|~|..`), exfiltración, secretos y escapes Docker — nunca el hecho
de operar contra un remoto. Los tests deben incluir casos remote-allow en los
3 modos (ej. `git clone git@github.com:…`, `curl https://registry.npmjs.org/…`,
MCP `https://…/mcp`) junto a los deny.

### 6.5 LSP y formatters nativos en el home generado (§0.6)

Nuevos settings (todos bajo `CONFIG_DIR`, con efecto en `CCODE_HOME`):

```ini
setting.lsp=true|false            # default false; instala/activa LS
setting.lsp_servers=go,ts,python,rust  # csv; default según spike (propuesto: ts,python)
setting.formatters=true|false     # default false; instala/activa formatters + enabledPlugins
```

Diseño:

- Binarios en `CCODE_HOME/home/.local/bin/` (rw, en PATH del contenedor):
  instalados por `ensure_lsp_formatters` en host (o en primer `run` si hay red)
  con `uv tool install ruff` / `go install golang.org/x/tools/gopls@latest` /
  `npm`-free: preferir binarios estáticos o `uvx`/`npx --yes` solo como runner
  efímero si el LS lo permite; **nunca** global del sistema ni en la imagen
  (separación host/container + slim).
- `.lsp.json` generado en `CCODE_HOME/home/.claude/.lsp.json` (rw) a partir de
  `setting.lsp_servers` (plantilla por lenguaje con `command` apuntando a
  `/home/coder/.local/bin/<ls>`). Plugins prebuilt TS/Python/Rust como
  `enabledPlugins` cuando el spike los confirme.
- Formatters: `enabledPlugins` en el `settings.json` generado + binarios
  (`prettier`, `ruff format`, …) en el mismo `.local/bin`. `doctor` lista
  `command -v <ls|formatter>` y el tab Errors de `/plugin`.
- Todo sobrevive a `rm` contenedor y a rebuild de imagen (vive en host).
  `sync` los repara sin tocar versiones fijadas salvo `update`.
  Tests E2E: round-trip editar→LSP sin `Executable not found in $PATH` y
  formatter idempotente tras rebuild.

---

## 7. Wrapper `bin/claude-dockerized`

Esqueleto heredado (`check_docker/check_not_root`, `parse_config`, `build_*`,
`DRY_RUN`, traps relay, `TMPDIR=/tmp/claude`). Sin `PRIVATE_SERVER_SCRIPT`.

| Comando | Implementación Claude | Notas |
|---|---|---|
| `run [DIR]` | `claude` interactivo (`--workdir` + `-e CLAUDE_DOCKERIZED_WORKDIR`), `tty -it`, nombre `claude-<dir>-<rand>` | Sin `--standalone` |
| `auth` | `claude auth login` (documentar `setup-token` alternativo) | rw; `doctor` verifica `.credentials.json 0600` |
| `models [DIR]` | flags reales según spike (`--model`/`/model`/`config list`) | Spike fija; no inventar |
| `exec MSG` | `claude -p "MSG" [--output-format …] [--model …]` | misma firma |
| `mcp [ARGS]` | `claude mcp [list\|get\|login\|logout]`; `add/remove` → guard host-only | Mensajes exclusive-control documentados |
| `plugin [ARGS]` | `claude plugin [list\|…]`; `install/update/remove` → host-only | `--scope` solo host |
| `stats` | `claude usage` o equivalente real; fallback tamaño `share/claude` + `cleanupPeriodDays` | Spike fija |
| `debug [paths\|config\|agents]` | `claude --debug`, `config list`, `/status`, `/plugin` Errors, `/sandbox` | sin servidor |
| `doctor` | guard + `jq`, SSH (`ssh-add -l`), GPG (socket+keyring+`list-keys`+sign probe), secretos inline, `env-file`, `model`, `claude --version` + `Auto-updates: disabled`, LSP/formatters `command -v` | lógica SSH/GPG intacta, rutas nuevas |
| `install/upgrade/update/version/config/clean/help/uninstall` | Idénticos renombrados (`WRAPPER_VERSION 0.1.0`, `IMAGE_NAME=claude-dockerized:latest`, `CONFIG_DIR=~/.config/claude-dockerized`, `CCODE_HOME`) | `upgrade/update` usan `CLAUDE_BUILD_TIME` + `--build-arg CLAUDE_CODE_VERSION`; `version` = wrapper + guard + `claude --version` |
| `config claude path\|edit` (+ `credentials path` solo-print) | edita `CCODE_HOME/home/.claude/settings.json` fuente o plantilla según diseño final | `sync [--check]` cubre guard+policies+`settings.json`+`CLAUDE.md`+mirror+`.lsp.json`+`DISABLE_AUTOUPDATER` |

`setting.*` final:

- Heredados sin cambios: `ssh_agent_support`, `gpg_agent_support`,
  `gpg_allow_main_socket`, `gpg_autostart_agent`, `gpg_relay`, `docker_socket`,
  `security_policy=strict|balanced|none` (`off` alias aceptado, normalizado a
  `none`), `memory`, `cpus`, `env_file`, `network`.
- Eliminados: `websearch_provider`, `theme` (migración los avisa).
- Nuevos: `model` (`^[a-z0-9._-]+$`), `cleanup_days` (entero →
  `cleanupPeriodDays`), `lsp`, `lsp_servers`, `formatters` (§6.5).
- `mount.*` sin cambios (ro default, abs path, rechazo `~/.ssh`, `~/.gnupg`,
  `~/.claude/.credentials.json` como custom).

---

## 8. SSH / GPG / Docker / Worktrees — reutilización intacta

- **SSH**: `ensure_ssh_agent_ready`, `--mount type=bind source=$SSH_AUTH_SOCK`
  + `-e SSH_AUTH_SOCK` + `config|known_hosts:ro`, rechazo `~/.ssh` custom,
  flags `CLAUDE_DOCKERIZED_SSH_AGENT`. Funciona en los 3 modos.
- **GPG**: `ensure_gpg_agent_ready/is_running`, `ensure_gpg_mirror` (solo
  público + `no-autostart`, nunca `private-keys-v1.d`), socket dedicado
  `/home/coder/.gnupg-agent/S.gpg-agent` + symlink, preferencia `extra`,
  relay `socat` en `gnupg-relay/$$`, `entrypoint keyboxd --launch`, pinentry en
  host.
- **Docker socket**: opt-in, `--group-add <gid>`, root-equivalent documentado.
- **Worktrees**: `detect_git_worktree/build_git_worktree_args` (main `.git` ro).
- **Secrets**: `setting.env_file` bajo `CONFIG_DIR`, `600`, `--env-file`,
  nunca montado, `DRY_RUN` redacta, `validate_*` aborta literales.

---

## 9. Tests, lint y CI

1. `tests/wrapper-args.test.sh` (port):
   - Nuevo: `settings.json` válido con `env.DISABLE_AUTOUPDATER=1` +
     `permissions.deny ∋ Read(./.env)` + `disableBypassPermissionsMode`,
     `hooks-guard/*.sh +x` espejados, `policies/VERSION` match, `CLAUDE.md`
     markers (`Core Workflow`, `ruff check`, `tsc --noEmit`, `cargo clippy`,
     `staticcheck`, `shellcheck`), `private-keys-v1.d` en deny, `.lsp.json` +
     `.local/bin` persistidos cuando `lsp/formatters=true`.
   - Montajes opción A: `settings.json:ro` por archivo,
     `hooks-guard/:ro`, `.credentials.json:rw 0600`, `.claude.json:rw`,
     `.local/bin:rw`, `plugins:rw`, `CONFIG_DIR` nunca montado, `env` nunca
     montado + fuera refused + missing fail. Aserción negativa: ningún mount
     `source=…/.claude target=/home/coder/.claude` entero.
   - Runtime: `--user uid:gid`, `--group-add coder`, `no-new-privileges`,
     `--cap-drop=ALL`, Dockerfile último `USER coder` + `chown/chmod g+rwX`,
     `ARG CLAUDE_CODE_VERSION=2.1.284`, instalador `claude.ai/install.sh`,
     cero `npm install -g @anthropic*`, cero `OPENCODE|OCODE|opencode` (salvo
     allowlist §1.3).
   - SSH/GPG/relay/autostart/stray/liveness: copiar bloques (renombrar a
     `CLAUDE_DOCKERIZED_*`). `settings.json` vía `json_valid`, hooks
     `bash -n` + `shellcheck`, `sync --check` no escribe, `sync` hace `.bak`.
2. `tests/claude-guard.test.mjs`:
   - Harness stdin-JSON (`tool_input.command` / `file_path`), matriz
     `strict|balanced|none` × (`Bash` hook, file hook). `off` aceptado como alias
     de `none`.
   - Copiar `alwaysDeny/alwaysAllow/devIdioms` adaptados + casos
     **remote-allow en los 3 modos** (§6.4) + LSP/formatter-allow
     (`gopls serve`, `ruff format …`, `prettier …`) en `balanced/none`.
   - Symlink-escape igual que hoy.
3. Lint: `bash -n bin/* lib/*.sh hooks/*.sh`, `shellcheck -x -S warning …`,
   `hadolint` Dockerfile, `node --check` si hay helper. `CONTRIBUTING.md` con
   paridad CI.

---

## 10. Fases de implementación

- **Fase 0 — Spike CLI (0.5–1d)**: con `Dockerfile` §5 efímero: `claude
  --version` (=`2.1.284 (Claude Code)`), `auth login` (dónde escribe),
  `mcp add/list/get/login`, `plugin install --scope …`, rutas reales
  (`settings.json/.claude.json/.credentials.json/plugins/.lsp.json`),
  flags `models/usage/debug`, `claude doctor` (línea `Auto-updates`),
  `/status|/hooks|/plugin|/sandbox`. Fijar tabla §7 + lista LS/formatters por
  defecto. Salida: apéndice al PLAN.
- **Fase 1 — Renombrado exhaustivo (1d)**: aplicar §1.3
  (`bin/claude-dockerized`, `CCODE_*`, `CLAUDE_DOCKERIZED_*`, `/tmp/claude`,
  `ccd/*`, completions, `install.sh`, `run-simple.sh`, `config.example`,
  `Dockerfile`+`entrypoint`). `grep` del §1.3 en verde (salvo allowlist).
  `DRY_RUN` humo `build/run --help`.
- **Fase 2 — Estado + settings + sync (2–3d)**: `ensure_claude_dirs/managed_config`,
  plantilla §6.2 + merge `template-wins` + `json_valid` + `validate_claude_config`,
  `CLAUDE.md`, mirror fino §6.1, `sync --check` + `check_security_layer` +
  `maybe_drift_hint` (incluye `DISABLE_AUTOUPDATER`). `config claude path|edit`.
- **Fase 3 — Hooks nativos (3–4d)**: `hooks/*.sh` §6.3 + `GUARD_VERSION` +
  `doctor` + `tests/claude-guard.test.mjs` en verde (`strict/balanced/none` +
  remote-allow).
- **Fase 4 — Comandos (1–2d)**: `run/auth/exec/mcp/plugin/debug/doctor/stats`
  sin servidor; `version/upgrade/update/clean`; `DRY_RUN` + redacción.
- **Fase 5 — SSH/GPG/Docker/worktrees/env (1d)**: re-cablear a
  `CLAUDE_DOCKERIZED_*`; `wrapper-args.test.sh` verde.
- **Fase 6 — LSP/formatters/MCP E2E (1–2d)**: `ensure_lsp_formatters` (§6.5),
  LS ejemplo sin `Executable not found`, formatter idempotente tras `rm` +
  rebuild, `mcp-remote` OAuth (`login` dentro, `add` fuera).
- **Fase 7 — Docs + migración (1d)**: `README/SECURITY/CONTRIBUTING/CLAUDE.md`,
  `policies/README` (nota vendored), mig `opencode-dockerized →
  `claude-dockerized` (copia `env`+`config` con aviso `websearch/theme`
  deprecados, credenciales solo `0600` explícito). Bump `WRAPPER_VERSION 0.1.0`,
  `GUARD_VERSION 1`.

Estimación: **~2 semanas** 1 persona (E2E en Linux + Docker).

---

## 11. Criterios de aceptación (vinculantes)

- [ ] `install --yes` + `build` + `auth` + `run` desde checkout limpio;
  PATH/aliases/completions idempotentes; nada en `~/.local/bin`.
- [ ] `Dockerfile`: `FROM debian:trixie-slim`, `ARG CLAUDE_CODE_VERSION=2.1.284`,
  install `claude.ai/install.sh | bash -s 2.1.284`, `claude --version` OK,
  NVM `--lts` + `uv` OK, cero `npm install -g`, cero `OPENCODE|OCODE|opencode`
  (salvo allowlist §1.3).
- [ ] `settings.json` efectivo contiene `env.DISABLE_AUTOUPDATER=1`;
  `claude doctor` muestra `Auto-updates: disabled`; `sync --check` lo exige.
- [ ] Tras `rm` + rebuild sobreviven: login, settings custom merge, MCP + OAuth,
  plugins, `.lsp.json` + binarios `.local/bin`, sesiones/historial. Todo bajo
  `CCODE_HOME`; XDG host intacto.
- [ ] `config sync --check` detecta drift (guard, policies, settings, mirror,
  `.lsp.json`, `DISABLE_AUTOUPDATER`); `sync` repara con `.bak`; `--check` no
  escribe.
- [ ] `wrapper-args.test.sh` + `claude-guard.test.mjs` + `shellcheck/hadolint/
  bash -n` verdes.
- [ ] `doctor` OK con SSH+GPG (socket+keyring+sign probe), LSP/formatters
  presentes cuando activos, sin secretos inline, `disableAllHooks` ausente.
- [ ] Guard en `strict/balanced/none`: bloquea batería `alwaysDeny` y permite
  `alwaysAllow`; `devIdioms` solo en `strict`; **remote-allow** (git SSH, MCP
  `https`, registry) permitido en los 3 modos.
- [ ] `DRY_RUN=true` no crea contenedor, un flag por línea, redacta secretos.
- [ ] `SECURITY.md` con deltas Claude (protected paths,
  `disableBypassPermissionsMode`, `.credentials.json 0600`,
  `managed-mcp.json`, `sandbox` 2ª capa, no-autoupdate, LSP en home).

## 12. Riesgos conocidos

- Bind por archivo de `.credentials.json` con rewrite atómico → si queda stale,
  fallback documentado: pre-crear + `ensure` con `0600`, y si el spike lo exige,
  bind del archivo + test E2E de `auth` round-trip (no montar `~/.claude/`
  entero en ningún caso).
- `disableAllHooks:true` en proyecto desactiva 2ª capa → `sync --check`+`doctor`
  lo denuncian; 1ª capa (`deny` ro) + Docker siguen. Solo enterprise valoraría
  `allowManagedPermissionRulesOnly`.
- Vendored heurístico (falsos ± heredados); documentado.
- GPG tmpfs + sin `socat` → skip con warning; `clean` purga relays.
- Divergencia CLI (`models/usage/debug`) → Fase 0 fija, no adivinar.

## 13. Referencias

- `code.claude.com/docs/en/setup#install-a-specific-version` (pinning
  `bash -s 2.1.284`, canales `latest|stable`, `claude --version`) y
  `code.claude.com/docs/en/setup#disable-auto-updates`
  (`env.DISABLE_AUTOUPDATER=1`, `claude doctor`, `DISABLE_UPDATES`,
  `FORCE_AUTOUPDATE_PLUGINS`).
- `…/self-hosted-environments-deploy` (runner + fleet pinning),
  `…/agent-sdk/secure-deployment`, `…/sandbox-environments`, `…/sandboxing`,
  `…/settings` + `…/settings-example`, `…/server-managed-settings` +
  `…/managed-mcp`, `…/mcp`, `…/plugins` + `…/plugins-reference`,
  `…/tools-reference`, `…/hooks-guide` + `…/sub-agents`, `…/authentication` +
  `…/env-vars` + `…/llm-gateway-connect`, `…/whats-new/*`.
- Legado: `README.md`, `SECURITY.md`, `Dockerfile`, `entrypoint.sh`,
  `bin/opencode-dockerized`, `lib/config-lib.sh`, `lib/install-lib.sh`,
  `plugins/security-guard.js`, `policies/*`, `tests/*`.

---
*Fin del PLAN rev.2. Esperando nuevas instrucciones antes de implementar.*
