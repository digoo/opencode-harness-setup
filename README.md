# OpenCode Harness Setup — Complete Guide

Everything needed to build a token-efficient OpenCode harness on macOS: MCP servers, plugins,
skills, a two-layer compression pipeline (RTK + Headroom), and an enforced model guard for a
restricted MCP server.

This is the exact sequence used to produce a working setup, including the mistakes, the
diagnostics, and the settings that turned out to be load-bearing.

**Target**: macOS 26.7.1 (arm64) · OpenCode 2.3.2 · Node 24.22.3 (fnm) · Homebrew 7.0.10

> **Custom API URL.** Every example uses `https://api.example.com/v1` as the upstream provider
> endpoint. Replace it with your own OpenAI-compatible API base URL throughout. It appears in
> the `rtk-proxy.toml` upstreams, the `rtk-proxy service install` flags, the `RTK_PROXY_*`
> environment variables, and the OpenCode provider `baseURL`.

---

## Table of contents

1. [Architecture](#1-architecture)
2. [Prerequisites](#2-prerequisites)
3. [Step 1 — Install the token tooling](#3-step-1--install-the-token-tooling)
4. [Step 2 — Build the RTK proxy chain](#4-step-2--build-the-rtk-proxy-chain)
5. [Step 3 — Install and wire Headroom](#5-step-3--install-and-wire-headroom)
6. [Step 4 — Configure the OpenCode provider](#6-step-4--configure-the-opencode-provider)
7. [Step 5 — Install plugins and skills](#7-step-5--install-plugins-and-skills)
8. [Step 6 — Register the MCP servers](#8-step-6--register-the-mcp-servers)
9. [Step 7 — The RTK after-tool hook](#9-step-7--the-rtk-after-tool-hook-the-part-that-actually-saves-tokens)
10. [Step 8 — The REA model guard](#10-step-8--the-rea-model-guard)
11. [Step 9 — Obsidian vault and workspace docs](#11-step-9--obsidian-vault-and-workspace-docs)
12. [Step 10 — Porting the vibe-coding-toolkit](#12-step-10--porting-the-vibe-coding-toolkit)
13. [Verification](#13-verification)
14. [Troubleshooting](#14-troubleshooting)
15. [Complete file reference](#15-complete-file-reference)

---

## 1. Architecture

Two request paths, one upstream provider.

```text
OpenCode (GPT or Claude model)
    |
    v
rtk-proxy  :8080          normalize (ANSI/progress/dedup) + cache-align
    |
    v
https://api.example.com/v1        (the provider)

Claude Code
    |
    v
Headroom  :8787            Kompress ONNX, mode=cache, tool-result interceptors
    |
    v
rtk-proxy  :8080
    |
    v
https://api.example.com/v1
```

Both proxies are **launchd user agents**, so they start at login and survive the editor closing.
OpenCode itself is not in that chain — it is a client that points at `http://127.0.0.1:8080/v1`.

### The three compression layers

| Layer | Where it runs | What it compresses | Measured |
|---|---|---|---|
| Headroom | proxy, before upstream | tool results (Bash output) | ~15% on large tool results |
| RTK after-tool hook | in the agent, after the tool runs | any unrewritten command's output | 51,374 B to 16,108 B (69%) |
| RTK source filters | in the rewritten command | `ls`, `grep`, `git`, `read`, `test` output | source-side, counted by `rtk gain` |

Plus OpenCode's own `compaction` for long-session summarisation.

---

## 2. Prerequisites

```sh
# Homebrew
brew install git gh node fnm sqlite zstd ripgrep fd

# Node via fnm (needed for the global npm packages below)
curl -fsSL https://fnm.vercel.app/install | bash
fnm install 24
fnm use 24
```

Verify:

```sh
opencode --version     # v2.3.2
gh auth status         # logged in, token scopes: gist, read:org, repo, workflow
node --version
```

> **Path warning.** The OpenCode server does not inherit your interactive shell `PATH`, so it
> cannot see binaries installed by fnm or npm into the fnm-managed Node directory. Every MCP
> `command` entry must use an **absolute path**. See [Step 6](#8-step-6--register-the-mcp-servers).

---

## 3. Step 1 — Install the token tooling

### RTK

```sh
brew upgrade rtk
rtk --version        # 1.2.1
```

RTK ships two binaries. `rtk` is in Homebrew. **`rtk-proxy` is not** — it is a separate,
separately-licensed release asset published alongside the CLI:

```sh
cd "$(mktemp -d)"
BASE=https://github.com/rtk-ai/rtk/releases/download/v1.2.1
curl -sL -o rtk-proxy.tar.gz "$BASE/rtk-proxy-aarch64-apple-darwin.tar.gz"
curl -sL -o checksums.txt "$BASE/checksums.txt"

# Verify before installing
grep "rtk-proxy-aarch64-apple-darwin" checksums.txt
shasum -a 256 rtk-proxy.tar.gz
# the two hashes must match

tar xzf rtk-proxy.tar.gz
install -m 755 rtk-proxy /opt/homebrew/bin/rtk-proxy
rtk-proxy --version
```

> **Do not skip the checksum step.** The proxy forwards provider credentials; a compromised
> binary would receive your API keys.

### Other npm packages

```sh
npm install -g context-mode@latest
npm install -g @dietrichgebert/ponytail@latest
npm install -g @caveman-ai/cli@latest
npm install -g rea-agents@latest
npm install -g @playwright/mcp@latest
```

> `npm update -g` can *remove* globally installed packages rather than upgrade them. Verify
> with `npm list -g --depth=0` afterwards and reinstall anything missing.

---

## 4. Step 2 — Build the RTK proxy chain

### 4.1 The proxy config

`rtk-proxy` reads `rtk-proxy.toml`. Create the directory and write the file:

```sh
mkdir -p ~/Library/Application\ Support/rtk-proxy
```

The file `~/Library/Application Support/rtk-proxy/rtk-proxy.toml` contains:

```toml
bind = "127.0.0.1:8080"
anthropic_upstream = "https://api.example.com/v1"
openai_upstream = "https://api.example.com/v1"
ccr = true
cache_align = true
normalize = true
compression = "balanced"
relay_borrowing = true
icm_ttl_secs = 604800
upstream_timeout_secs = 600
upstream_retries = 2
```

> ### Pitfall: `rtk-proxy config set` does not persist
>
> ```
> $ rtk-proxy config set openai_upstream https://example.com/v1
> openai_upstream = https://example.com/v1     # looks like it worked
> $ rtk-proxy config get openai_upstream
> https://api.openai.com                        # unchanged
> ```
>
> The admin endpoint acknowledges the write but the value does not survive. Use the **toml file**
> or the **environment variables** `RTK_PROXY_OPENAI_UPSTREAM` / `RTK_PROXY_ANTHROPIC_UPSTREAM`.
> Environment variables work when starting the process:
>
> ```sh
> RTK_PROXY_OPENAI_UPSTREAM=https://api.example.com/v1 \
> RTK_PROXY_ANTHROPIC_UPSTREAM=https://api.example.com/v1 \
>   rtk llm-proxy start
> ```

### 4.2 Install as a launchd service

```sh
rtk-proxy service install \
  --openai-upstream https://api.example.com/v1 \
  --anthropic-upstream https://api.example.com/v1 \
  --ccr true --cache-align true --compression balanced
```

This writes:

- `~/Library/LaunchAgents/app.rtk-ai.rtk-proxy.plist` — `RunAtLoad` + `KeepAlive`
- `~/Library/Application Support/rtk-proxy/rtk-proxy.toml`

Verify and restart:

```sh
rtk-proxy service status
rtk llm-proxy stop && rtk-proxy service start
rtk-proxy config get
```

### 4.3 The pipeline file — this is the one that matters

Without a pipeline file the daemon logs:

```text
no cache-breakpoint or CCR rules — running category-A normalisation only
```

and `rtk-proxy stats` reports `tokens saved: 0`.

Create `~/Library/Application Support/rtk/pipeline.toml`:

```toml
schema_version = 1

[pipeline]
extends = ["rtk:posthook", "rtk:proxy"]
```

Then restart the daemon and confirm the rules changed:

```sh
rtk llm-proxy stop
rtk-proxy service start
rtk pipeline show
```

Expected output:

```text
Pipeline: rtk:posthook
Inherits: rtk:posthook -> rtk:proxy -> rtk:default

Rules (per position; first match wins, project before user before inherited):
  hook.before_tool.shell
    rtk-rewrite            [rtk:default] when always -> action=rewrite
  hook.after_tool.read
    lockfiles              [rtk:posthook] ...
  hook.after_tool.shell
    term-default           [rtk:posthook] when is_rtk_command=false -> use=[term]
```

> ### Pitfall: `rtk:proxy` alone saves nothing
>
> `rtk:proxy` extends `rtk:default`, whose only proxy-layer rule is `normalize`
> (`ansi`, `progress`, `dedup`). That strips escape codes — it does not compress.
> The real compression method is `term`, and it only runs at `hook.after_tool`,
> which the **proxy cannot reach** because the method keeps the original only in a
> recall copy the proxy cannot store. RTK says so explicitly:
>
> ```text
> W016 `term` (via cap) is skipped at proxy.request.tool_result — it keeps the
>      original only in a recall copy, which the proxy cannot store — use it
>      under hook.after_tool
> ```
>
> So `rtk:posthook` fixes the *pipeline declaration*, but the actual compression
> still requires the agent-side hook from Step 7.

> ### Pitfall: `rtk pipeline explain --agent opencode` shows nothing
>
> The pipeline resolves rules by **agent name**, and RTK does not know `opencode`:
>
> ```
> $ rtk pipeline explain --agent opencode --tool Bash --command "ls"
> hook.after_tool.any: no rule matches these facts — output passes through
> $ rtk pipeline explain --agent claude-code --tool Bash --command "ls"
> hook.after_tool.shell: rule `term-default` -> [ansi, progress, dedup, base64-elide, cap]
> ```
>
> Use `--agent claude-code` when inspecting pipeline behaviour.

---

## 5. Step 3 — Install and wire Headroom

Headroom is a separate product from OpenCode's `compaction`. `compaction` summarises
conversation history; **Headroom compresses tool output before it reaches the model**.
Both are useful; they are not substitutes.

### 5.1 Install

```sh
uv tool install --python 3.13 "headroom-ai[all]"
headroom --version      # 0.41.0
```

Verify the compression model loads:

```sh
headroom doctor
```

Expected: `kompress │ ✓ pass │ ready (onnx)`.

> On first request the ONNX model downloads and warms in the background. The log shows
> `Kompress: DEFERRED (warming in the background after startup)` followed by
> `Kompress: warmed in the background in 4577 ms (backend onnx)`. A `degraded` kompress
> status during that window is expected, not a fault.

### 5.2 Install as a service

```sh
headroom deploy --providers manual --target claude
```

This writes `~/Library/LaunchAgents/com.headroom.default.plist` and
`~/.headroom/deploy/default/{manifest.json,run-headroom.sh,ensure-headroom.sh}`.

### 5.3 Point Headroom at rtk-proxy

Headroom must forward to rtk-proxy, not straight to the provider. Write
`~/.headroom/deploy/default/run-headroom.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
export HEADROOM_PORT=8787
export HEADROOM_HOST=127.0.0.1
export HEADROOM_MODE=cache
export HEADROOM_BACKEND=anthropic
export HEADROOM_EMBEDDER_RUNTIME=cpu
export HEADROOM_KOMPRESS_BACKEND=onnx
export HEADROOM_TELEMETRY=off
export HEADROOM_ROLLOUT_CHANNEL=canary
# Chain: client -> Headroom (compress) -> rtk-proxy -> provider
export ANTHROPIC_TARGET_API_URL=http://127.0.0.1:8080
export OPENAI_TARGET_API_URL=http://127.0.0.1:8080/v1
exec /Users/<you>/.local/bin/headroom install agent run --profile default
```

Copy it over the ensure script and make both executable:

```sh
cp ~/.headroom/deploy/default/run-headroom.sh ~/.headroom/deploy/default/ensure-headroom.sh
chmod 755 ~/.headroom/deploy/default/*.sh
```

And the manifest must match, because **`base_env` overrides the run script**. Edit
`~/.headroom/deploy/default/manifest.json` so `base_env` contains:

```json
{
  "ANTHROPIC_TARGET_API_URL": "http://127.0.0.1:8080",
  "OPENAI_TARGET_API_URL": "http://127.0.0.1:8080/v1"
}
```

Restart and verify the upstream actually changed:

```sh
launchctl bootout gui/$(id -u)/com.headroom.default
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.headroom.default.plist
sleep 8
curl -s http://127.0.0.1:8787/readyz | grep -o '"url":"[^"]*"'
# -> "url":"http://127.0.0.1:8080"
```

### 5.4 Enable tool-result interception

By default Headroom only normalises. Real tool-result compression is **opt-in** and
gated behind a rollout channel.

Add to both `run-headroom.sh` and `ensure-headroom.sh`:

```bash
export HEADROOM_ROLLOUT_CHANNEL=canary
```

Add `--intercept-tool-results` to `proxy_args` in `manifest.json`:

```json
"proxy_args": [
  "--host", "127.0.0.1",
  "--port", "8787",
  "--headroom-deployment-profile", "default",
  "--headroom-deployment-runtime", "python",
  "--mode", "cache",
  "--backend", "anthropic",
  "--intercept-tool-results",
  "--no-telemetry",
  "--no-rate-limit"
]
```

Confirm the rollout resolved:

```sh
headroom rollout status
```

```text
Rollout channel: canary
  tool_result_interceptors: enabled=true decision=rollout_channel
```

> ### Pitfall: Headroom compresses nothing without the flag
>
> The symptom is subtle: everything looks healthy, `headroom doctor` passes, `kompress` reports
> `ready (onnx)`, and the proxy answers every request — but the token count never drops.
>
> The log shows why:
>
> ```text
> [router] route_counts={'excluded_tool': 1} compressed=0 frozen=2 msgs=3
> [router] route_counts={'ratio_too_high': 1, 'cache_miss': 1} compressed=0 frozen=976 msgs=977
> ```
>
> `compressed=0` on every request. Two separate causes, both required:
>
> 1. **The rollout channel.** Tool-result interceptors are gated behind
>    `HEADROOM_ROLLOUT_CHANNEL=canary` (or `dev`). Without it:
>    ```text
> Rollout channel: stable
>   tool_result_interceptors: enabled=false decision=not_requested
> ```
> 2. **The flag.** `--intercept-tool-results` must be in `proxy_args` in the manifest.
>    It is rejected at startup without the channel:
>    ```text
> --intercept-tool-results  Opt in to tool_result interceptors.
>                          Requires HEADROOM_ROLLOUT_CHANNEL=canary (or dev).
> ```
>
> Fix both, then reload the launchd agent and confirm `compressed=1` appears in the log.

> ### Pitfall: pointing Headroom at the wrong provider breaks the other client
>
> Headroom is a **shared** proxy. Changing its upstream to serve OpenCode also changes the
> upstream for every client that already pointed at Headroom.
>
> In this setup Claude Code was already routed through Headroom to a Kimi endpoint with a
> Kimi key. Repointing Headroom at the OpenAI-compatible provider broke Claude Code
> immediately, because the Kimi key was rejected by the new upstream:
>
> ```text
> Error: Incorrect API key provided: sk-...5060.
> You can find your API key at https://platform.openai.com/account/api-keys.
> ```
>
> The mistake was changing Headroom's upstream in place. The correct approach is to keep
> Headroom pointed at whatever provider its clients expect, and let each client decide where
> *it* points. If you need two different upstreams, run **two** Headroom instances on
> different ports — one per provider — instead of moving a shared one.
>
> When you do change it, audit every client that uses it before restarting:
>
> ```sh
> grep -r "127.0.0.1:8787" ~/.claude ~/.config/opencode 2>/dev/null
> ```

### 5.4.1 Two providers, two Headroom instances

If two clients need different upstreams, give each its own Headroom. The deployment profile
name is what keeps them apart:

```sh
# profile "openai" -> port 8788
headroom deploy --profile openai --port 8788 --providers manual --target opencode

# profile "default" -> port 8787
headroom deploy --profile default --port 8787 --providers manual --target claude
```

Each profile gets its own directory (`~/.headroom/deploy/<profile>/`), its own launchd plist
(`com.headroom.<profile>`), and its own `base_env`. Then point each client at its own port:

```text
OpenCode   -> http://127.0.0.1:8080/v1        (rtk-proxy only, no Headroom)
Claude Code-> http://127.0.0.1:8787           (Headroom profile "default")
```

### 5.5 What Headroom will and will not compress

`Read`, `Glob`, `Grep`, `Write`, `Edit`, `WebSearch`, `WebFetch` are **excluded by design**:
lossy compression of a file read breaks byte-exact `Edit` patching. `Bash` is the intended
target. Do not "fix" this by removing them from the exclusion list.

### 5.6 Measure it

```sh
headroom savings
```

```text
Today        0.1%  saved 12,332 / 8,312,831 tokens  $0.0370
  opencode                 36 calls - 11,019 tokens saved
```

To compare a payload directly, send the same body to both hops:

```sh
curl -s http://127.0.0.1:8080/v1/chat/completions -H "Authorization: Bearer $KEY" \
  -d @body.json | jq .usage.prompt_tokens     # without Headroom
curl -s http://127.0.0.1:8787/v1/chat/completions -H "Authorization: Bearer $KEY" \
  -d @body.json | jq .usage.prompt_tokens     # with Headroom
```

---

## 6. Step 4 — Configure the OpenCode provider

### 6.1 The provider block

`~/.config/opencode/opencode.json`:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "kpa": {
      "name": "KPA",
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": {
        "baseURL": "http://127.0.0.1:8080/v1"
      },
      "models": {
        "gpt-5-6-luna": {
          "name": "GPT-5.6 Luna",
          "settings": {
            "apiKey": "{file:~/.config/opencode/secrets/provider-gpt.key}"
          },
          "limit": { "context": 1050000, "input": 922000, "output": 128000 }
        }
      }
    }
  },
  "compaction": {
    "auto": true,
    "keep": { "tokens": 15000 },
    "buffer": "20%"
  }
}
```

### 6.2 Real limits, not the fallback

Custom providers fall back to **200k context / 32k output** unless each model declares its own
`limit`. A 1M-window model silently gets 200k. Source the real numbers from the
models.dev catalog:

```sh
curl -s https://models.dev/api.json -o /tmp/models.json
node -e "
const d=require('/tmp/models.json');
for (const [p,m] of Object.entries(d)) {
  if (!m.models) continue;
  for (const id of Object.keys(m.models)) {
    if (id.startsWith('gpt-5-6') || id.startsWith('claude-opus-5')) {
      console.log(p+'/'+id, JSON.stringify(m.models[id].limit));
    }
  }
}"
```

### 6.3 Secrets on disk, not in the config

```sh
mkdir -p ~/.config/opencode/secrets
chmod 700 ~/.config/opencode/secrets
printf '%s' 'sk-...' > ~/.config/opencode/secrets/provider-gpt.key
printf '%s' 'sk-...' > ~/.config/opencode/secrets/provider-claude.key
chmod 600 ~/.config/opencode/secrets/*.key
```

Reference with `{file:...}` so the key never appears in the config file:

```json
"apiKey": "{file:~/.config/opencode/secrets/provider-gpt.key}"
```

---

## 7. Step 5 — Install plugins and skills

### 7.1 Plugins

```jsonc
"plugin": [
  "superpowers@git+https://github.com/obra/superpowers.git",
  "/opt/homebrew/lib/node_modules/context-mode",
  "./plugins/caveman",
  "./plugins/rea-guard"
]
```

```sh
opencode plugin list
opencode plugin check
```

### 7.2 RTK's own OpenCode plugin

```sh
rtk init -g --opencode --auto-patch
```

This installs `~/.config/opencode/plugins/rtk.ts` **and** the Claude Code hooks, including the
`PostToolUse` hook that RTK itself reports as missing.

```sh
rtk init --show
```

```text
[ok] settings.json: RTK hooks configured (PreToolUse + PostToolUse)
[ok] OpenCode: plugin installed (/Users/<you>/.config/opencode/plugins/rtk.ts)
```

### 7.3 Claude Code routing

`~/.claude/settings.json`:

```jsonc
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8787",
    "ANTHROPIC_API_KEY": "<your provider key>",
    "ANTHROPIC_MODEL": "claude-opus-5-5",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-5-5",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-5-5",
    "ANTHROPIC_DEFAULT_FABLE_MODEL": "claude-fable-5-2",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-5-5",
    "CLAUDE_CODE_SUBAGENT_MODEL": "claude-sonnet-5-5"
  }
}
```

Claude Code then flows through Headroom automatically.

### 7.4 Skills

Global skills live in `~/.config/opencode/skills/`. The main ones used here:

| Skill | Purpose |
|---|---|
| `brainstorming` | before creative work |
| `writing-plans` | before multi-step implementation |
| `test-driven-development` | before writing implementation code |
| `systematic-debugging` | before proposing a fix |
| `verification-before-completion` | before claiming done |
| `requesting-code-review` | before merging |
| `using-git-worktrees` | isolated feature work |
| `caveman` | terse output mode |

---

## 8. Step 6 — Register the MCP servers

### 8.1 The full config

```jsonc
"mcp": {
  "codebase-memory-mcp": {
    "type": "local",
    "command": ["/Users/<you>/.local/bin/codebase-memory-mcp"]
  },
  "context-mode": {
    "type": "local",
    "command": [
      "/opt/homebrew/opt/node/bin/node",
      "/opt/homebrew/lib/node_modules/context-mode/server.mjs",
      "--agent", "opencode"
    ],
    "enabled": true
  },
  "serena": {
    "type": "local",
    "command": [
      "uvx", "--from", "git+https://github.com/oraios/serena",
      "serena", "start-mcp-server", "--context", "ide-assistant", "--project-from-cwd"
    ],
    "environment": { "PYTHONUNBUFFERED": "1" }
  },
  "servers": {
    "context7": {
      "type": "remote",
      "url": "https://mcp.context7.com/mcp"
    },
    "supabase": {
      "type": "remote",
      "url": "https://mcp.supabase.com/mcp?project_ref=<ref>",
      "enabled": true
    },
    "rea": {
      "type": "local",
      "command": [
        "/Users/<you>/.local/share/fnm/node-versions/24.22.3/installation/bin/rea",
        "mcp"
      ],
      "disabled": false
    }
  },
  "playwright": {
    "type": "local",
    "command": [
      "/Users/<you>/.local/share/fnm/node-versions/24.22.3/installation/bin/playwright-mcp"
    ],
    "enabled": true
  }
}
```

### 8.2 Absolute paths are mandatory

```text
x rea        failed: NotFound: ChildProcess.spawn (rea mcp)
x playwright failed: NotFound: ChildProcess.spawn (playwright-mcp )
v rea        connected
```

Same binary, same command — only the path changed. The OpenCode server's `PATH` does not
include the fnm bin directory. Resolve it once:

```sh
npm root -g
ls -d ~/.local/share/fnm/node-versions/*/installation/bin
```

> If you upgrade Node through fnm, the version segment changes and every MCP pointing at
> that path breaks. Re-run the command above after any Node upgrade.

### 8.3 REA has its own installer

```sh
rea mcp add --agent opencode --command "rea mcp"
```

It writes the config itself and keeps a backup at `opencode.json.rea.backup`. Then fix the
path and verify:

```sh
rea mcp doctor
```

```text
healthy: true
adapter: production-stdio
server: { name: rea, version: 6.9.0, protocol_version: 2025-11-25 }
inventory:
  tools:   { expected: 255, observed: 255, missing: [], unexpected: [], duplicates: [] }
  prompts: { expected: 6,   observed: 6,   missing: [], unexpected: [], duplicates: [] }
identity:
  expected_catalog_digest: 2c725b48...
  observed_catalog_digest: 2c725b48...
```

### 8.4 Verify everything

```sh
opencode mcp list
```

```text
v codebase-memory-mcp  connected
v context-mode         connected
v context7             connected
v opencode_console     connected
v playwright           connected
v rea                  connected
v serena               connected
v supabase             connected
```

---

## 9. Step 7 — The RTK after-tool hook

This is the single highest-impact change in the whole setup, and it is **not** provided by
RTK's stock OpenCode plugin.

### 9.1 Why it is needed

- The `term` filter (the one that actually compresses) only runs at `hook.after_tool`.
- The proxy cannot reach `hook.after_tool` — it cannot store the recall copy.
- RTK's stock OpenCode plugin registers `tool.execute.before` only, so nothing fires the
  filter in OpenCode.
- Result: `rtk-proxy stats` reported `tokens saved: 0` for every request.

### 9.2 The OpenCode 2.x hook shape

`ctx.tool.hook("execute.after", cb)` receives:

```text
{ tool, sessionID, agent, messageID, id, input, status, result }
result: { output, content, metadata }
```

For the **shell** tool, `result.output` is:

```json
{ "exitCode": 0, "output": "<the text>", "wallTimeSeconds": 12 }
```

> ### Pitfall: the text is at `result.output.output`, not `result.output.stdout`
>
> Reading `.stdout` yields `undefined`, the handler silently returns, and nothing is
> compressed — with no error anywhere. Discover the real shape with a throwaway probe plugin
> that dumps `Object.keys(e)` to a file.

> ### Pitfall: a syntax error in the plugin fails silently
>
> An orphaned doc comment left by a bad edit made the plugin fail to load. OpenCode did not
> report it and the hook simply never fired. Always check the plugin parses:
>
> ```sh
> cp ~/.config/opencode/plugins/rtk.ts /tmp/rtk-check.mts
> node --input-type=module -e "import('/tmp/rtk-check.mts').then(()=>console.log('OK')).catch(e=>console.log('ERR',e.message))"
> ```

### 9.3 The handler

Add to `~/.config/opencode/plugins/rtk.ts`:

```ts
async function handleAfterToolHook(rtkBin: string, event: any) {
  if (!event || event.status === "error") return
  if (process.env.RTK_DISABLED === "1") return

  const result = event.result ?? {}
  const output = result.output
  if (!output || typeof output !== "object") return

  // OpenCode's shell tool reports {exitCode, output, wallTimeSeconds}.
  const stdout = typeof output.output === "string" ? output.output : ""
  if (!stdout) return

  // rtk's `hook claude` processor keys off Claude Code's tool names.
  const toolName = event.tool === "shell" ? "Bash" : String(event.tool ?? "")

  const payload = JSON.stringify({
    hook_event_name: "PostToolUse",
    tool_name: toolName,
    tool_input: event.input ?? {},
    tool_response: { stdout, interrupted: false },
  })

  try {
    const answer = await new Promise<string | null>((resolve) => {
      const child = spawn(rtkBin, ["hook", "claude"], {
        encoding: "utf8",
        windowsHide: true,
      })
      let out = ""
      child.stdout?.on("data", (d) => (out += String(d)))
      child.on("error", () => resolve(null))
      child.on("close", () => resolve(out))
      child.stdin?.end(payload)
    })

    if (!answer) return
    const parsed = JSON.parse(String(answer).trim() || "{}")
    const updated = parsed?.hookSpecificOutput?.updatedToolOutput
    if (!updated || typeof updated.stdout !== "string") return
    if (updated.stdout === stdout) return

    output.output = updated.stdout
  } catch {
    // Compression is best-effort: an unusable answer leaves the output as it was.
  }
}
```

Register it in **both** entrypoints:

```ts
// V2
async setup(ctx: any) {
  const rtkBin = await ensureRtkUsable()
  if (!rtkBin) return
  await ctx?.tool?.hook?.("execute.before", (e: any) =>
    handleToolHook(e?.tool, e?.input, typeof e?.agent === "string" ? e.agent : undefined)
  )
  await ctx?.tool?.hook?.("execute.after", (e: any) => handleAfterToolHook(rtkBin, e))
}

// V1
async server() {
  const rtkBin = await ensureRtkUsable()
  if (!rtkBin) return {}
  return {
    "shell.env": (input: any, output: any) => { /* existing PATH fixup */ },
    "tool.execute.before": (input: any, output: any) =>
      handleToolHook(input?.tool, output?.args),
    "tool.execute.after": (input: any, output: any) =>
      handleAfterToolHook(rtkBin, input),
  }
}
```

Requires `spawn`:

```ts
import { execFile, spawn } from "node:child_process"
```

### 9.4 What the hook actually does

`rtk hook claude` expects Claude Code's `PostToolUse` JSON on stdin and answers with:

```json
{ "hookSpecificOutput": { "hookEventName": "PostToolUse", "updatedToolOutput": { "stdout": "..." } } }
```

The payload must include `tool_input.command`. Without it the handler returns empty.

> ### Pitfall: rtk will not compress its own output
>
> The `term-default` rule has the condition `is_rtk_command = false`. When RTK's
> `execute.before` hook rewrote `cat` into `rtk read`, the after-hook sees a command
> RTK itself produced and **skips it** — by design, because RTK already filtered at the
> source.
>
> So the after-hook earns its keep on commands RTK does **not** rewrite (arbitrary shell,
> `awk`, `sed`, custom tools) and on any output large enough to matter.

> ### Pitfall: the 512-byte floor
>
> RTK's `min_size = 512` guard means output under 512 bytes is left alone. That is
> intentional — compressing a small result costs more than it saves.

### 9.5 Verify

Build a large payload and measure:

```sh
python3 -c "
with open('/tmp/rtk-big/noise.txt','w') as f:
    for i in range(3000):
        f.write(f'noise record {i} alpha beta gamma delta epsilon zeta eta theta\n')
"

rtk hook claude < payload.json | jq -r '.hookSpecificOutput.updatedToolOutput.stdout | length'
```

Observed: **51,374 to 16,108 bytes (69% reduction)**.

Originals stay retrievable:

```sh
rtk recall --list
```

```text
HASH               COMMAND                      LINES  HIDDEN      ORIG  EXIT TRUNC
c55d0d63dc622ff0   posthook:bash_awk              802     802     51.4K     -
```

```sh
rtk recall c55d0d63dc622ff0 --full
```

### 9.6 The stale-server trap

The background `opencode serve --service` caches the loaded plugin. A plugin edit is not
live until the server reloads.

```sh
opencode run --standalone --model kpa/gpt-5-6-luna "..."   # fresh server
```

Or `/reload` in the TUI.

---

## 10. Step 8 — The REA model guard

REA must not run with Claude or GPT models — doing so risks the account being banned.
An instruction in `AGENTS.md` is advisory; a subagent can miss it. This is the enforced version.

### 10.1 The instruction layer

`~/.config/opencode/AGENTS.md`, inside a marker block so plugin rewrites leave it alone:

```markdown
<!-- rea-begin -->
# REA MCP — model restriction

REA (the `rea` MCP server) is BANNED with Claude models and GPT models. Using REA
with those models risks the user's account being banned. This is a hard
restriction, not a style preference.

## Rule
- NEVER call any `rea` tool while the active model is a Claude model or a GPT model.
- This applies to the main session and to every subagent.
- If a task needs REA and the current model is Claude or GPT, switch to another model first.

## Allowed models
- Any model that is not a Claude model and not a GPT model is allowed.
- If unsure whether a model counts as Claude or GPT, treat it as banned and ask.

## Enforcement
- Never delegate REA work to `kpa/claude-*` or `kpa/gpt-*` models.
<!-- rea-end -->
```

### 10.2 The enforcement layer

`~/.config/opencode/plugins/rea-guard/index.ts`:

```ts
const BANNED_PATTERNS = [
  /^claude/i,
  /^gpt-/i,
  /^gpt[0-9]/i,
  /^o[134](-|$)/i, // o1, o3, o4 reasoning models
  /^chatgpt/i,
]

function isReaTool(tool: string): boolean {
  return /^rea[_.]/i.test(tool)
}

function isBannedModel(modelID: string): boolean {
  if (!modelID) return false
  return BANNED_PATTERNS.some((re) => re.test(modelID))
}

export default {
  id: "rea-guard",

  async setup(ctx: any) {
    await ctx?.tool?.hook?.("execute.before", async (event: any) => {
      const tool = String(event?.tool ?? "")
      if (!isReaTool(tool)) return

      const sessionID = event?.sessionID
      if (!sessionID) return

      let modelID = ""
      try {
        const session = await ctx.session.get({ sessionID })
        const m = session?.model ?? session?.info?.model
        modelID = String(m?.id ?? m?.modelID ?? "")
      } catch {
        // Fail closed: a banned model must never reach REA because of a lookup error.
        throw new Error(
          `[rea-guard] blocked ${tool}: could not resolve the session model, and REA is banned with Claude and GPT models.`
        )
      }

      if (!isBannedModel(modelID)) return

      throw new Error(
        `[rea-guard] blocked ${tool}. REA is banned with Claude and GPT models (current model: ${modelID}). Switch to another model to use REA.`
      )
    })
  },
}
```

`~/.config/opencode/plugins/rea-guard/package.json`:

```json
{
  "name": "rea-guard",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "main": "index.ts"
}
```

Register it:

```jsonc
"plugin": [
  "superpowers@git+https://github.com/obra/superpowers.git",
  "/opt/homebrew/lib/node_modules/context-mode",
  "./plugins/caveman",
  "./plugins/rea-guard"
]
```

### 10.3 Verify

```sh
opencode run --model kpa/gpt-5-6-luna "Call rea_address_name with address 0x1000."
```

```text
[rea-guard] blocked rea_address_name. REA is banned with Claude and GPT models
(current model: gpt-5-6-luna). Switch to another model to use REA.
```

Test the pattern logic directly against a table of known ids — banned: `gpt-*`, `claude-*`,
`o1`/`o3`/`o4`, `chatgpt-*`; allowed: `llama`, `qwen`, `gemini`, `mistral`, `deepseek`, `grok`,
`kimi`, `glm`, `minimax`. 23 cases, all pass.

> **Note.** The guard reads the *session's selected model*, resolved server-side via
> `ctx.session.get`. It is not a provider allowlist, so it survives provider renames and
> new model names. Anything matching the banned patterns is treated as banned, including
> models you have not seen yet.

---

## 11. Step 9 — Obsidian vault and workspace docs

```sh
brew install --cask obsidian
mkdir -p ~/vibecoding/vault
```

Then open the vault in Obsidian and enable **Settings → General → Advanced → Command line
interface** if you want the `obsidian` CLI.

Workspace layout used here:

```text
~/vibecoding/
|-- AGENTS.md            # policy: workflow, tool restrictions, shell hygiene
|-- CLAUDE.md            # bridge to the shared instructions
|-- docs/                # architecture, quality, onboarding, setup, design
|-- vault/               # Obsidian
|-- vibe-toolkit/        # portable port of an upstream toolkit
`-- <project folders>/   # one folder per repo
```

---

## 12. Step 10 — Porting the vibe-coding-toolkit

Upstream: <https://github.com/soumatheusgomes/vibe-coding-toolkit> — 122 blobs.

### 12.1 Mirror the upstream for reference

Fetch the authoritative tree:

```sh
curl -s -H "User-Agent: opencode" \
  "https://api.github.com/repos/soumatheusgomes/vibe-coding-toolkit/git/trees/main?recursive=1" \
  -o /tmp/gt.json

node -e "
const fs=require('fs');
const j=JSON.parse(fs.readFileSync('/tmp/gt.json','utf8'));
const blobs=j.tree.filter(t=>t.type==='blob');
console.log('blobs:', blobs.length, 'truncated:', j.truncated);
"
```

Download each blob preserving its path. Write this to a script file and run it:

```sh
BASE=https://raw.githubusercontent.com/soumatheusgomes/vibe-coding-toolkit/main
node -e "
const fs=require('fs');
const j=JSON.parse(fs.readFileSync('/tmp/gt.json','utf8'));
for (const t of j.tree) {
  if (t.type!=='blob') continue;
  const p='_upstream/'+t.path;
  fs.mkdirSync(require('path').dirname(p),{recursive:true});
  fs.writeFileSync('/tmp/paths.txt', t.path+'\n', {flag:'a'});
}
"

while read -r f; do
  mkdir -p "_upstream/$(dirname "$f")"
  curl -sL -o "_upstream/$f" "$BASE/$f"
done < /tmp/paths.txt
```

> ### Pitfall: the `.example` and `.template` trap
>
> 25 files end in `.example` and 11 in `.template`. Any glob like `*.ts` or `*.json`
> misses all of them. A count based on the GitHub API is the only reliable check.
> Also easy to miss: `LICENSE` (no extension), `CLAUDE.md` (11 bytes),
> `.github/workflows/validate.yml`, three localised READMEs, and 10 SVG assets in
> `docs/assets/readme/` (each with a `-still.svg` twin).

### 12.2 Port, do not copy

Port the *concept* into OpenCode's own shape. Do not copy client-specific harness internals
(Claude Code plugins, Codex config), and never copy credentials.

| Upstream concept | OpenCode equivalent |
|---|---|
| Graphify project graph | `codebase-memory-mcp` graph tools + `check_index_coverage` |
| Obsidian memory | durable notes in `docs/` + Serena memory + the environment manifest |
| Codex/Claude playbook | `opencode.json`, `plugins/`, `mcp/`, `hooks/` + `opencode plugin list` |
| Anthropic skills | OpenCode skills, `context7` for library docs |

### 12.3 Cross-check the port with more than one model

Independent catalogs from different models catch different omissions. Have each produce a
path list, then have a third compare them against live ground truth:

```sh
gh api "repos/OWNER/REPO/git/trees/main?recursive=1" --jq '.tree[] | select(.type=="blob") | .path'
```

In this setup the cross-check found 26 files missing from the local mirror — the root
READMEs, LICENSE, the workflow file, 10 SVG assets, and 6 templates — because the first
catalog was built from the local mirror instead of from GitHub.

---

## 13. Verification

Run all of it after a fresh boot.

```sh
echo "=== services ==="
launchctl list | grep -iE "headroom|rtk"

echo "=== ports ==="
lsof -nP -iTCP -sTCP:LISTEN | grep -E ":8080|:8787"

echo "=== chain ==="
curl -s http://127.0.0.1:8787/readyz | jq -r .checks.upstream.url
rtk-proxy config get | jq -r .openai_upstream

echo "=== mcp ==="
opencode mcp list

echo "=== plugins ==="
opencode plugin list

echo "=== models live ==="
for m in kpa/gpt-5-6-luna kpa/claude-opus-5-5 kpa/claude-haiku-5-5; do
  printf '%s -> ' "$m"
  opencode run --model "$m" "reply exactly OK" 2>&1 | tail -n 1
done

echo "=== savings ==="
rtk gain
headroom savings
```

Expected chain output:

```text
http://127.0.0.1:8080
https://api.example.com/v1
```

Expected savings on a busy machine:

```text
RTK Token Savings (Global Scope)
  Total commands: 239
  Tokens saved:   19.6K (38.0%)

headroom savings
  opencode   36 calls - 11,019 tokens saved
```

---

## 14. Troubleshooting

### `rtk-proxy stats` shows `tokens saved: 0`

The proxy layer cannot compress by itself. Check in this order:

1. `~/Library/Application Support/rtk/pipeline.toml` exists and extends `rtk:posthook`.
2. The daemon log says `pipeline=rtk:posthook`, not `pipeline=rtk:default`.
3. The agent-side `execute.after` hook is registered — this is where the saving happens.

```sh
rtk pipeline show
tail -n 20 ~/Library/Application\ Support/rtk-proxy/rtk-proxy.log
```

### The RTK after-hook does nothing

Check in order:

1. **Plugin syntax error.** A malformed plugin fails to load *silently*. Confirm:
   ```sh
   cp ~/.config/opencode/plugins/rtk.ts /tmp/rtk-check.mts
   node --input-type=module -e "import('/tmp/rtk-check.mts').then(()=>console.log('OK')).catch(e=>console.log('ERR',e.message))"
   ```
2. **Wrong output path.** Must be `result.output.output`, not `result.output.stdout`.
3. **Missing `tool_input.command`** in the payload sent to `rtk hook claude`.
4. **Output under 512 bytes** — the `min_size` guard.
5. **Command was rewritten by RTK** — `is_rtk_command = false` means it is skipped.
6. **Stale server.** The background `opencode serve --service` caches the loaded plugin.
   Use `/reload` in the TUI, or `opencode run --standalone` to test plugin changes.

### MCP shows `NotFound: ChildProcess.spawn`

The OpenCode server's `PATH` lacks the fnm bin directory. Use absolute paths in `command`.

### `rtk pipeline explain` shows no rules for `--agent opencode`

Expected. RTK knows `claude-code`, not `opencode`. Use `--agent claude-code`.

### `rtk-proxy config set` reports success but nothing changes

Expected. The write does not persist. Edit the toml file or use the environment variables.

### Headroom upstream still points at the old provider

The manifest's `base_env` overrides the run script. Edit **both**, then reload the launchd
agent:

```sh
launchctl bootout gui/$(id -u)/com.headroom.default
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.headroom.default.plist
```

### Headroom is healthy but saves nothing

Check the router counters in the log:

```sh
grep -i "router" ~/.headroom/logs/proxy-8787.log | tail -n 5
```

```text
[router] route_counts={'excluded_tool': 1} compressed=0 frozen=2 msgs=3
```

`compressed=0` means the interceptors never ran. Two causes, both must be fixed:

1. `HEADROOM_ROLLOUT_CHANNEL=canary` is not set in the run script, the ensure script,
   **and** the manifest `base_env`.
2. `--intercept-tool-results` is missing from `proxy_args` in the manifest.

```sh
headroom rollout status
# tool_result_interceptors: enabled=true decision=rollout_channel
```

### A client started returning "Incorrect API key provided"

You changed a shared proxy's upstream. Headroom serves every client that points at it.
Restore the upstream that client expects, or give each provider its own Headroom instance
on its own port (see 5.4.1).

### Shell tool calls fail to parse

```text
The tool input could not be parsed as JSON, so the call was not executed.
Invalid arguments for tool "shell": command: Missing key
```

The command string carried nested quotes, escaped quotes, backslashes, a heredoc, `$(...)`, or
backticks. Do **not** retry with more escaping. Write the command to a script file with the
`patch` tool, then run it:

```sh
sh /path/to/script.sh
```

The same rule applies to `ctx_execute` with `language: "shell"` — its `code` field is still a
shell command string.

### Everything worked, then stopped after a Node upgrade

fnm changes the version directory. Re-resolve the MCP paths:

```sh
ls -d ~/.local/share/fnm/node-versions/*/installation/bin
```

and update every MCP entry that referenced the old path.

---

## 15. Complete file reference

### Created or modified

| Path | Purpose |
|---|---|
| `~/.config/opencode/opencode.json` | providers, models + limits, MCPs, plugins, compaction |
| `~/.config/opencode/AGENTS.md` | global policy: graph rules, caveman, shell hygiene, REA ban |
| `~/.config/opencode/plugins/rtk.ts` | RTK plugin **plus the after-tool compression hook** |
| `~/.config/opencode/plugins/rea-guard/index.ts` | REA model guard |
| `~/.config/opencode/plugins/rea-guard/package.json` | plugin manifest |
| `~/.config/opencode/secrets/*.key` | provider keys, `chmod 600` |
| `~/.claude/settings.json` | Claude Code to Headroom, models, RTK hooks |
| `~/Library/Application Support/rtk-proxy/rtk-proxy.toml` | proxy config |
| `~/Library/Application Support/rtk/pipeline.toml` | RTK pipeline (`rtk:posthook`) |
| `~/Library/LaunchAgents/app.rtk-ai.rtk-proxy.plist` | rtk-proxy autostart |
| `~/Library/LaunchAgents/com.headroom.default.plist` | Headroom autostart |
| `~/.headroom/deploy/default/manifest.json` | Headroom deployment (upstream + args) |
| `~/.headroom/deploy/default/run-headroom.sh` | Headroom env (chain + canary) |
| `~/vibecoding/AGENTS.md` | workspace policy |
| `~/vibecoding/CLAUDE.md` | bridge |
| `~/vibecoding/docs/*.md` | architecture, quality, onboarding, setup, design |
| `~/vibecoding/vibe-toolkit/` | ported toolkit (docs, prompts, templates, vendor mirror) |
| `~/vibecoding/vault/` | Obsidian vault |

### Installed software

| Tool | Version | Form |
|---|---|---|
| OpenCode | 2.3.2 | CLI + server |
| rtk | 1.2.1 | Homebrew |
| rtk-proxy | 1.2.1 | GitHub release asset, checksum-verified |
| Headroom | 0.41.0 | `uv tool install` |
| context-mode | 2.2.1 | npm + MCP + plugin |
| ponytail | 5.3.3 | npm plugin |
| caveman | 4.1.0 | npm plugin + skills |
| superpowers | 22f0b46 | git plugin |
| rea-agents | 6.9.0 | npm + MCP |
| @playwright/mcp | 0.0.86 | npm + MCP |
| codebase-memory-mcp | 0.12.1 | binary |
| serena | 2.1.1.dev0 | `uvx` from git |

### Measured results

| Metric | Value |
|---|---|
| RTK overall savings | 19.6K tokens (38.0%) |
| RTK after-hook on a 51KB result | 51,374 to 16,108 bytes (69%) |
| Headroom savings (OpenCode) | 11,019 tokens over 36 calls |
| Headroom on large Bash output | ~15% |
| REA tools available | 255 (plus 6 prompts) |

---

## License

MIT. The upstream projects keep their own licenses — check each before redistributing
its binaries in this repository.
