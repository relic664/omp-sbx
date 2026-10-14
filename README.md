<p align="center">
  <img width="250" alt="Image" src="https://github.com/user-attachments/assets/c91d67e4-c6a6-46c0-a7dd-4f682cc67193" />
</p>

# omp-sbx Oh My Pi Sandbox

Run the [omp coding agent](https://omp.sh) (oh-my-pi) inside a [Docker sbx](https://docs.docker.com/ai/sandboxes/) sandbox.

## What it does

- Launches omp inside a Docker sbx microVM — sbx handles all security (non-root user, network policies, secret proxy, resource limits)
- Keeps agent state (agent.db, models.yml, sessions, memories, managed-skills) **in the workspace itself**, via `PI_CODING_AGENT_DIR=<workspace>/.omp-agent` — it persists across sandbox restarts through the workspace mount, no separate mount needed
- Provider credentials (`OPENAI_API_KEY`, optional `OPENAI_BASE_URL`) are planned to be injected at launch from the host environment — nothing logged into or stored inside the sandbox. See [docs/trimming-and-injection.md](docs/trimming-and-injection.md) for the injection plan (env at create now, sbx secret + proxy later)
- Sandboxes are per-directory: running from the same cwd reconnects to the same sandbox
- Recovers automatically after a force-quit: if the sandbox is left stopped (or its agent wedged), the launcher re-attaches, then stops+restarts, and as a last resort recreates the sandbox — your omp session resumes from the workspace state either way
- `--new` flag forces a fresh sandbox

## Prerequisites

```bash
brew install docker/tap/sbx
sbx login
sbx policy set-default balanced
```

## Install

```bash
git clone https://github.com/mikeatlas/omp-sbx.git ~/src/github.com/mikeatlas/omp-sbx
cd ~/src/github.com/mikeatlas/omp-sbx

# Build + load the template image into sbx
./build.sh

# Symlink the launcher onto your PATH
ln -sf "$PWD/omp-sbx" ~/.local/bin/omp-sbx

# Alias omp to always use the sandbox (in ~/.zshrc or ~/.bashrc)
echo "alias omp='omp-sbx'" >> ~/.zshrc
```

## Usage

```bash
omp                    # interactive TUI (cwd = workspace, state in .omp-agent)
omp --new              # destroy + create fresh sandbox
omp --yes              # skip the pre-launch "press any key" pause
omp --version          # passthrough flags to omp
omp "fix the bug"      # one-shot prompt
```

## How it works

| Component | File | Purpose |
|---|---|---|
| Template | `sbx-kit/Dockerfile` | Extends `docker/sandbox-templates:shell-nightly` with omp binary + dev tools |
| Kit | `sbx-kit/spec.yaml` | Defines omp entrypoint, network allow-list, env, agent context |
| Env (experimental) | `sbx-kit/.sbxenv.yaml` + `omp-sbxenv` | Declarative alternative launcher for scripted/CI use — see [Scripted / CI use](#scripted--ci-use-experimental) |
| Launcher | `omp-sbx` | Wrapper handling banner, sandbox lifecycle, resume vs new |
| MCP gateway | `sbx-kit/omp-init.sh` | Opt-in wiring that connects omp to the sandbox's MCP gateway |

### Config and state

Agent state (agent.db, sessions, memories, managed-skills, models.yml) lives
in `<workspace>/.omp-agent`, pointed there by `PI_CODING_AGENT_DIR` in the
kit. It persists on the host through the workspace mount and is git-excluded
locally via `.git/info/exclude` (the entrypoint appends it; your committed
`.gitignore` is untouched). Each project directory has its own state,
including its own model preferences.

A project's provider key comes from the host environment at create time
(`OPENAI_API_KEY`, `OPENAI_BASE_URL` if set). No auth storage is shared or
persisted in the sandbox. Nothing else is mounted from the host's home
directory.

### GitHub access

GitHub is reached through sbx's built-in credential proxy — no `gh` CLI in the
sandbox, and no GitHub config mounted. Register the secret once on the host:

```bash
sbx secret set github --command 'gh auth token'
```

The host daemon re-runs that command when the cached value ages out, so token
rotation needs no manual copy. The proxy injects the credential into requests
to the built-in `github` service's domains (`github.com`, `api.github.com`,
`raw.githubusercontent.com`, and the rest — see sbx's built-in services
table), and re-encodes git-over-HTTPS to Basic auth, so `git push`/`pull` over
HTTPS to github.com works with no credential helper and no SSH setup. The
token never enters the sandbox — in-container tooling sees no `GH_TOKEN` at
all.

Two consequences:

- **HTTPS remotes only.** An SSH remote (`git@github.com:…`) and non-GitHub
  forges are not covered; use an HTTPS remote.
- **GitHub API work goes through MCP servers**, not `gh`. There is no `gh`
  binary configured in the sandbox.

Verifying inside the sandbox:

```bash
git ls-remote https://github.com/<you>/<your-repo>.git   # private repo reachable
git push                                                 # 401 means no secret registered
```

If a git operation to github.com returns 401, check `sbx secret ls` — the
proxy injects nothing when the `github` service has no stored secret.

### MCP servers

sbx keeps its own MCP registry on the host and serves it to a sandbox through
a gateway. Register servers directly with `sbx mcp add` — no import tool
needed:

```bash
sbx mcp add searxng --command searxng-mcp --args "--host" --args "localhost"   # stdio, runs on the host
sbx mcp add notion --url https://mcp.notion.com/mcp --skip_auth                # remote; OAuth later
sbx mcp auth notion                                                            # opens a host browser
```

**Why the sandbox never sees a credential.** A stdio server runs on the host,
and a remote server's OAuth token stays there. The sandbox reaches the server
through the gateway URL, not the credential — a microVM has no keychain and no
browser to offer.

**Two ways to reach a sandbox, and they do not mix:**

| Route | Command | Trade |
|---|---|---|
| Live attach | `sbx mcp load searxng --sandbox omp-<dir>` | No restart; the agent also gets the gateway's `mcp-add` / `mcp-find` |
| Fixed at create | `OMP_SBX_STATIC_MCP=notion,searxng omp-sbx --new` | Set cannot change without `--new`; the agent cannot register more |

Loading into a sandbox created with `--static-mcp` misbehaves - the second load
appears to replace the first rather than add to it. Pick one route.

**Env vars for stdio servers.** `sbx mcp add` has no `--env`, so a server that
reads its config from the environment gets wrapped: `sbx mcp add myserver
--command env --args "API_KEY=..." --args myserver`. The value stays on the
host; the server runs there and the sandbox reaches it through the gateway.

#### Letting omp see them

Registering and attaching gets the servers onto the sandbox's gateway. omp still
has to connect to it, which a project turns on with one line in its `.env`:

```bash
OMP_SBX_MCP_GATEWAY=1
```

Off by default. A gateway with nothing attached still hands omp the meta-tools
that register more servers, and that is not a choice to make for every project.

The tools arrive named `mcp__sbx_gateway_<tool>`, so `searxng_web_search` becomes
`mcp__sbx_gateway_searxng_web_search`. Check what mounted with `/mcp` in a
session.

`omp-init.sh` writes the server definition into a `--plugin-dir` root under
`~/.cache` inside the sandbox, not an `mcp.json`. Every config dir omp looks in
for `mcp.json` is a host mount here, so writing one would leave a URL in the
shared host config that resolves only inside a sandbox.

Changing `OMP_SBX_MCP_GATEWAY` takes effect on the next launch. Changing
`omp-init.sh` needs `./build.sh` and `omp --new`.


**Two-part setup, split by concern:**

| Part | Location | Rebuild needed? |
|---|---|---|
| Binary install | `sbx-kit/Dockerfile` (the `LSP servers` section) | Yes — `./build.sh` |
| Server registration | `<workspace>/.omp-agent/lsp.yml` (per project) | Workspace copy: no |

`lsp.yml` lives in the agent dir, which is the workspace-local `.omp-agent` —
editing it takes effect immediately on the next session. Adding or changing a *binary* requires a rebuild + `omp --new`.

#### Lazy loading

omp starts LSP servers **lazily**, keyed on `fileTypes` matching actual files in the open workspace. A server only activates for workspaces that contain a file whose extension matches one of its `fileTypes`. The message *“No language servers configured for this project”* (from `lsp status`) means **no file in the workspace matched** any server's `fileTypes` — not that the config is missing.

`rootMarkers` (`.git`, `go.mod`, `package.json`) set the project root but do **not** start a server by themselves; a matching file type is also required.

#### Adding a server

1. Install the binary in `sbx-kit/Dockerfile` — append to the global `npm install` line for npm packages, or add a separate `RUN` step for non-npm servers (`go install`, `cargo install`, etc.).
2. Register the server in `<workspace>/.omp-agent/lsp.yml`:
   ```yaml
     gopls:
       command: gopls
       args: ["serve"]
       fileTypes: [".go"]
       rootMarkers:
         - "go.mod"
         - ".git"
   ```
3. Rebuild + load (`./build.sh`), then start a fresh sandbox (`omp --new`).

### Security

All security is handled by the sbx microVM — no manual `cap_drop`, `gosu`, `umask`, or read-only rootfs configuration needed:

| Control | sbx |
|---|---|
| Isolation | MicroVM with separate kernel |
| Non-root user | Built-in `agent` UID 1000 |
| Network | Policy-based allow-list |
| Secrets | Proxy injects keys (never enter sandbox) |
| Resource limits | `sbx run --memory --cpus` |

## Scripted / CI use (experimental)

`omp-sbxenv` is an alternative launcher built on Docker sbx's declarative
`sbx-kit/.sbxenv.yaml` + `sbx env` commands (sbx v0.39+; Docker marks `sbx env`
experimental and subject to change). It fits headless automation better than
`omp-sbx`'s interactive create/pause/attach flow:

```bash
omp-sbxenv --version   # create (if needed) + run a one-shot command
omp-sbxenv --new        # remove + recreate the environment
```

Under the hood this templates `sbx-kit/.sbxenv.yaml` with `${VAR}` values the
script exports (workspace path, kit path, sandbox name) and calls
`sbx env create` / `sbx env exec` / `sbx env rm` directly — no host-mounted
secret files, since `.sbxenv.yaml` (unlike `spec.yaml`) expands `${VAR}`
placeholders for real.

**Known gaps vs `omp-sbx`:**
- No force-quit recovery cascade (re-attach → restart → recreate) — just
  create-or-reuse.
- Re-running `sbx env run` on an existing environment only re-applies
  env/MCP changes; other `.sbxenv.yaml` edits need `--new`.

For day-to-day interactive use, stick with `omp-sbx`.

## Rebuild after omp upgrade

```bash
cd ~/src/github.com/mikeatlas/omp-sbx
./build.sh
```
