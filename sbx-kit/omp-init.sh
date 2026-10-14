#!/usr/bin/env bash
# omp-init.sh - the image entrypoint: finish setup, then exec omp.
#
# Anything omp reads at load time is wired up here. The spec.yaml startup
# hook runs in parallel with omp itself and can lose that race.
set -euo pipefail

# ── Workspace-local agent state ──────────────────────────────────────────────
# PI_CODING_AGENT_DIR (set in spec.yaml) redirects every agent artifact -
# agent.db, history.db, models.yml, sessions, memories, managed-skills - into
# <workspace>/.omp-agent, so state persists on the host through the workspace
# mount alone. The harness resolves the override unconditionally (DirResolver
# in pi-utils/src/dirs.ts), before its .env handling; no migration step.
#
# Not .omp: the harness treats a .omp directory in the workdir as the
# project-config root (RULES.md, mcp.json, extension roots), and sessions
# landing there would read back as project config.
OMP_AGENT_DIR="/home/agent/workspace/.omp-agent"
mkdir -p "$OMP_AGENT_DIR"

# Keep the state dir out of commits without touching the project's .gitignore:
# info/exclude is local to this clone, so the kit can append freely.
if [ -d "/home/agent/workspace/.git" ] && [ -w "/home/agent/workspace/.git/info" ]; then
  grep -qs '^\.omp-agent/$' /home/agent/workspace/.git/info/exclude 2>/dev/null || \
    echo '.omp-agent/' >> /home/agent/workspace/.git/info/exclude
fi

# ── .env parsing ─────────────────────────────────────────────────────────────
# Shared by the opt-in blocks below. Reads the project .env at the host path,
# not /home/agent/workspace: the symlink to it belongs to the startup hook,
# which has not necessarily run yet.
env_value() {
  local key="$1" file="$2" val
  val="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$file" | head -1)"
  val="${val%$'\r'}"
  val="${val%\"}"; val="${val#\"}"
  val="${val%\'}"; val="${val#\'}"
  printf '%s' "$val"
}

# Flags this script adds ahead of the caller's own, e.g. --extension.
OMP_ARGS=()

WORKSPACE_ENV="${WORKSPACE_DIR:-/home/agent/workspace}/.env"

# ── MCP gateway (opt-in) ────────────────────────────────────────────────────
# sbx serves the host's MCP registry to this sandbox over a gateway and injects
# its URL. Register the servers on the host first, with omp-sbx-mcp-import.
#
# A project opts in with OMP_SBX_MCP_GATEWAY=1 in its .env. Off by default: a
# gateway with nothing attached still hands omp the meta-tools that register
# more servers, which is not a choice to make on every project's behalf.
#
# The server definition goes in a --plugin-dir root rather than an mcp.json.
# omp looks for mcp.json in its config dir and the workspace, and both are host
# mounts here, so writing one would leave a URL in the host config that only
# resolves inside a sandbox. A plugin root is read from wherever it points.
MCP_GATEWAY_OPT=""
if [ -f "$WORKSPACE_ENV" ]; then
  MCP_GATEWAY_OPT="$(env_value OMP_SBX_MCP_GATEWAY "$WORKSPACE_ENV")"
fi

case "$MCP_GATEWAY_OPT" in
  1|true|on|yes)
    if [ -z "${MCP_GATEWAY_URL:-}" ]; then
      echo "omp-sbx: OMP_SBX_MCP_GATEWAY is set but this sandbox has no MCP gateway" >&2
    else
      # Rewritten every launch, so a sandbox that comes back with a different
      # gateway URL picks it up.
      #
      # The manifest is a bare plugin.json for its name alone, which becomes the
      # tool prefix: mcp__sbx_gateway_<tool>. omp reads the name from here or the
      # directory basename, and nowhere else. It reads the servers from .mcp.json
      # once no manifest declares an mcpServers pointer, so the two stay apart.
      MCP_PLUGIN_DIR="$HOME/.cache/omp-sbx/plugins/sbx"
      mkdir -p "$MCP_PLUGIN_DIR"
      printf '{"name":"sbx","version":"local"}\n' >"$MCP_PLUGIN_DIR/plugin.json"
      printf '{"mcpServers":{"gateway":{"type":"http","url":"%s"}}}\n' "$MCP_GATEWAY_URL" \
        >"$MCP_PLUGIN_DIR/.mcp.json"
      OMP_ARGS+=(--plugin-dir "$MCP_PLUGIN_DIR")
    fi
    ;;
esac

# The startup hook turns this path into a symlink to the host workspace, so
# enter it here rather than declaring it as the image WORKDIR - sbx's own
# setup execs run before the hook and would fail on a moving path.
cd /home/agent/workspace
exec omp "${OMP_ARGS[@]}" "$@"
