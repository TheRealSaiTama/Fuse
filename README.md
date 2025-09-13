# FUSE — Parallel Multi‑Model Judge & Merge

[![Shell](https://img.shields.io/badge/shell-bash-121011.svg?logo=gnu-bash&logoColor=white)](#)
[![OS](https://img.shields.io/badge/OS-macOS%20%7C%20Linux-black.svg)](#)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](#license)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](#contributing)
[![Stars](https://img.shields.io/github/stars/TheRealSaiTama/Fuse?style=social)](https://github.com/TheRealSaiTama/Fuse)

**One prompt in → many model CLIs out (in parallel) → scoreboard → one concise “merged best” answer.**  
Pure Bash. Zero SDKs. Works with whatever model CLIs you already use (Qwen, Gemini, Ollama, LM Studio, OpenAI, Groq…).

---

## ✨ Why FUSE?

- **Parallel fan‑out.** Fire the *same* prompt at multiple model CLIs **at once**.
- **Scoreboard.** See latency, word count, and success/fail per provider.
- **Judge/Consensus.** Pick a judge model (or let FUSE pick the fastest) to merge all answers into a short, careful final.
- **Zero lock‑in.** No APIs or SDKs required—just shell commands. Your keys/config stay with your CLIs.
- **Tiny & hackable.** One portable script; easy to read and extend.

```
Prompt ─┬─► qwen CLI ─┐
        ├─► gemini CLI ─┤──► Scoreboard ─► Judge model ─► Final merged answer
        ├─► ollama CLI ─┘
        └─► openai CLI … 
```

---

## 🚀 Quick Start

> Requires: a POSIX shell (bash), plus the model CLIs you want to test.  
> Don’t have any installed yet? Use *mocks* below to try it instantly.

```bash
# 1) Get the script
git clone https://github.com/TheRealSaiTama/Fuse
cd Fuse
chmod +x fuse.sh

# 2) Create a providers.txt (quick mock demo)
cat > providers.txt <<'EOF'
fast:::bash -lc 'sleep 0.6; echo "(fast) Hello. Prompt: $PROMPT"'
slow:::bash -lc 'sleep 1.5; echo "(slow) Hi. Prompt: $PROMPT"'
EOF

# 3) Run it
./fuse.sh -m consensus "Say hello in one sentence."
```

Expected output (example):

```
FUSE — Parallel Multi-Model Judge & Merge
Providers: fast, slow
─────────────────────────────────────────
✓ fast     0.61s   6 words
✓ slow     1.50s   7 words

— JUDGE: fast —
Hello. Prompt: Say hello in one sentence.
```

---

## 🔧 Real Providers (edit to match your CLIs)

Create/Edit `providers.txt`. Each line is:

```
name:::command_with_$PROMPT
```

Examples:

```txt
qwen:::qwen -m qwen2.5 -p "$PROMPT"
gemini:::gemini -m gemini-1.5-pro -p "$PROMPT"
ollama:::ollama run llama3.1 "USER: $PROMPT"
openai:::openai chat.completions.create -m gpt-4o-mini -g user "$PROMPT"
```

> Any CLI that reads `"$PROMPT"` from env and prints a reply to **stdout** works.

Optional: auto‑detect installed CLIs and generate `providers.txt`:

```bash
./scripts/fuse-doctor.sh     # writes providers.txt based on what’s available
```

---

## 🧭 Usage

```bash
./fuse.sh [-c providers.txt] [-m raw|consensus|judgeonly] [-t timeout] [-j judge] "your prompt"
```

Common flows:

```bash
# Show each model's raw answer + timings (no judge)
./fuse.sh -m raw "Outline a 10-step Notion template launch."

# Parallel + judge-composed final answer (default)
./fuse.sh -m consensus "Draft a WhatsApp rebooking flow for salons."

# Pick a specific judge (instead of the fastest)
./fuse.sh -m consensus -j qwen "Pricing SMB onboarding?"

# Inspect the judge prompt used (for debugging)
./fuse.sh -m judgeonly "Prompt engineering best practices?"
```

**Flags**
- `-c` path to providers file (default: `providers.txt`)
- `-m` mode: `raw`, `consensus` (default), or `judgeonly`
- `-t` per‑provider timeout (seconds, default: `90`)
- `-j` judge provider name (must exist in `providers.txt`), otherwise fastest wins

**Exit codes**
- `0` success
- `124` provider timeout (per‑provider)
- non‑zero if judge fails (script falls back to raw display)

---

## 🧪 Dev & Testing

Install optional tooling:

```bash
# macOS
brew install shellcheck bats-core
# Ubuntu/Debian
sudo apt-get update && sudo apt-get install -y shellcheck bats
```

Run tests (uses mock providers, no network):

```bash
bats tests
```

Lint the shell:

```bash
shellcheck fuse.sh
```

---

## 🔐 Security & Privacy

- FUSE never sends data anywhere by itself; it only runs **your** CLIs.
- Secrets and API keys remain configured in those CLIs as you already manage them.
- Judge selection defaults to the fastest responder; use `-j` to force a specific, privacy‑scoped model if needed.

---

## 🧭 Troubleshooting

- **“Command not found”** → That provider’s CLI isn’t installed or not in `$PATH`. Remove the line from `providers.txt` or install the CLI.
- **Weird quoting** → Always wrap `$PROMPT` in quotes inside `providers.txt`: `"$PROMPT"`.  
- **Judge failed** → You’ll get the raw outputs instead. Try another judge with `-j` or increase `-t`.
- **Timeouts** → Increase `-t 180` for slower providers; failures show in the scoreboard.

---

## 🗺️ Roadmap

- `--md` to emit a Markdown report (scoreboard + final)
- `--grade` mode to pick a single winner via a rubric
- Built‑in “doctor” to generate `providers.txt` without a helper script
- Minimal TUI with fuzzy provider toggling

---

## 🤝 Contributing

PRs welcome! Good first issues: add provider recipes, improve docs, or wire up `--md` / `--grade`.

1. Fork → create a feature branch → commit → open PR.
2. Add or update tests under `tests/`.
3. Keep `fuse.sh` portable (macOS 12.x + Linux).

---

## 🧾 License

MIT © 2025 Keshav Jha. See [LICENSE](#license).

---

## 🙌 Credits

Built by **Keshav Jha (TheRealSaiTama)**.  
Shout‑out to everyone building slick CLI tooling and multi‑model workflows.
