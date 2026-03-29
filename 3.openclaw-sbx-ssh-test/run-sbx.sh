#!/usr/bin/env bash
# run-sbx.sh — Build and run openclaw-sbx-ssh via plain docker run (no Compose)
#
# Usage:
#   ./run-sbx.sh --ssh-target USER@HOST:PORT [--ssh-key PATH]
#                [--ssh-workspace-root PATH] [--ssh-key-dir PATH]
#                [--build] [--token TOKEN] [--port PORT]
#                [--bind BIND] [--name NAME] [--no-start]
#
# Options:
#   --ssh-target TARGET  SSH target in user@host:port format. REQUIRED.
#   --ssh-key PATH       Host path to SSH private key (default: ~/.ssh/id_ed25519).
#   --ssh-workspace-root Remote path for sandbox workspaces (default: /tmp/openclaw-sandboxes).
#   --ssh-key-dir PATH   Host SSH key directory bind-mounted read-only (default: ~/.ssh).
#   --build              Force rebuild of the openclaw-sbx-ssh:latest image before run.
#   --token TOKEN        Gateway auth token. Generated and printed if omitted.
#   --port PORT          Host port for gateway (default: 18789).
#   --bind BIND          Gateway bind mode: lan | loopback (default: lan).
#   --name NAME          Container name (default: openclaw-gateway-ssh).
#   --no-start           Only build the image; do not start the container.
#
# Prerequisites:
#   - Docker daemon running and accessible
#   - SSH key pair with public key authorized on the remote SSH target
#     (password auth is NOT supported — SSH sandbox uses BatchMode=yes)
#   - Remote target has standard tools: sh, mkdir, tar, rm, find
#
# Named volumes used (no host paths exposed):
#   openclaw-config     →  /home/node/.openclaw           (gateway config)
#   openclaw-workspace  →  /home/node/.openclaw/workspace (user workspace)
#
# SSH key bind mount (read-only):
#   ~/.ssh  →  /home/node/.ssh:ro
#
# To remove all persisted data:
#   docker volume rm openclaw-config openclaw-workspace

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="openclaw-sbx-ssh:latest"
CONTAINER_NAME="openclaw-gateway-ssh"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
BRIDGE_PORT="${OPENCLAW_BRIDGE_PORT:-18790}"
GATEWAY_BIND="${OPENCLAW_GATEWAY_BIND:-lan}"
GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
SSH_TARGET="${OPENCLAW_SSH_TARGET:-}"
SSH_KEY="${OPENCLAW_SSH_IDENTITY_FILE:-$HOME/.ssh/id_ed25519}"
SSH_WORKSPACE_ROOT="${OPENCLAW_SSH_WORKSPACE_ROOT:-/tmp/openclaw-sandboxes}"
SSH_KEY_DIR="${OPENCLAW_SSH_KEY_DIR:-$HOME/.ssh}"
DO_BUILD=0
NO_START=0
CONFIG_VOLUME="${OPENCLAW_CONFIG_VOLUME:-openclaw-config}"
WORKSPACE_VOLUME="${OPENCLAW_WORKSPACE_VOLUME:-openclaw-workspace}"

fail() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Prestart helpers — plain docker run with volumes mounted, no gateway process
#
# These functions run one-off containers to read/write the named config volume
# before the long-running gateway container starts.  Equivalent to setup.sh's
# run_prestart_cli() / run_prestart_gateway(), but without Compose.
# ---------------------------------------------------------------------------

# Run a sh -c command in the image as root, with both volumes mounted.
prestart_sh_root() {
  docker run --rm \
    --user root \
    -v "${CONFIG_VOLUME}:/home/node/.openclaw" \
    -v "${WORKSPACE_VOLUME}:/home/node/.openclaw/workspace" \
    --entrypoint sh \
    "$IMAGE" -c "$1"
}

# Run a sh -c command in the image as node, with both volumes mounted.
prestart_sh_node() {
  docker run --rm \
    --user node \
    -v "${CONFIG_VOLUME}:/home/node/.openclaw" \
    -v "${WORKSPACE_VOLUME}:/home/node/.openclaw/workspace" \
    --entrypoint sh \
    "$IMAGE" -c "$1"
}

