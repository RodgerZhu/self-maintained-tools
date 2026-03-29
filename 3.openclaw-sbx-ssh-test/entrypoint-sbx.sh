#!/usr/bin/env bash
# entrypoint-sbx.sh — OpenClaw Gateway sandbox-mode container entrypoint
#
# Execution order:
#   Phase 1 (root)  : Fix named-volume ownership so 'node' user can write.
#   Phase 2 (root)  : First-boot config initialization via 'node dist/index.js config set'.
#                     Skipped on subsequent starts (config file already present).
#   Phase 3 (node)  : exec gateway via gosu — drops root privileges permanently.
#
# This script is the ENTRYPOINT of Dockerfile.sbx and runs as root (USER root
# in the Dockerfile).  It never leaves root running after exec gosu.

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

run_as_node() {
  # Run a command as the 'node' user (uid 1000) so files written to the
  # named config volume are owned by node, not root.
  gosu node "$@"
}

# ---------------------------------------------------------------------------
# Phase 1: Fix named-volume ownership
#
# Docker creates named volumes as root:root on first use.  The gateway
# process runs as 'node' (uid 1000) and needs write access to both volumes.
# -xdev prevents chown from crossing the workspace mount boundary.
# The workspace .openclaw/ metadata subdirectory is handled separately
# because it lives in a different mount and -xdev would skip it.
# ---------------------------------------------------------------------------

log "Fixing volume ownership"
find /home/node/.openclaw -xdev -exec chown node:node {} + 2>/dev/null || true
if [[ -d /home/node/.openclaw/workspace/.openclaw ]]; then
  chown -R node:node /home/node/.openclaw/workspace/.openclaw 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Fix SSH key permissions
#
# The host ~/.ssh directory is bind-mounted read-only at /run/ssh-keys.
# We copy the needed key files into the writable /home/node/.ssh/ and set
# correct ownership + permissions so the 'node' user can read them.
# ---------------------------------------------------------------------------

if [[ -d /run/ssh-keys ]]; then
  mkdir -p /home/node/.ssh
  cp -a /run/ssh-keys/. /home/node/.ssh/
  chown -R node:node /home/node/.ssh
  chmod 700 /home/node/.ssh
  find /home/node/.ssh -type f \( -name 'id_*' ! -name '*.pub' \) -exec chmod 600 {} +
  log "SSH keys copied from /run/ssh-keys to /home/node/.ssh with correct permissions"
fi

# ---------------------------------------------------------------------------
# Phase 2: First-boot config initialization
#
# The config named volume starts empty.  We detect first boot by checking
# for the main config file.  If absent, we write all required settings via
# the openclaw CLI before starting the gateway.
#
# Settings written:
#   gateway.mode                                       = local
#   gateway.bind                                       = $OPENCLAW_GATEWAY_BIND (default: lan)
#   agents.defaults.sandbox.mode                       = $OPENCLAW_SANDBOX_MODE (default: all)
#   agents.defaults.sandbox.scope                      = session
#   agents.defaults.sandbox.workspaceAccess            = $OPENCLAW_WORKSPACE_ACCESS (default: rw)
#   agents.defaults.sandbox.backend                    = ssh
#   agents.defaults.sandbox.ssh.target                 = $OPENCLAW_SSH_TARGET (required)
#   agents.defaults.sandbox.ssh.identityFile           = $OPENCLAW_SSH_IDENTITY_FILE (default: ~/.ssh/id_ed25519)
#   agents.defaults.sandbox.ssh.workspaceRoot          = $OPENCLAW_SSH_WORKSPACE_ROOT (default: /tmp/openclaw-sandboxes)
#   agents.defaults.sandbox.ssh.strictHostKeyChecking  = false
#   agents.defaults.sandbox.ssh.updateHostKeys         = false
#   gateway.controlUi.allowedOrigins                   = localhost + 127.0.0.1 (non-loopback only)
# ---------------------------------------------------------------------------

# Use a marker file (not openclaw.json) to detect first-boot completion.
# openclaw.json is created during config set writes, so using it as the
# gate means a restart after a partial failure would skip sandbox setup.
# The marker file is only written after ALL config steps succeed.
INIT_MARKER="/home/node/.openclaw/.sbx-initialized"

