#!/bin/bash
# Auto-freeze (SIGSTOP) claude CLI processes whose tmux pane is not currently
# visible, and unfreeze (SIGCONT) the claude in each attached session's active
# pane. Reduces tmux server load and keystroke latency when many claude TUIs
# share one tmux server.
#
# Intended to be invoked from tmux hooks (after-select-pane, etc.) and once at
# startup. Idempotent: safe to run on every pane switch.

set -u

command -v tmux >/dev/null 2>&1 || exit 0

visible_ttys=$(tmux list-panes -a \
    -F '#{session_attached} #{window_active} #{pane_active} #{pane_tty}' \
    2>/dev/null \
  | awk '$1>0 && $2==1 && $3==1 {sub("/dev/","",$4); print $4}' \
  | sort -u)

for claude_pid in $(pgrep -x claude 2>/dev/null); do
    claude_tty=$(ps -o tty= -p "$claude_pid" 2>/dev/null | tr -d ' ')
    [ -z "$claude_tty" ] && continue
    [ "$claude_tty" = "?" ] && continue
    if printf '%s\n' "$visible_ttys" | grep -qFx "$claude_tty"; then
        kill -CONT "$claude_pid" 2>/dev/null || true
    else
        kill -STOP "$claude_pid" 2>/dev/null || true
    fi
done
