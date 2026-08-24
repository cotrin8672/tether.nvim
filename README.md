# tether.nvim

Scoped, asynchronous inline AI editing for Neovim, powered by [OpenCode](https://opencode.ai/).

`tether.nvim` turns any Neovim motion or text object into a small OpenCode task. OpenCode can inspect the repository and discuss the change, but it can submit edits only to the range you selected. The result stays in the normal buffer until you explicitly accept or reject it.

## Requirements

- Neovim 0.11 or newer
- OpenCode 1.18 or newer, available as `opencode`
- `curl`
- [Snacks.nvim](https://github.com/folke/snacks.nvim) is optional; without it, task selection falls back to `vim.ui.select`

Run `:checkhealth tether` after installation to verify the environment.

Contributors can run the headless unit suite with `nvim --headless -u NONE -l tests/run.lua`. The opt-in `nvim --headless -u NONE -l tests/opencode_smoke.lua` test starts a real local OpenCode server and checks bundled-tool discovery, the dedicated agent, session creation, and abort without invoking an LLM.

## Installation

With lazy.nvim:

```lua
{
  "cotrin8672/tether.nvim",
  config = function()
    local tether = require("tether")

    tether.setup()

    -- tether.nvim intentionally creates no default mappings.
    vim.keymap.set("n", "gl", tether.operator, { expr = true, desc = "AI operator" })
    vim.keymap.set("x", "gl", tether.visual, { desc = "AI selection" })
    vim.keymap.set("n", "<leader>ao", tether.open)
    vim.keymap.set("n", "<leader>aa", tether.accept)
    vim.keymap.set("n", "<leader>ax", tether.reject)
  end,
}
```

The OpenCode server is lazy: calling `setup()` does not start a process. The first submitted task starts one server for the Neovim instance.

## Workflow

### Operator and text objects

The normal-mode mapping is an expression operator. Invoke it, then use any motion or text object:

```text
gliw            edit the inner word
glip            edit the inner paragraph
gl}             edit to the next paragraph
```

Tree-sitter and plugin-provided text objects work as long as they behave like normal Neovim operator motions. Once the range is known, tether asks for an instruction through `vim.ui.input` and starts the task asynchronously. Cancelling the prompt creates no task.

### Visual selections

Select text in characterwise, linewise, or blockwise Visual mode and press `gl`. Selections are inclusive, and reversed selections are normalized. A blockwise selection is treated as one continuous range from its normalized start to end, not as independent rectangular edits.

### Review and conversation

- `<leader>ao` opens the OpenCode conversation for the task under the cursor. Outside a task, it opens the task picker.
- `<leader>aa` accepts the proposal or the current manually edited contents and closes that task.
- `<leader>ax` aborts a running task, or restores the original selected text for a proposed task.

The OpenCode conversation opens in a floating terminal. Continue prompting there to revise the same task; each successful `tether_submit_target` replaces the current proposal in the selected range. Conversation history remains in OpenCode after the local task is closed.

## Task states

| State | Meaning |
| --- | --- |
| `starting` | The OpenCode server or session is being prepared. |
| `working` | OpenCode is processing the initial instruction. |
| `retrying` | A transient operation is being retried. |
| `waiting` | The session is idle without a proposal; continue in the conversation. |
| `revising` | OpenCode is working while a previous proposal remains visible. |
| `pending` | A proposal is in the buffer and awaits accept, reject, or revision. |
| `edited` | The tracked range changed outside tether; AI submissions will not overwrite it. |
| `error` | The server or task encountered an error; the buffer content is preserved. |

Signs and end-of-line virtual text show the effective state. Conflict state has priority over OpenCode activity.

## Parallel tasks and conflicts

Any number of tasks may run across buffers, and non-overlapping ranges in the same buffer may run concurrently. A new task is rejected only when its selected range overlaps an active task; adjacent ranges are allowed.

Each task tracks its target with extmarks and uses optimistic locking. Edits outside the tracked range do not interrupt it. If the tracked text differs from what tether expects, the task becomes `edited`, and later AI submissions are refused rather than overwriting the user's work. In that state, accept keeps the current text; reject asks before restoring the task's original snapshot.

For a modified buffer, tether supplies OpenCode with an in-memory buffer snapshot without saving the file. By default, modified buffers larger than 256 KiB are rejected so that stale on-disk contents are not mistaken for current context.

## Safety boundary

The bundled OpenCode agent may inspect the project with read/search/LSP/web tools, but file-writing, patch, shell, and sub-agent tools are denied. Its only edit path is `tether_submit_target(code)`.

`tether_submit_target` cannot choose a file, range, or task ID. tether resolves the OpenCode session to an existing task and validates the loopback token, payload size, buffer, extmark, modifiability, and expected text before calling `nvim_buf_set_text`. This boundary keeps repository exploration broad while keeping mutation scoped to the selected buffer range.

This is a guardrail, not a substitute for review: inspect every proposal before accepting it.

## Configuration

Defaults are shown below:

```lua
require("tether").setup({
  context = {
    max_buffer_bytes = 256 * 1024,
    max_submit_bytes = 2 * 1024 * 1024,
  },
  opencode = {
    command = "opencode",
    curl = "curl",
    minimum_version = "1.18.0",
    poll_interval_ms = 750,
    request_timeout_seconds = 15,
    server_start_timeout_ms = 10000,
  },
  ui = {
    picker = "auto", -- Snacks when available, otherwise vim.ui.select
    icons = {
      starting = "◌",
      working = "◌",
      retrying = "↻",
      waiting = "○",
      revising = "◌",
      pending = "●",
      edited = "!",
      error = "×",
    },
    float = {
      width = 0.88,
      height = 0.82,
      border = "rounded",
      title = " OpenCode ",
    },
  },
})
```

OpenCode authentication, model selection, global/project configuration, and `AGENTS.md` instructions remain OpenCode's responsibility. tether does not select a model. If `OPENCODE_CONFIG_CONTENT` already exists, tether merges its strict-JSON inline configuration with the tether agent and permission rules rather than replacing it.

OpenCode 1.18 does not reliably load `file://` plugins declared through inline configuration, so tether stages its bundled callback plugin in Neovim's cache and starts its private server with that cache as `OPENCODE_CONFIG_DIR`. If you already set `OPENCODE_CONFIG_DIR`, its custom agents and plugins are unavailable inside tether sessions; global/project settings and instructions are still discovered normally. `:checkhealth tether` reports this situation. Existing inline configuration must be strict JSON (not JSONC with comments or trailing commas) so Neovim can merge it safely.

## Troubleshooting

Start with `:checkhealth tether`. It reports the Neovim version, OpenCode availability and version, `curl`, and optional Snacks integration.

- **`opencode` or `curl` is not found:** put it on `PATH`, or set `opencode.command` / `opencode.curl` to the executable path.
- **A selection is rejected:** ensure the buffer is a normal, modifiable buffer; check that the range does not overlap another task; and save a modified buffer that exceeds `context.max_buffer_bytes`.
- **A task shows `edited`:** the selected text changed after the task started. Accept to keep the current text, or reject to restore the original text after confirmation.
- **A task shows `waiting`:** OpenCode became idle without calling `tether_submit_target`; open the conversation and ask it to complete and submit the replacement.
- **A task shows `error`:** open it again to restart the shared server and reattach to its persisted OpenCode session. The current buffer content is left untouched.
- **No Snacks picker appears:** Snacks is optional. Install it for the richer picker, or continue with the `vim.ui.select` fallback.

Tasks are kept only for the current Neovim process. OpenCode sessions may persist, but tether does not restore local tasks after Neovim restarts.
