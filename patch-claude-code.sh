#!/usr/bin/env bash
set -euo pipefail

# patch-claude-code.sh — Rebalance Claude Code prompts to fix corner-cutting behavior
#
# What this does:
#   Patches the npm-installed @anthropic-ai/claude-code cli.js to rebalance
#   system prompt instructions that cause the model to cut corners, simplify
#   excessively, and defer complicated work.
#
# Requirements:
#   - Node.js >= 18
#   - npm
#
# Usage:
#   ./patch-claude-code.sh              # install (if needed), patch, repoint claude binary
#   ./patch-claude-code.sh --restore    # restore original cli.js and repoint to bun binary
#   ./patch-claude-code.sh --dry-run    # show what would be patched without modifying anything
#   ./patch-claude-code.sh --check      # check if patches are already applied
#   ./patch-claude-code.sh --watch      # install watcher to re-patch after auto-updates
#   ./patch-claude-code.sh --unwatch    # remove the watcher

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
OS="$(uname -s)"

# Watcher identifiers
PLIST_LABEL="com.user.claude-code-patcher"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
SYSTEMD_UNIT="claude-code-patcher.path"
SYSTEMD_SERVICE="claude-code-patcher.service"
SYSTEMD_DIR="$HOME/.config/systemd/user"

# --------------------------------------------------------------------------- #
# Resolve paths
# --------------------------------------------------------------------------- #

