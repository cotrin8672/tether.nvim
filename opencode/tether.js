import { tool } from "@opencode-ai/plugin"

const allowedTools = new Set([
  "read",
  "grep",
  "glob",
  "list",
  "lsp",
  "webfetch",
  "websearch",
  "skill",
  "todowrite",
  "todoread",
  "tether_submit_target",
])

const TetherPlugin = async () => ({
  tool: {
    tether_submit_target: tool({
      description:
        "Submit the complete replacement text for the editor-owned target. This is the only way to change code in a tether session.",
      args: {
        code: tool.schema.string().describe("The complete final replacement for the selected target, without Markdown fences"),
      },
      async execute(args, context) {
        const url = process.env.TETHER_CALLBACK_URL
        const token = process.env.TETHER_CALLBACK_TOKEN
        if (!url || !token) {
          return "Submission rejected: the Neovim callback is not configured"
        }
        try {
          const response = await fetch(url, {
            method: "POST",
            headers: {
              authorization: `Bearer ${token}`,
              "content-type": "application/json",
            },
            body: JSON.stringify({ session_id: context.sessionID, code: args.code }),
          })
          const result = await response.json().catch(() => ({}))
          if (!response.ok || result.ok !== true) {
            return `Submission rejected: ${result.error || `callback returned HTTP ${response.status}`}`
          }
          return "The proposal was applied to the Neovim target and is awaiting human review."
        } catch (error) {
          return `Submission rejected: ${error instanceof Error ? error.message : String(error)}`
        }
      },
    }),
  },
  "tool.execute.before": async (input) => {
    if (!allowedTools.has(input.tool)) {
      throw new Error(`Tool '${input.tool}' is disabled in a tether session`)
    }
  },
})

export default {
  id: "tether.nvim",
  server: TetherPlugin,
}
