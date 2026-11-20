// Drop-in handler for RTK's OpenCode plugin.
//
// Add to ~/.config/opencode/plugins/rtk.ts and register it in BOTH the V2
// `setup()` and the V1 `server()` entrypoints. Requires `spawn` from
// node:child_process.
//
// Why: the `term` filter — the one that actually compresses — only runs at
// `hook.after_tool`. The proxy cannot reach that position, so the agent-side
// hook is where the saving happens. RTK's stock plugin registers
// `execute.before` only.
//
// Measured: 51,374 bytes -> 16,108 bytes (69% reduction) on a large tool result.

export async function handleAfterToolHook(rtkBin: string, event: any) {
  if (!event || event.status === "error") return
  if (process.env.RTK_DISABLED === "1") return

  const result = event.result ?? {}
  const output = result.output
  if (!output || typeof output !== "object") return

  // OpenCode's shell tool reports {exitCode, output, wallTimeSeconds}.
  // The text is at result.output.output — NOT result.output.stdout.
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

// Registration snippet for the V2 entrypoint:
//
//   await ctx?.tool?.hook?.("execute.after", (e: any) => handleAfterToolHook(rtkBin, e))
//
// Registration snippet for the V1 entrypoint:
//
//   "tool.execute.after": (input: any, output: any) => handleAfterToolHook(rtkBin, input),