find_claude_bin() {
  local candidates=(
    "$(command -v claude 2>/dev/null || true)"
    "$HOME/.local/bin/claude"
    "$HOME/.claude/bin/claude"
    "/usr/local/bin/claude"
  )
  for c in "${candidates[@]}"; do
    if [[ -n "$c" && -e "$c" ]]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

find_bun_binary() {
  local versions_dir="$HOME/.local/share/claude/versions"
  if [[ -d "$versions_dir" ]]; then
    local latest
    latest=$(ls -1 "$versions_dir" 2>/dev/null | sort -V | tail -1)
    if [[ -n "$latest" ]]; then
      echo "$versions_dir/$latest"
      return 0
    fi
  fi
  return 1
}

ensure_npm_package() {
  local npm_root
  npm_root="$(npm root -g 2>/dev/null)" || {
    echo "ERROR: npm not found or npm root -g failed" >&2
    exit 1
  }

  local cli_js="$npm_root/@anthropic-ai/claude-code/cli.js"

  if [[ ! -f "$cli_js" ]]; then
    echo "Claude Code npm package not found. Installing..." >&2
    npm install -g @anthropic-ai/claude-code || {
      echo "ERROR: Failed to install @anthropic-ai/claude-code" >&2
      exit 1
    }
  fi

  echo "$cli_js"
}

get_version() {
  local cli_js="$1"
  local pkg_json
  pkg_json="$(dirname "$cli_js")/package.json"
  if [[ -f "$pkg_json" ]]; then
    node -e "console.log(require('$pkg_json').version)" 2>/dev/null || echo "unknown"
  else
    node -e "
      const src = require('fs').readFileSync('$cli_js', 'utf8');
      const m = src.match(/Version: ([\\d.]+)/);
      console.log(m ? m[1] : 'unknown');
    " 2>/dev/null || echo "unknown"
  fi
}

# --------------------------------------------------------------------------- #
# Patch definitions
# --------------------------------------------------------------------------- #

PATCH_SCRIPT='
const fs = require("fs");
const cli_js = process.env.CLI_JS;
const dryRun = process.env.DRY_RUN === "1";
const checkOnly = process.env.CHECK_ONLY === "1";

let src = fs.readFileSync(cli_js, "utf8");
let applied = 0;
let skipped = 0;
let alreadyApplied = 0;

function patch(label, old, replacement) {
  if (src.includes(replacement)) {
    alreadyApplied++;
    if (!checkOnly) console.log("  ALREADY APPLIED: " + label);
    return;
  }
  if (!src.includes(old)) {
    skipped++;
    console.log("  SKIP (not found): " + label);
    return;
  }
  if (checkOnly) {
    console.log("  NOT APPLIED: " + label);
    return;
  }
  const occurrences = src.split(old).length - 1;
  src = src.split(old).join(replacement);
  applied += occurrences;
  console.log("  OK (" + occurrences + "x): " + label);
}

// Patches 1-3: brevity rules in main system prompt.
// Fixed upstream in v2.1.100; kept in case an older version is installed.
patch(
    "#1  Output efficiency (fixed upstream v2.1.100)",
    "IMPORTANT: Go straight to the point. Try the simplest approach first without going in circles. Do not overdo it. Be extra concise.",
    "IMPORTANT: Go straight to the point without going in circles. Choose the approach that correctly and completely solves the problem. Do not add unnecessary complexity, but do not sacrifice correctness or completeness for the sake of simplicity either."
);

patch(
    "#2  Brevity paragraph (fixed upstream v2.1.100)",
    "Keep your text output brief and direct. Lead with the answer or action, not the reasoning. Skip filler words, preamble, and unnecessary transitions. Do not restate what the user said \u2014 just do it. When explaining, include only what is necessary for the user to understand.",
    "Keep your text output brief and direct. Skip filler words, preamble, and unnecessary transitions. Do not restate what the user said \u2014 just do it. When explaining, include what is necessary for the user to understand. Note: these communication guidelines apply to your messages to the user, NOT to the thoroughness of your code changes or investigation depth."
);

patch(
    "#3  One sentence rule (fixed upstream v2.1.100)",
    "If you can say it in one sentence, don\u0027t use three. Prefer short, direct sentences over long explanations. This does not apply to code or tool calls.",
    "Prefer short, direct sentences over long explanations in your messages. This does not apply to code, tool calls, or the thoroughness of your implementation work."
);

// Patches 4-11: still present in v2.1.109+.
patch(
    "#4  Anti-gold-plating — allow necessary related work",
    "Don\u0027t add features, refactor code, or make \"improvements\" beyond what was asked. A bug fix doesn\u0027t need surrounding code cleaned up. A simple feature doesn\u0027t need extra configurability. Don\u0027t add docstrings, comments, or type annotations to code you didn\u0027t change. Only add comments where the logic isn\u0027t self-evident.",
    "Don\u0027t add unrelated features or speculative improvements. However, if adjacent code is broken, fragile, or directly contributes to the problem being solved, fix it as part of the task. A bug fix should address related issues discovered during investigation. Don\u0027t add docstrings, comments, or type annotations to code you didn\u0027t change. Only add comments where the logic isn\u0027t self-evident."
);

patch(
    "#5  Error handling — use judgment instead of blanket skip",
    "Don\u0027t add error handling, fallbacks, or validation for scenarios that can\u0027t happen. Trust internal code and framework guarantees. Only validate at system boundaries (user input, external APIs). Don\u0027t use feature flags or backwards-compatibility shims when you can just change the code.",
    "Add error handling and validation at real boundaries where failures can realistically occur (user input, external APIs, I/O, network). Trust internal code and framework guarantees for truly internal paths. Don\u0027t use feature flags or backwards-compatibility shims when you can just change the code."
);

patch(
    "#6  Three lines rule — use judgment",
    "Three similar lines of code is better than a premature abstraction.",
    "Use judgment about when to extract shared logic. Avoid premature abstractions for hypothetical reuse, but do extract when duplication causes real maintenance risk."
);

patch(
    "#7  Gold-plate subagent — work like a senior dev",
    "Complete the task fully\u2014don\u0027t gold-plate, but don\u0027t leave it half-done.",
    "Complete the task fully and thoroughly. Do the work that a careful senior developer would do, including edge cases and fixing obviously related issues you discover. Don\u0027t add purely cosmetic or speculative improvements unrelated to the task."
);

patch(
    "#8  Explore agent — thoroughness over speed",
    "NOTE: You are meant to be a fast agent that returns output as quickly as possible. In order to achieve this you must:\n- Make efficient use of the tools that you have at your disposal: be smart about how you search for files and implementations\n- Wherever possible you should try to spawn multiple parallel tool calls for grepping and reading files\n\nComplete the user\u0027s search request efficiently and report your findings clearly.",
    "NOTE: Be thorough in your exploration. Use efficient search strategies but do not sacrifice completeness for speed:\n- Make efficient use of the tools that you have at your disposal: be smart about how you search for files and implementations\n- Wherever possible you should try to spawn multiple parallel tool calls for grepping and reading files\n- When the caller requests thorough exploration, exhaust all reasonable search strategies before reporting\n\nComplete the user\u0027s search request thoroughly and report your findings clearly."
);

patch(
    "#9  Tone — appropriate detail, not just short",
    "Your responses should be short and concise.",
    "Your responses should be clear and appropriately detailed for the complexity of the task."
);

patch(
    "#10 Subagent output — allow useful code context",
    "Include code snippets only when the exact text is load-bearing",
    "Include code snippets when they provide useful context"
);

patch(
    "#11 Scope matching — allow necessary adjacent work",
    "Match the scope of your actions to what was actually requested.",
    "Match the scope of your actions to what was actually requested, but do address closely related issues you discover during the work when fixing them is clearly the right thing to do."
);

// Patches 12-15: new targets in v2.1.109+.
patch(
    "#12 Thinking suppression — remove anti-thinking bias",
    "on simpler user messages, it\u0027s best to respond or act directly without thinking unless further reasoning is necessary. On more complex tasks, you should feel free to reason as much as needed for best results but without overthinking. Avoid unnecessary thinking in response to simple user messages.",
    "Think as much as is useful for the task. Err on the side of more thinking when the task is non-trivial, when correctness matters, or when there is any ambiguity. Use thinking to plan your approach, catch errors, and verify your work before acting."
);

patch(
    "#13 End-of-turn summary — scale to complexity",
    "End-of-turn summary: one or two sentences. What changed and what\u0027s next. Nothing else.\n\nMatch responses to the task: a simple question gets a direct answer, not headers and sections.",
    "End-of-turn summary: briefly describe what changed and what\u0027s next. Scale the detail to the complexity of the work \u2014 a one-line fix gets one sentence, a multi-file refactor deserves a paragraph. Include caveats, partial completions, or discoveries the user should know about.\n\nMatch responses to the task: a simple question gets a direct answer, not headers and sections."
);

patch(
    "#14 Code comments — use judgment instead of blanket ban",
    "In code: default to writing no comments. Never write multi-paragraph docstrings or multi-line comment blocks \u2014 one short line max. Don\u0027t create planning, decision, or analysis documents unless the user asks for them \u2014 work from conversation context, not intermediate files.",
    "In code: prefer self-documenting code over comments. Add comments where the logic is non-obvious or where a future reader would need context about why, not what. Keep docstrings focused but not artificially short. Don\u0027t create planning, decision, or analysis documents unless the user asks for them \u2014 work from conversation context, not intermediate files."
);

patch(
    "#15 Subagent report quality — allow richer reports",
    "the caller will relay this to the user, so it only needs the essentials.",
    "the caller will relay this to the user. Include the essentials plus any discoveries, caveats, or context that would help the caller make good decisions."
);

// ===========================================================================
// Results
// ===========================================================================
if (checkOnly) {
  console.log("\n" + alreadyApplied + " applied, " + (11 - alreadyApplied - skipped) + " not applied, " + skipped + " not found in this version");
  process.exit(alreadyApplied === 11 ? 0 : 1);
}

if (!dryRun) {
  fs.writeFileSync(cli_js, src, "utf8");
}
console.log("\nPatches applied: " + applied + ", already applied: " + alreadyApplied + ", skipped: " + skipped);
if (dryRun) console.log("(dry run — no files modified)");
if (skipped > 3) {
  console.log("WARNING: many patches skipped — Claude Code may have changed its prompt format.");
}
'

# --------------------------------------------------------------------------- #
# Apply patches (shared logic)
# --------------------------------------------------------------------------- #

apply_patches() {
  local cli_js="$1"
  local quiet="${2:-}"

  local backup="$cli_js.backup"
  if [[ ! -f "$backup" ]]; then
    cp "$cli_js" "$backup"
    [[ -z "$quiet" ]] && echo "Backed up to $backup"
  fi

  DRY_RUN=0 CHECK_ONLY=0 CLI_JS="$cli_js" node -e "$PATCH_SCRIPT"

  local patched_version
  patched_version=$(node "$cli_js" --version 2>&1 || true)
  if [[ -z "$patched_version" || "$patched_version" == *"Error"* ]]; then
    echo "ERROR: patched cli.js failed to run, restoring backup" >&2
    cp "$backup" "$cli_js"
    return 1
  fi
  [[ -z "$quiet" ]] && echo "Verified: $patched_version"
  return 0
}

# --------------------------------------------------------------------------- #
# Full patch cycle: sync npm package to bun version, patch, repoint symlink
# --------------------------------------------------------------------------- #

full_patch_cycle() {
  local quiet="${1:-}"

  # Find latest bun binary version
  local versions_dir="$HOME/.local/share/claude/versions"
  local bun_version=""
  if [[ -d "$versions_dir" ]]; then
    bun_version=$(ls -1 "$versions_dir" 2>/dev/null | sort -V | tail -1)
  fi

  local npm_root
  npm_root="$(npm root -g 2>/dev/null)" || return 1
  local cli_js="$npm_root/@anthropic-ai/claude-code/cli.js"
  local pkg_json="$npm_root/@anthropic-ai/claude-code/package.json"

  # Sync npm package version to match bun binary
  if [[ -n "$bun_version" && -f "$pkg_json" ]]; then
    local npm_version
    npm_version=$(node -e "console.log(require('$pkg_json').version)" 2>/dev/null || echo "")
    if [[ "$npm_version" != "$bun_version" ]]; then
      [[ -z "$quiet" ]] && echo "Updating npm package: $npm_version -> $bun_version"
      npm install -g "@anthropic-ai/claude-code@$bun_version" 2>/dev/null || return 1
      rm -f "$cli_js.backup"  # stale backup
    fi
  fi

  if [[ ! -f "$cli_js" ]]; then
    [[ -z "$quiet" ]] && echo "npm cli.js not found, installing..."
    npm install -g @anthropic-ai/claude-code 2>/dev/null || return 1
  fi

  apply_patches "$cli_js" "$quiet"

  # Repoint claude symlink
  local claude_bin
  claude_bin=$(find_claude_bin) || return 1
  if [[ "$(readlink "$claude_bin" 2>/dev/null)" != "$cli_js" ]]; then
    ln -sf "$cli_js" "$claude_bin"
    [[ -z "$quiet" ]] && echo "Repointed $claude_bin -> $cli_js"
  fi
}

# --------------------------------------------------------------------------- #
# --watch: platform-specific file watcher
# --------------------------------------------------------------------------- #

install_watch_macos() {
  local versions_dir="$HOME/.local/share/claude/versions"
  local node_path
  node_path="$(command -v node)"

  mkdir -p "$HOME/Library/LaunchAgents"

  cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$PLIST_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$SCRIPT_PATH</string>
    <string>--apply-quiet</string>
  </array>
  <key>WatchPaths</key>
  <array>
    <string>$versions_dir</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$(dirname "$node_path"):$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>StandardOutPath</key>
  <string>$HOME/.claude/patch.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/.claude/patch.log</string>
  <key>RunAtLoad</key>
  <false/>
</dict>
</plist>
EOF

  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  launchctl load "$PLIST_PATH"

  echo "Installed launchd agent: $PLIST_LABEL"
  echo "Watches: $versions_dir"
}

uninstall_watch_macos() {
  if [[ -f "$PLIST_PATH" ]]; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    echo "Removed launchd agent: $PLIST_LABEL"
  else
    echo "No launchd agent found at $PLIST_PATH"
  fi
}

install_watch_linux() {
  local versions_dir="$HOME/.local/share/claude/versions"
  local node_path
  node_path="$(command -v node)"

  mkdir -p "$SYSTEMD_DIR"

  # .path unit — watches the versions directory
  cat > "$SYSTEMD_DIR/$SYSTEMD_UNIT" << EOF
[Unit]
Description=Watch for Claude Code updates

[Path]
PathChanged=$versions_dir
Unit=$SYSTEMD_SERVICE

[Install]
WantedBy=default.target
EOF

  # .service unit — runs the patcher
  cat > "$SYSTEMD_DIR/$SYSTEMD_SERVICE" << EOF
[Unit]
Description=Re-patch Claude Code after update

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH --apply-quiet
Environment=PATH=$(dirname "$node_path"):$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
Environment=HOME=$HOME
StandardOutput=append:$HOME/.claude/patch.log
StandardError=append:$HOME/.claude/patch.log
EOF

  systemctl --user daemon-reload
  systemctl --user enable --now "$SYSTEMD_UNIT"

  echo "Installed systemd path unit: $SYSTEMD_UNIT"
  echo "Watches: $versions_dir"
}

uninstall_watch_linux() {
  if [[ -f "$SYSTEMD_DIR/$SYSTEMD_UNIT" ]]; then
    systemctl --user disable --now "$SYSTEMD_UNIT" 2>/dev/null || true
    rm -f "$SYSTEMD_DIR/$SYSTEMD_UNIT" "$SYSTEMD_DIR/$SYSTEMD_SERVICE"
    systemctl --user daemon-reload
    echo "Removed systemd units: $SYSTEMD_UNIT, $SYSTEMD_SERVICE"
  else
    echo "No systemd path unit found"
  fi
}

install_watch() {
  case "$OS" in
    Darwin)  install_watch_macos ;;
    Linux)   install_watch_linux ;;
    *)
      echo "ERROR: --watch is not supported on $OS"
      echo "You can re-run this script manually after updates: $0"
      exit 1
      ;;
  esac

  echo "Log: ~/.claude/patch.log"
  echo ""
  echo "When Claude Code auto-updates (new binary in versions/), the watcher will:"
  echo "  1. Update the npm package to match"
  echo "  2. Re-apply all prompt patches"
  echo "  3. Repoint the claude symlink to patched npm cli.js"
  echo ""
  echo "To remove: $0 --unwatch"
}