if [[ ! -f "$INIT_MARKER" ]]; then
  log "First boot — initializing OpenClaw config (SSH sandbox mode)"

  # ---- Validate SSH target ----
  if [[ -z "${OPENCLAW_SSH_TARGET:-}" ]]; then
    echo "ERROR: OPENCLAW_SSH_TARGET is required for SSH sandbox mode." >&2
    echo "       Example: -e OPENCLAW_SSH_TARGET=user@host:22" >&2
    exit 1
  fi

  # Seed required directory structure in the config volume.
  # The gateway creates these on startup, but doing it here ensures config set
  # commands succeed even if the gateway has never run before.
  run_as_node mkdir -p \
    /home/node/.openclaw/identity \
    /home/node/.openclaw/agents/main/agent \
    /home/node/.openclaw/agents/main/sessions

  # ---- Token handling ----
  # If OPENCLAW_GATEWAY_TOKEN is not provided at runtime, generate one here.
  # The generated token is printed clearly — this is the only time it appears.
  # On subsequent boots the token is persisted in the config volume and read
  # by the gateway from $OPENCLAW_GATEWAY_TOKEN or the config file.
  if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
    if command -v openssl >/dev/null 2>&1; then
      OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)"
    else
      OPENCLAW_GATEWAY_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
    fi
    echo ""
    echo "  ┌────────────────────────────────────────────────────────────────┐"
    echo "  │  Gateway token (auto-generated — save this, shown once only):  │"
    echo "  │  $OPENCLAW_GATEWAY_TOKEN  │"
    echo "  └────────────────────────────────────────────────────────────────┘"
    echo ""
  fi
  export OPENCLAW_GATEWAY_TOKEN

  # ---- Write config ----
  # All config writes run as node so the resulting files are owned by node.
  run_as_node node /app/dist/index.js config set gateway.mode local
  run_as_node node /app/dist/index.js config set \
    gateway.bind "${OPENCLAW_GATEWAY_BIND:-lan}"

  # Sandbox policy — four mandatory fields.
  # OPENCLAW_SANDBOX_MODE controls when sandboxing applies:
  #   all      — every session runs skills in a sibling container (default, most isolated)
  #   non-main — only channel/automation sessions sandboxed; main chat runs in gateway
  # If any write fails, abort before the gateway starts to prevent docker.sock
  # from being reachable with an incomplete sandbox policy.
  sandbox_ok=true
  run_as_node node /app/dist/index.js config set \
    agents.defaults.sandbox.mode "${OPENCLAW_SANDBOX_MODE:-all}"  || sandbox_ok=false
  run_as_node node /app/dist/index.js config set \
    agents.defaults.sandbox.scope "session"                       || sandbox_ok=false
  run_as_node node /app/dist/index.js config set \
    agents.defaults.sandbox.workspaceAccess "${OPENCLAW_WORKSPACE_ACCESS:-rw}" || sandbox_ok=false
  run_as_node node /app/dist/index.js config set \
    agents.defaults.sandbox.backend "ssh"                         || sandbox_ok=false

  # SSH-specific configuration.
  run_as_node node /app/dist/index.js config set \
    agents.defaults.sandbox.ssh.target "${OPENCLAW_SSH_TARGET}"  || sandbox_ok=false
  run_as_node node /app/dist/index.js config set \
    agents.defaults.sandbox.ssh.identityFile \
    "${OPENCLAW_SSH_IDENTITY_FILE:-/home/node/.ssh/id_ed25519}"   || sandbox_ok=false
  run_as_node node /app/dist/index.js config set \
    agents.defaults.sandbox.ssh.workspaceRoot \
    "${OPENCLAW_SSH_WORKSPACE_ROOT:-/tmp/openclaw-sandboxes}"     || sandbox_ok=false
  run_as_node node /app/dist/index.js config set \
    agents.defaults.sandbox.ssh.strictHostKeyChecking false --strict-json || sandbox_ok=false
  run_as_node node /app/dist/index.js config set \
    agents.defaults.sandbox.ssh.updateHostKeys false --strict-json        || sandbox_ok=false

  if [[ "$sandbox_ok" != true ]]; then
    echo "ERROR: Sandbox config write failed. Gateway NOT started." >&2
    echo "       Marker file NOT written — next restart will retry init." >&2
    exit 1
  fi

  # Non-loopback bind: whitelist localhost origins for the control UI so
  # browser clients are not rejected by the CORS check.
  if [[ "${OPENCLAW_GATEWAY_BIND:-lan}" != "loopback" ]]; then
    port="${OPENCLAW_GATEWAY_PORT:-18789}"
    origins="[\"http://localhost:${port}\",\"http://127.0.0.1:${port}\"]"
    run_as_node node /app/dist/index.js config set \
      gateway.controlUi.allowedOrigins "$origins" --strict-json 2>/dev/null || true
  fi

  # Write marker ONLY after all config steps succeed.
  # If any step above failed we would have exited before reaching here.
  run_as_node touch "$INIT_MARKER"
  log "Sandbox config written: mode=${OPENCLAW_SANDBOX_MODE:-all}, scope=session, workspaceAccess=${OPENCLAW_WORKSPACE_ACCESS:-rw}, backend=ssh, target=${OPENCLAW_SSH_TARGET}"
fi

# ---------------------------------------------------------------------------
# Phase 3: Start gateway (drop to node via gosu)
#
# exec replaces this root shell — no root process remains after this point.
# ---------------------------------------------------------------------------

log "Starting gateway (bind=${OPENCLAW_GATEWAY_BIND:-lan}, port=${OPENCLAW_GATEWAY_PORT:-18789}, sandbox=ssh)"

exec gosu node node /app/dist/index.js gateway \
  --bind  "${OPENCLAW_GATEWAY_BIND:-lan}" \
  --port  "${OPENCLAW_GATEWAY_PORT:-18789}"