# Run node /app/dist/index.js <subcommand> as node, non-interactively.
prestart_cli() {
  docker run --rm \
    --user node \
    -v "${CONFIG_VOLUME}:/home/node/.openclaw" \
    -v "${WORKSPACE_VOLUME}:/home/node/.openclaw/workspace" \
    ${GATEWAY_TOKEN:+-e "OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}"} \
    --entrypoint node \
    "$IMAGE" /app/dist/index.js "$@"
}

# Same as prestart_cli but with stdin + tty — for interactive prompts.
prestart_cli_interactive() {
  local tty_flag=""
  [[ -t 0 ]] && tty_flag="--tty"
  docker run --rm -i $tty_flag \
    --user node \
    -v "${CONFIG_VOLUME}:/home/node/.openclaw" \
    -v "${WORKSPACE_VOLUME}:/home/node/.openclaw/workspace" \
    ${GATEWAY_TOKEN:+-e "OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}"} \
    --entrypoint node \
    "$IMAGE" /app/dist/index.js "$@"
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)              DO_BUILD=1 ;;
    --no-start)           NO_START=1 ;;
    --token)              GATEWAY_TOKEN="${2:-}"; shift ;;
    --port)               GATEWAY_PORT="${2:-}"; shift ;;
    --bind)               GATEWAY_BIND="${2:-}"; shift ;;
    --name)               CONTAINER_NAME="${2:-}"; shift ;;
    --ssh-target)         SSH_TARGET="${2:-}"; shift ;;
    --ssh-key)            SSH_KEY="${2:-}"; shift ;;
    --ssh-workspace-root) SSH_WORKSPACE_ROOT="${2:-}"; shift ;;
    --ssh-key-dir)        SSH_KEY_DIR="${2:-}"; shift ;;
    *) fail "Unknown option: $1" ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

command -v docker >/dev/null 2>&1 || fail "docker not found."

# SSH target is mandatory
[[ -n "$SSH_TARGET" ]] || \
  fail "SSH target is required. Use --ssh-target USER@HOST:PORT or set OPENCLAW_SSH_TARGET."

# Verify SSH key directory exists
[[ -d "$SSH_KEY_DIR" ]] || \
  fail "SSH key directory not found at $SSH_KEY_DIR. Ensure your SSH keys are available."

# Container-side path for the identity file (keys are bind-mounted under /home/node/.ssh)
SSH_KEY_BASENAME="$(basename "$SSH_KEY")"
SSH_IDENTITY_FILE_CONTAINER="/home/node/.ssh/${SSH_KEY_BASENAME}"

# ---------------------------------------------------------------------------
# Build openclaw-sbx image
# ---------------------------------------------------------------------------

build_image() {
  echo ""
  echo "==> Building image: $IMAGE"
  docker build \
    -f "$ROOT_DIR/Dockerfile.sbx" \
    -t "$IMAGE" \
    "$ROOT_DIR"
  echo "==> Image built: $IMAGE"
}

# Build if forced, or if the image does not yet exist
if [[ "$DO_BUILD" -eq 1 ]]; then
  build_image
elif ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "Image $IMAGE not found locally — building..."
  build_image
fi

# Verify SSH client is present inside the image
echo ""
echo "==> Verifying SSH client inside $IMAGE"
docker run --rm --entrypoint ssh "$IMAGE" -V 2>&1 || \
  fail "SSH client not found in $IMAGE. Rebuild the image."

[[ "$NO_START" -eq 1 ]] && { echo "==> --no-start: image ready, not starting container."; exit 0; }

# ---------------------------------------------------------------------------
# Test SSH connectivity from the host
# ---------------------------------------------------------------------------

echo ""
echo "==> Testing SSH connectivity to $SSH_TARGET"
SSH_USER_HOST="${SSH_TARGET%:*}"
SSH_PORT="${SSH_TARGET##*:}"
[[ "$SSH_PORT" == "$SSH_TARGET" ]] && SSH_PORT="22"