uninstall_watch() {
  case "$OS" in
    Darwin)  uninstall_watch_macos ;;
    Linux)   uninstall_watch_linux ;;
    *)       echo "No watcher to remove on $OS" ;;
  esac
}

# --------------------------------------------------------------------------- #
# Commands
# --------------------------------------------------------------------------- #

MODE="${1:-apply}"

case "$MODE" in
  --restore)
    uninstall_watch

    # Restore npm cli.js from backup
    CLI_JS=$(ensure_npm_package)
    BACKUP="$CLI_JS.backup"
    if [[ -f "$BACKUP" ]]; then
      cp "$BACKUP" "$CLI_JS"
      echo "Restored $CLI_JS from backup"
    fi

    # Repoint to bun binary
    CLAUDE_BIN=$(find_claude_bin) || { echo "ERROR: claude not found"; exit 1; }
    BUN_BIN=$(find_bun_binary) || true
    if [[ -n "${BUN_BIN:-}" && -f "$BUN_BIN" ]]; then
      # Remove existing file/symlink before creating new symlink
      rm -f "$CLAUDE_BIN"
      ln -s "$BUN_BIN" "$CLAUDE_BIN"
      echo "Repointed $CLAUDE_BIN -> $BUN_BIN"
    else
      echo "Bun binary not found — run: claude update"
    fi
    exit 0
    ;;

  --dry-run)
    CLI_JS=$(ensure_npm_package)
    VERSION=$(get_version "$CLI_JS")
    echo "Claude Code v$VERSION — dry run"
    echo ""
    DRY_RUN=1 CHECK_ONLY=0 CLI_JS="$CLI_JS" node -e "$PATCH_SCRIPT"
    exit 0
    ;;

  --check)
    CLI_JS=$(ensure_npm_package)
    VERSION=$(get_version "$CLI_JS")
    echo "Claude Code v$VERSION — checking patch status"
    echo ""
    DRY_RUN=0 CHECK_ONLY=1 CLI_JS="$CLI_JS" node -e "$PATCH_SCRIPT"
    exit $?
    ;;

  --watch)
    echo "=== Applying patches ==="
    full_patch_cycle
    echo ""
    echo "=== Installing file watcher ==="
    install_watch
    exit 0
    ;;

  --unwatch)
    uninstall_watch
    exit 0
    ;;

  --apply-quiet)
    # Called by launchd/systemd — run full cycle quietly
    echo "[$(date)] Auto-patch triggered"
    full_patch_cycle "quiet" 2>&1
    echo "[$(date)] Done"
    exit 0
    ;;

  apply|"")
    # fall through to main logic below
    ;;

  --help|-h)
    echo "Usage: $0 [--dry-run | --restore | --check | --watch | --unwatch | --help]"
    echo ""
    echo "  (no args)    Install npm package if needed, apply patches, repoint claude binary"
    echo "  --watch      Apply patches + install watcher to re-patch after auto-updates"
    echo "               macOS: launchd agent  |  Linux: systemd path unit"
    echo "  --unwatch    Remove the watcher"
    echo "  --dry-run    Show what would be patched without modifying anything"
    echo "  --check      Check if patches are already applied"
    echo "  --restore    Restore everything to original state"
    echo "  --help       Show this help"
    exit 0
    ;;

  *)
    echo "Unknown option: $MODE"
    echo "Run $0 --help for usage"
    exit 1
    ;;
