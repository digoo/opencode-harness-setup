// REA guard — blocks REA MCP tool calls on Claude and GPT models.
//
// REA is banned with those models: using it risks the account being banned.
// An instruction in AGENTS.md is advisory; this is the enforcement point.
// The block happens at the tool layer, so it also covers subagents and any
// agent that has not read the rule.
//
// The check is on the session's selected model, resolved through the server,
// not on a hardcoded provider list: any model whose id looks like a Claude or
// GPT model is treated as banned.

const BANNED_PATTERNS = [
  /^claude/i,
  /^gpt-/i,
  /^gpt[0-9]/i,
  /^o[134](-|$)/i, // o1, o3, o4 reasoning models
  /^chatgpt/i,
]

/** Tool ids are `<server>_<tool>`; rea's tools all start with `rea_`. */
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
        // If the model cannot be resolved, fail closed: a banned model must
        // never reach REA because of a lookup error.
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