if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
    -i "$SSH_KEY" -p "$SSH_PORT" "$SSH_USER_HOST" echo ok 2>/dev/null; then
  echo "    SSH connection successful."
else
  echo ""
  echo "WARNING: SSH connection to $SSH_TARGET failed." >&2
  echo "  Ensure:" >&2
  echo "    1. SSH key at $SSH_KEY is authorized on the remote host" >&2
  echo "    2. Remote host is reachable" >&2
  echo "    3. SSH port $SSH_PORT is open" >&2
  echo "" >&2
  echo "  To set up key-based auth:" >&2
  echo "    ssh-copy-id -i ${SSH_KEY}.pub -p $SSH_PORT $SSH_USER_HOST" >&2
  echo ""
  read -r -p "Continue anyway? [y/N] " _cont
  [[ "$_cont" =~ ^[Yy] ]] || exit 1
fi

# ---------------------------------------------------------------------------
# Interactive prestart configuration
#
# Runs only on first boot (marker file absent in the config named volume).
# All writes go directly into the named volume via one-off containers, so
# when the gateway starts it finds config already in place and the entrypoint
# skips its own init block.
# ---------------------------------------------------------------------------

INIT_MARKER="/home/node/.openclaw/.sbx-initialized"

FIRST_BOOT=0
if ! docker run --rm \
    --user node \
    -v "${CONFIG_VOLUME}:/home/node/.openclaw" \
    --entrypoint sh "$IMAGE" \
    -c "test -f ${INIT_MARKER}" 2>/dev/null; then
  FIRST_BOOT=1
fi