esac

# --------------------------------------------------------------------------- #
# Main: one-shot apply
# --------------------------------------------------------------------------- #

echo "=== Claude Code Prompt Patcher ==="
echo ""

CLAUDE_BIN=$(find_claude_bin) || {
  echo "ERROR: claude binary not found in PATH or common locations"
  exit 1
}
echo "Claude binary: $CLAUDE_BIN"
if [[ -L "$CLAUDE_BIN" ]]; then
  echo "Currently points to: $(readlink "$CLAUDE_BIN" 2>/dev/null || echo '?')"
fi

CLI_JS=$(ensure_npm_package)
VERSION=$(get_version "$CLI_JS")
echo "NPM cli.js: $CLI_JS"
echo "Version: $VERSION"
echo ""

apply_patches "$CLI_JS"

echo ""
if [[ "$(readlink "$CLAUDE_BIN" 2>/dev/null)" == "$CLI_JS" ]]; then
  echo "Claude binary already points to npm cli.js"
else
  echo "Repointing $CLAUDE_BIN -> $CLI_JS"
  ln -sf "$CLI_JS" "$CLAUDE_BIN"
fi

echo ""
echo "Done. Start a new claude session to use patched prompts."
echo ""
echo "To survive auto-updates:  $0 --watch"
echo "To restore original:      $0 --restore"
