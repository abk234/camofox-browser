# Camofox skill eval — results

**Task:** Cross-check what Camoufox is (official docs → Google → GitHub) and how it relates to camofox-browser. Produce findings + screenshots via MCP.

**Skill followed:** `camofox-browser` (health → MCP loop → summarize → close)

## Result summary

| Source | URL | Finding |
|--------|-----|---------|
| Official docs | https://camoufox.com/ | Open-source **anti-detect Firefox** for AI agents (author **daijro**). C++ fingerprint spoofing, Playwright/Juggler isolation, BrowserForge rotation. |
| Stealth docs | https://camoufox.com/stealth/ | Hides Playwright bindings; human-like mouse; active development in 2026 after a maintenance gap. |
| Google SERP | `camofox-browser jo-inc Camoufox` | Top hit: **jo-inc/camofox-browser**; snippets say it wraps Camoufox via `camoufox-js` for agent automation / OpenClaw. |
| GitHub | https://github.com/jo-inc/camofox-browser | Stealth headless browser for AI agents; ~10.8k★; includes `mcp/` directory. |

**Relation:** **Camoufox** = the stealth Firefox engine. **camofox-browser** = jo-inc’s agent-facing REST/MCP server that runs that engine.

## MCP tools exercised

`create_tab` → `snapshot` → `click` (Stealth Overview) → `snapshot` → `navigate` (`@google_search`) → `snapshot` → `navigate` (GitHub URL) → `screenshot` → `close_tab`

No captcha/block observed on Google.

## Artifacts

- `tmp/skill-eval/03-github-camofox-browser.png` (saved)
- MCP also returned screenshots for camoufox.com, stealth, and Google SERP in-session
