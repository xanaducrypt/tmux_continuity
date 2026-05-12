#!/usr/bin/env bash
# claude_autoresume.sh — tmux-resurrect strategy that ensures claude commands
# get a --resume <uuid> arg pointing at the most-recently-modified JSONL for
# the pane's cwd. Existing --resume args are preserved as-is.
#
# Source of truth: /home/manas.gupta/tmux_continuity/claude_autoresume.sh
# Installed at:    ~/.tmux/plugins/tmux-resurrect/strategies/claude_autoresume.sh
# (TPM updates may overwrite the installed copy; reinstall from source.)
# Debug log:       /home/manas.gupta/tmux_continuity/claude_autoresume.log

set -u

ORIGINAL_COMMAND="${1:-}"
DIRECTORY="${2:-}"
LOG=/home/manas.gupta/tmux_continuity/claude_autoresume.log

log() {
    # one-line tab-separated record: timestamp \t decision \t in_cmd \t in_dir \t out_cmd
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$(date -Iseconds)" "$1" "$ORIGINAL_COMMAND" "$DIRECTORY" "$2" >> "$LOG" 2>/dev/null || true
}

emit() {  # log <decision> <command>, echo <command>, exit 0
    log "$1" "$2"
    echo "$2"
    exit 0
}

# Defensive: any unexpected error → fall back to original command.
trap 'emit "trap-error" "$ORIGINAL_COMMAND"' ERR

# Already has --resume — preserve as-is.
if printf '%s\n' "$ORIGINAL_COMMAND" | grep -q -- '--resume'; then
    emit "already-has-resume" "$ORIGINAL_COMMAND"
fi

# No directory passed → can't look up history.
[ -n "$DIRECTORY" ] || emit "no-dir" "$ORIGINAL_COMMAND"

# Encode directory → claude project-dir name. Claude maps each of `/`, `_`, `.`
# to `-`. So /weka_team_data/manas.gupta/X becomes -weka-team-data-manas-gupta-X.
project_encoded="$(printf '%s' "$DIRECTORY" | sed 's|[/._]|-|g')"
project_dir="$HOME/.claude/projects/$project_encoded"

[ -d "$project_dir" ] || emit "no-project-dir:$project_dir" "$ORIGINAL_COMMAND"

# Most recently modified JSONL.
latest="$(ls -t "$project_dir"/*.jsonl 2>/dev/null | head -1)"
[ -n "$latest" ] || emit "no-jsonl:$project_dir" "$ORIGINAL_COMMAND"

uuid="$(basename "$latest" .jsonl)"
emit "resolved=$uuid" "$ORIGINAL_COMMAND --resume $uuid"