if [[ "$FIRST_BOOT" -eq 1 ]]; then
  echo ""
  echo "========================================"
  echo " OpenClaw Gateway — First-time Setup"
  echo "   (SSH Sandbox Mode)"
  echo "========================================"
  echo " Config volume : $CONFIG_VOLUME"
  echo " Workspace vol : $WORKSPACE_VOLUME"
  echo " SSH target    : $SSH_TARGET"
  echo " SSH key       : $SSH_KEY"
  echo " SSH workspace : $SSH_WORKSPACE_ROOT (on remote)"
  echo " Gateway bind  : $GATEWAY_BIND"
  echo " Gateway port  : $GATEWAY_PORT"
  echo ""

  # ---- Token prompt -------------------------------------------------------
  if [[ -z "$GATEWAY_TOKEN" ]]; then
    echo "Gateway auth token"
    echo "  Enter a token string, or press Enter to auto-generate one:"
    read -r _input_token
    if [[ -n "$_input_token" ]]; then
      GATEWAY_TOKEN="$_input_token"
      echo "Using provided token."
    else
      if command -v openssl >/dev/null 2>&1; then
        GATEWAY_TOKEN="$(openssl rand -hex 32)"
      else
        GATEWAY_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
      fi
      echo ""
      echo "  Auto-generated token (save this — shown once only):"
      echo "  $GATEWAY_TOKEN"
    fi
    echo ""
  fi

  # ---- Fix volume ownership -----------------------------------------------
  echo "==> Fixing volume ownership"
  prestart_sh_root \
    'find /home/node/.openclaw -xdev -exec chown node:node {} + 2>/dev/null; \
     [ -d /home/node/.openclaw/workspace/.openclaw ] && \
       chown -R node:node /home/node/.openclaw/workspace/.openclaw 2>/dev/null || true'

  # ---- Seed directory structure -------------------------------------------
  prestart_sh_node 'mkdir -p \
    /home/node/.openclaw/identity \
    /home/node/.openclaw/agents/main/agent \
    /home/node/.openclaw/agents/main/sessions'

  # ---- Interactive onboard ------------------------------------------------
  echo ""
  echo "==> Onboarding (interactive)"
  echo "    Gateway mode is pinned to 'local' for Docker deployments."
  echo "    Tailscale: configure at the host level separately."
  echo "    Daemon install: skipped — lifecycle managed by Docker."
  echo ""
  prestart_cli_interactive onboard --mode local --no-install-daemon

  # ---- Gateway defaults ---------------------------------------------------
  echo ""
  echo "==> Writing gateway defaults"
  prestart_cli config set gateway.mode  local          >/dev/null
  prestart_cli config set gateway.bind  "$GATEWAY_BIND" >/dev/null
  echo "    Pinned gateway.mode=local, gateway.bind=$GATEWAY_BIND"

  # ---- Sandbox config -----------------------------------------------------
  echo ""
  echo "==> Writing sandbox config"
  sandbox_ok=true
  prestart_cli config set agents.defaults.sandbox.mode \
    "${OPENCLAW_SANDBOX_MODE:-all}"                                          >/dev/null || sandbox_ok=false
  prestart_cli config set agents.defaults.sandbox.scope         "session"    >/dev/null || sandbox_ok=false
  prestart_cli config set agents.defaults.sandbox.workspaceAccess \
    "${OPENCLAW_WORKSPACE_ACCESS:-rw}"                                        >/dev/null || sandbox_ok=false
  prestart_cli config set agents.defaults.sandbox.backend       "ssh"        >/dev/null || sandbox_ok=false

  # SSH-specific configuration
  prestart_cli config set agents.defaults.sandbox.ssh.target \
    "$SSH_TARGET"                                                             >/dev/null || sandbox_ok=false
  prestart_cli config set agents.defaults.sandbox.ssh.identityFile \
    "$SSH_IDENTITY_FILE_CONTAINER"                                            >/dev/null || sandbox_ok=false
  prestart_cli config set agents.defaults.sandbox.ssh.workspaceRoot \
    "$SSH_WORKSPACE_ROOT"                                                     >/dev/null || sandbox_ok=false
  prestart_cli config set agents.defaults.sandbox.ssh.strictHostKeyChecking \
    false --strict-json                                                       >/dev/null || sandbox_ok=false
  prestart_cli config set agents.defaults.sandbox.ssh.updateHostKeys \
    false --strict-json                                                       >/dev/null || sandbox_ok=false

  if [[ "$sandbox_ok" != true ]]; then
    fail "Sandbox config write failed. Aborting — gateway NOT started."
  fi
  echo "    mode=${OPENCLAW_SANDBOX_MODE:-all}, scope=session, workspaceAccess=${OPENCLAW_WORKSPACE_ACCESS:-rw}, backend=ssh"
  echo "    ssh.target=$SSH_TARGET, ssh.identityFile=$SSH_IDENTITY_FILE_CONTAINER"

  # ---- Control UI allowlist (non-loopback only) ---------------------------
  if [[ "$GATEWAY_BIND" != "loopback" ]]; then
    _origins="[\"http://localhost:${GATEWAY_PORT}\",\"http://127.0.0.1:${GATEWAY_PORT}\"]"
    prestart_cli config set gateway.controlUi.allowedOrigins "$_origins" \
      --strict-json >/dev/null || true
    echo "    Set controlUi.allowedOrigins for non-loopback bind."
  fi

  # ---- Write initialization marker ----------------------------------------
  # The marker is written ONLY after all config steps succeed.
  # entrypoint-sbx.sh checks for this file and skips re-initialization.
  docker run --rm --user node \
    -v "${CONFIG_VOLUME}:/home/node/.openclaw" \
    --entrypoint sh "$IMAGE" \
    -c "touch ${INIT_MARKER}"
  echo ""
  echo "==> Configuration complete."

  # ---- Optional channel setup prompt -------------------------------------
  echo ""
  echo "==> Channel setup (optional — can be done after gateway starts)"
  echo "    WhatsApp (QR scan):"
  echo "      docker exec -it $CONTAINER_NAME node /app/dist/index.js channels login"
  echo "    Telegram (bot token):"
  echo "      docker exec -it $CONTAINER_NAME node /app/dist/index.js channels add --channel telegram --token <token>"
  echo "    Discord (bot token):"
  echo "      docker exec -it $CONTAINER_NAME node /app/dist/index.js channels add --channel discord --token <token>"
  echo "    Docs: https://docs.openclaw.ai/channels"
  echo ""
  echo "Press Enter to start the gateway, or Ctrl+C to abort."
  read -r _

else
  echo ""
  echo "==> Config volume already initialized — skipping interactive setup."
  echo "    To force re-setup: docker run --rm --user node \\"
  echo "      -v ${CONFIG_VOLUME}:/home/node/.openclaw --entrypoint sh $IMAGE \\"
  echo "      -c 'rm /home/node/.openclaw/.sbx-initialized'"
fi

# ---------------------------------------------------------------------------
# Remove existing container if present (rerun idempotency)
# ---------------------------------------------------------------------------

if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  echo ""
  echo "==> Container '$CONTAINER_NAME' already exists — removing before restart."
  docker rm -f "$CONTAINER_NAME"
fi

# ---------------------------------------------------------------------------
# Start gateway container
# ---------------------------------------------------------------------------

echo ""
echo "==> Starting container: $CONTAINER_NAME"
echo "    Image          : $IMAGE"
echo "    Config volume  : $CONFIG_VOLUME  →  /home/node/.openclaw"
echo "    Workspace vol  : $WORKSPACE_VOLUME  →  /home/node/.openclaw/workspace"
  echo "    SSH keys dir   : $SSH_KEY_DIR  →  /run/ssh-keys (read-only staging)"
  echo "    SSH target     : $SSH_TARGET"
echo "    Gateway port   : $GATEWAY_PORT"
echo "    Gateway bind   : $GATEWAY_BIND"
if [[ -n "$GATEWAY_TOKEN" ]]; then
  echo "    Token          : (provided via --token / env)"
else
  echo "    Token          : (will be auto-generated on first boot — check logs)"
fi
# Build -e token argument safely as an array so quoting is handled correctly.
# Using ${var:+word} inline in the docker run command would produce a single
# string with literal quotes rather than two separate arguments.
TOKEN_ENV_ARGS=()
[[ -n "$GATEWAY_TOKEN" ]] && TOKEN_ENV_ARGS=(-e "OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}")

echo ""

docker run \
  --detach \
  --name "$CONTAINER_NAME" \
  --init \
  --restart unless-stopped \
  -v "${CONFIG_VOLUME}:/home/node/.openclaw" \
  -v "${WORKSPACE_VOLUME}:/home/node/.openclaw/workspace" \
  -v "${SSH_KEY_DIR}:/run/ssh-keys:ro" \
  -p "${GATEWAY_PORT}:18789" \
  -p "${BRIDGE_PORT}:18790" \
  -e "OPENCLAW_GATEWAY_PORT=${GATEWAY_PORT}" \
  -e "OPENCLAW_GATEWAY_BIND=${GATEWAY_BIND}" \
  -e "OPENCLAW_SSH_TARGET=${SSH_TARGET}" \
  -e "OPENCLAW_SSH_IDENTITY_FILE=${SSH_IDENTITY_FILE_CONTAINER}" \
  -e "OPENCLAW_SSH_WORKSPACE_ROOT=${SSH_WORKSPACE_ROOT}" \
  "${TOKEN_ENV_ARGS[@]}" \
  "$IMAGE"

# ---------------------------------------------------------------------------
# Post-start summary
# ---------------------------------------------------------------------------

echo ""
echo "==> Container started: $CONTAINER_NAME"
echo ""
echo "Commands:"
echo "  docker logs -f $CONTAINER_NAME"
echo "  docker exec $CONTAINER_NAME node /app/dist/index.js health --token <token>"
echo "  docker exec $CONTAINER_NAME node /app/dist/index.js sandbox explain"
echo "  docker exec $CONTAINER_NAME node /app/dist/index.js sandbox list"
echo "  docker exec -it $CONTAINER_NAME node /app/dist/index.js channels login"
echo ""
if [[ -z "$GATEWAY_TOKEN" ]]; then
  echo "  To retrieve the auto-generated token:"
  echo "  docker logs $CONTAINER_NAME 2>&1 | grep -A1 'Gateway token'"
  echo ""
fi
echo "  To stop:  docker stop $CONTAINER_NAME"
echo "  To remove: docker rm -f $CONTAINER_NAME"
echo "  To wipe data: docker volume rm $CONFIG_VOLUME $WORKSPACE_VOLUME"
