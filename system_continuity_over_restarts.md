# system_continuity_over_restarts

**The single source of truth** for how this workstation (`strategy-dev-manas.gupta`, owner `manas.gupta`) keeps tmux + claude sessions alive across reboots. If you (human or Claude session) need to understand, verify, debug, extend, or roll back this setup — read this file end to end before touching anything.

---

## 1. What this gives you

After any future reboot:

1. `tmux.service` (a user systemd unit, no sudo required) starts the tmux daemon on boot.
2. `tmux-continuum` automatically restores the last saved tmux layout (sessions, windows, panes, cwds, pane contents).
3. `tmux-resurrect` relaunches each pane's saved command. Bash panes come back as bash; claude panes come back as `claude --resume <uuid>`.
4. A custom resurrect strategy script (`claude_autoresume.sh`) ensures every claude pane gets a `--resume <uuid>` argument — preserving an existing one if present, or auto-injecting the most-recently-modified session JSONL's UUID for the pane's cwd.
5. You SSH in, `tmux attach`, work continues.

Zero post-reboot manual work. Long conversations (>200k tokens) show a "Resume from summary" prompt on first attach — one keystroke each.

## 2. Timeline of what was done

| Date (2026) | Phase | Action |
|---|---|---|
| May 8 | Discovery | Inventoried 45 tmux sessions, 58 claude processes, 9 stale `(deleted)` cwds, 6 standalone services |
| May 11 | Phase A — hardening | (a) Migrated `~/.local/share/tmux/resurrect/` → symlink to `/weka_user_data/manas.gupta/state/tmux_resurrect/` (durable on NFS). (b) Wrote `~/.config/systemd/user/tmux.service`, enabled with `loginctl enable-linger` (no sudo via `set-self-linger` polkit action). (c) Repaired stale cwds in 3 bash panes via `tmux send-keys cd …`. |
| May 11 | Phase A — manual cleanup | Walked the 6 claude panes that still had stale cwds: `/exit` → `cd <new>` → `claude --resume <uuid>`. Created 5 project-dir symlinks + 1 file-level symlink in `~/.claude/projects/` to bridge old-encoding (`-weka-user-data-manas-gupta-…`) to new-encoding (`-weka-team-data-manas-team-manas-gupta-…`) because `/weka_user_data/manas.gupta` is itself a root-owned symlink to `/weka_team_data/manas_team/manas.gupta/` |
| May 11 | Phase B — auto-resume | Wrote `claude_autoresume.sh` (resurrect strategy). Added `~claude` to `@resurrect-processes` and `@resurrect-strategy-claude 'autoresume'` in `.tmux.conf`. Smoke-tested 4 input cases, all passed |
| May 12 | RAM upgrade reboot | IT bumped RAM from 12 GB → 48 GB. System rebooted. tmux.service auto-started, 36 sessions restored, strategy ran 26 times (16 `resolved=<uuid>`, 10 `already-has-resume`, 0 errors), 26 claude conversations came back |
| May 12 | KillMode cleanup | Swapped `tmux.service` from `Type=forking + KillMode=none` (deprecated) → `Type=oneshot + RemainAfterExit=yes` (cleaner, no deprecation warning) |
| May 12 | Simplification pass | Replaced plugin-dir copy of `claude_autoresume.sh` with a symlink to source-of-truth (single source, TPM `git pull` preserves untracked symlinks). Deleted stale backups (`~/.local/share/tmux/resurrect.local_backup/` 24 MB + `tmux.service.killmode-none-backup`). Removed dead `@continuum-boot 'on'` line from `.tmux.conf` (and unset it from running tmux server). |
| May 12 | Robustness audit | Added `RequiresMountsFor=/weka_user_data/manas.gupta` to `tmux.service` (closes boot-time NFS race). Moved master doc into `~/tmux_continuity/` git repo (old path is now a backward-compat symlink). Added `.gitignore` for the log; committed strategy script, master doc, and `.tmux.conf` updates; pushed to GitHub (`xanaducrypt/tmux_continuity`). Local-disk loss is now recoverable via `git clone`. |

## 3. Critical facts / constraints

These are non-obvious facts about the system that any debugger needs to know.

- **User `manas.gupta` has NO sudo on this machine.** Every fix must use user-level mechanisms (user-systemd, self-linger, `~/.config/`, etc.).
- **Polkit allows `loginctl enable-linger` without sudo** when called *without a username argument* (uses the `set-self-linger` action which defaults to `allow_any: yes` on Ubuntu 22.04 / systemd 249). The form `loginctl enable-linger <username>` requires admin auth.
- **`/weka_user_data/manas.gupta` is a root-owned symlink** to `/weka_team_data/manas_team/manas.gupta/`. Both paths resolve to the same physical directory. Process `getcwd()` returns the physical path (`/weka_team_data/…`); bash `$PWD` shows the logical (`/weka_user_data/…`).
- **Claude encodes a working directory to a project-dir name** by mapping each of `/`, `_`, `.` to `-`. Example: `/weka_team_data/manas_team/manas.gupta/alpha_hft/strategy` → `-weka-team-data-manas-team-manas-gupta-alpha-hft-strategy`.
- **The same workspace can have two project-dir encodings** because of the `/weka_user_data` symlink. Claudes started before the symlink existed (old encoding `-weka-user-data-manas-gupta-…`) need a symlink in `~/.claude/projects/` to be findable via the new encoding.
- **`tmux-resurrect` saves a new layout file only when state changes** (it compares with the previous save and deletes identical ones). So absence of a new `tmux_resurrect_<timestamp>.txt` does NOT mean continuum stopped — check `pane_contents.tar.gz` mtime instead.
- **`/home/manas.gupta` is on local disk** (`/dev/mapper/ubuntu--vg-ubuntu--lv`) — survives reboot. `/weka_*` paths are NFS to a separate cluster — fully durable.

## 4. Exhaustive list of installed/modified files

| Path | What it is | Who reads/writes |
|---|---|---|
| `~/.tmux.conf` → `/home/manas.gupta/tmux_continuity/.tmux.conf` (symlinked) | tmux config; sets `@resurrect-processes` and `@resurrect-strategy-claude` | tmux at startup; `tmux source-file` |
| `/home/manas.gupta/tmux_continuity/claude_autoresume.sh` | The strategy script (+x, ~50 lines). Single source of truth. | Edit here |
| `~/.tmux/plugins/tmux-resurrect/strategies/claude_autoresume.sh` | **Symlink** → `/home/manas.gupta/tmux_continuity/claude_autoresume.sh`. Resurrect invokes via this path. | tmux-resurrect at restore time |
| `/home/manas.gupta/tmux_continuity/claude_autoresume.log` | TSV log written by the strategy script on every invocation | Strategy script (write); humans/Claude (read) |
| `~/.config/systemd/user/tmux.service` | Boots tmux on system start. `Type=oneshot + RemainAfterExit=yes` | systemd-user manager at boot |
| `~/.local/share/tmux/resurrect` → `/weka_user_data/manas.gupta/state/tmux_resurrect/` (symlinked) | The resurrect saves directory (durable on Weka) | tmux-continuum (write every 1 min on state change); tmux-resurrect (read on restore) |
| `~/.claude/projects/<encoded-cwd>/*.jsonl` | Claude session histories on local disk. Survive reboot | claude (write); strategy script (read mtime to pick latest) |
| Linger | `loginctl show-user manas.gupta -p Linger` must print `Linger=yes` | Enables user-systemd to run pre-SSH-login |

### Project-dir symlinks under `~/.claude/projects/`

Created during Phase A to bridge old → new encoding for 6 workspaces:

| Symlink (new encoding) | Target (old encoding) |
|---|---|
| `-weka-team-data-manas-team-manas-gupta-strategy-factory` | `-weka-user-data-manas-gupta-strategy-factory` |
| `-weka-team-data-manas-team-manas-gupta-dashboards` | `-weka-user-data-manas-gupta-dashboards` |
| `-weka-team-data-manas-team-manas-gupta-scripts-HF10-Expenses` | `-weka-user-data-manas-gupta-scripts-HF10-Expenses` |
| `-weka-team-data-manas-team-manas-gupta-mfqr` | `-weka-user-data-manas-gupta-mfqr` |
| `-weka-team-data-manas-team-manas-gupta-scripts-index-adjustment` | `-weka-user-data-manas-gupta-scripts-index-adjustment` |
| `-weka-team-data-manas-team-manas-gupta-alpha-hft-strategy/435b413b-…jsonl` | (file-level symlink — the new dir already existed with newer sessions) |

If any of these symlinks goes missing, the strategy log will show `no-project-dir:<path>` for the affected workspace and that pane will fall back to plain `claude` on next restore. Recreate with `ln -s <target> <symlink>`.

## 5. How the reboot flow works (step by step)

1. System boots. `user@8005.service` starts because linger is enabled for `manas.gupta`.
2. systemd-user processes user units. `tmux.service` (oneshot) runs `ExecStart=/usr/bin/tmux new-session -d -s _bootstrap`.
3. tmux daemon starts, sources `~/.tmux.conf`. TPM plugin manager loads tmux-resurrect and tmux-continuum.
4. tmux-continuum's init hook fires (because `@continuum-restore 'on'`). It locates the latest save via the symlink `~/.local/share/tmux/resurrect/last`.
5. tmux-resurrect parses the save file (`tmux_resurrect_<timestamp>.txt` on Weka). Recreates sessions/windows/panes with their original cwds.
6. For each pane, resurrect checks `pane_full_command` against `@resurrect-processes`. With `~claude` whitelisted (the `~` means "match anywhere in the command via regex"), every claude pane matches.
7. Because `@resurrect-strategy-claude 'autoresume'` is set, resurrect calls `~/.tmux/plugins/tmux-resurrect/strategies/claude_autoresume.sh "$pane_full_command" "$dir"`.
8. The script writes one tab-separated log line to `~/tmux_continuity/claude_autoresume.log` and prints the (possibly augmented) command to stdout.
9. Resurrect captures stdout and does `tmux send-keys -t <pane> "<augmented_command>" C-m`.
10. Each pane sees `claude --resume <uuid>` typed and pressed Enter. Claude loads the JSONL and resumes the conversation.
11. User SSHes in any time after boot, runs `tmux attach`, picks up work.

Long conversations (>200k tokens) show "Resume from summary / Resume full session / Don't ask me again" on first attach — one keystroke each.

## 6. Quick health-check after any reboot

```bash
# Run all checks in sequence:

# (1) System is up, linger survived
uptime
loginctl show-user manas.gupta -p Linger              # expect: Linger=yes

# (2) tmux.service did its job
systemctl --user is-enabled tmux.service              # expect: enabled
systemctl --user is-active tmux.service               # expect: active

# (3) Layout restored
tmux ls | wc -l                                       # expect: matches pre-reboot count (~36)

# (4) Strategy ran cleanly on this boot's restore
awk -F'\t' -v today="$(date -Idate)" '$1 ~ "^"today {
  tag=$2; if(tag~/^resolved=/)tag="resolved"; if(tag~/^no-project-dir:/)tag="no-project-dir"; if(tag~/^no-jsonl:/)tag="no-jsonl"; c[tag]++
} END {for(t in c) printf "%4d %s\n", c[t], t}' ~/tmux_continuity/claude_autoresume.log | sort -rn
# expect: lots of resolved=  + already-has-resume; zero or near-zero trap-error/no-jsonl/no-project-dir

# (5) Claude panes are alive
tmux list-panes -a -F '#{pane_current_command}' | grep -c '^claude$'   # expect: matches pre-reboot

# (6) Resurrect symlink + Weka save dir intact
readlink ~/.local/share/tmux/resurrect                # expect: /weka_user_data/manas.gupta/state/tmux_resurrect
ls -lt /weka_user_data/manas.gupta/state/tmux_resurrect/pane_contents.tar.gz   # expect: mtime within last 2 min (continuum saving)
```

## 7. Debugging cookbook

The strategy log is the primary diagnostic. Read it first:

```bash
tail -100 ~/tmux_continuity/claude_autoresume.log
```

Columns (tab-separated): `timestamp`, `decision-tag`, `in_cmd`, `in_dir`, `out_cmd`.

Decision tags:
- `already-has-resume` — pane's saved cmd already had `--resume <uuid>`; left unchanged
- `no-dir` — resurrect didn't pass cwd (rare; plugin bug)
- `no-project-dir:<path>` — encoded project dir doesn't exist (**most common failure**)
- `no-jsonl:<path>` — project dir exists but has no `*.jsonl` files
- `resolved=<uuid>` — happy path; UUID injected
- `trap-error` — script hit unexpected error; fell back to original command

### Symptom: a pane is bash after reboot (no claude relaunched at all)

The `~claude` whitelist isn't matching, or resurrect isn't calling the strategy.

```bash
tmux show-options -g @resurrect-processes             # must contain ~claude
tmux show-options -g @resurrect-strategy-claude       # must be: autoresume
ls -la ~/.tmux/plugins/tmux-resurrect/strategies/claude_autoresume.sh   # must exist + executable
```

If the symlink is missing or broken (rare — TPM `git pull` doesn't touch untracked symlinks, but a destructive plugin reinstall could):

```bash
ln -s /home/manas.gupta/tmux_continuity/claude_autoresume.sh \
      ~/.tmux/plugins/tmux-resurrect/strategies/claude_autoresume.sh
```

### Symptom: pane runs `claude` but no `--resume` argument

Strategy ran but couldn't find a project dir. Find the entry:

```bash
grep <pane-cwd> ~/tmux_continuity/claude_autoresume.log | tail
```

Decision column tells you why:
- `no-project-dir:<path>` — encoded path doesn't match any real dir. Likely the workspace was launched in an old path. Check `ls ~/.claude/projects/ | grep <substring>` for a matching dir under a different encoding. If found, create a bridge symlink: `ln -s ~/.claude/projects/<old-encoding> ~/.claude/projects/<new-encoding>`.
- `no-jsonl:<path>` — project dir exists but empty. Workspace was never used; plain claude is correct behavior.

### Symptom: pane got `claude --resume <uuid>` but claude says "No conversation found"

The UUID exists in the wrong project dir. Symlink the project dir or the specific JSONL:

```bash
# Whole dir:
ln -s ~/.claude/projects/<dir-with-uuid> ~/.claude/projects/<dir-claude-looked-in>

# Or just the file:
ln -s ~/.claude/projects/<dir-with-uuid>/<uuid>.jsonl ~/.claude/projects/<dir-claude-looked-in>/<uuid>.jsonl
```

### Symptom: pane got `--resume <wrong-uuid>` (resumed a different conversation)

Strategy picked the most recent JSONL but a different recent conversation existed. Compare:

```bash
ls -lt ~/.claude/projects/<encoded-cwd>/*.jsonl | head -5
```

Fixes:
- Manually `/exit` the pane and `claude --resume <correct-uuid>`.
- Or `touch ~/.claude/projects/<encoded-cwd>/<correct>.jsonl` to make it newest, so future restores pick it.

### Symptom: tmux didn't auto-start after reboot

```bash
systemctl --user status tmux.service
systemctl --user is-enabled tmux.service              # must be: enabled
loginctl show-user manas.gupta -p Linger              # must be: yes
journalctl --user -u tmux.service --since "1 hour ago"
```

If linger is `no`, re-enable: `loginctl enable-linger` (no args, no sudo).

### Symptom: continuum stopped saving

```bash
ls -lt /weka_user_data/manas.gupta/state/tmux_resurrect/ | head -5
readlink ~/.local/share/tmux/resurrect                # must be: /weka_user_data/manas.gupta/state/tmux_resurrect
```

If symlink missing/broken: `ln -s /weka_user_data/manas.gupta/state/tmux_resurrect ~/.local/share/tmux/resurrect`.

`pane_contents.tar.gz` mtime is the most reliable "continuum is alive" signal — it updates every minute regardless of whether state changed (the `.txt` files only get a new file on actual state change). Force a save manually: `tmux run-shell ~/.tmux/plugins/tmux-resurrect/scripts/save.sh`.

### Symptom: stale `(deleted)` cwds after reboot

Shouldn't happen after Phase A unless a workspace path was renamed again. Find them:

```bash
tmux list-panes -a -F '#{session_name}|#{pane_current_path}' | grep -E "(deleted|/old_)"
```

For each: attach, `/exit` any running claude, `cd <new-path>`, then `claude --resume <uuid>`.

## 8. Prompt template — paste this to a fresh Claude session if something breaks

```
My tmux + claude session continuity setup is misbehaving.

Symptom: <DESCRIBE WHAT YOU OBSERVED — e.g. "after reboot, half my panes
are bash instead of claude", or "claude is launching fresh instead of
resuming", or "tmux didn't auto-start at all">.

Before changing anything:
1. Read /home/manas.gupta/tmux_continuity/system_continuity_over_restarts.md
   end to end — it has the full design, all file paths, and a
   debugging cookbook keyed by symptom. (The path
   /home/manas.gupta/system_continuity_over_restarts/system_continuity_over_restarts.md
   is also a backward-compat symlink pointing at the same file.)
2. Read the most recent entries of ~/tmux_continuity/claude_autoresume.log
   (TSV, columns: timestamp, decision-tag, in_cmd, in_dir, out_cmd).
   The decision tag tells you which branch fired (already-has-resume,
   no-project-dir:<path>, no-jsonl:<path>, resolved=<uuid>, trap-error).
3. Verify the live state matches what the doc's "exhaustive list of
   installed/modified files" table describes (config options set,
   symlinks intact, unit enabled, etc.).

Then diagnose root cause and propose a concrete fix. Do NOT run
destructive commands (rm, mv, kill, systemctl stop, tmux kill-server)
without confirming with me first. The user has no sudo — propose only
user-level fixes.

If your investigation surfaces a failure mode the doc doesn't cover,
update the Debugging Cookbook section before finishing.
```

## 9. Rollback procedures

### Partial — disable auto-resume only, keep tmux auto-start

Edit `~/.tmux.conf` and remove `~claude` from the `@resurrect-processes` line:
```
set -g @resurrect-processes '~ssh ~python3 ~node'    # was: '~ssh ~python3 ~node ~claude'
```
Then `tmux source-file ~/.tmux.conf`. Restore reverts to: claude panes come back as bash, you manually `claude --resume` per pane.

### Full — revert everything (back to pre-Phase-A state)

```bash
# 1. Disable tmux.service
systemctl --user disable tmux.service
rm ~/.config/systemd/user/tmux.service

# 2. Disable linger (optional — leaving it on is harmless)
loginctl disable-linger

# 3. Revert resurrect dir to local
rm ~/.local/share/tmux/resurrect
mv ~/.local/share/tmux/resurrect.local_backup ~/.local/share/tmux/resurrect

# 4. Revert .tmux.conf
# Remove `~claude` from @resurrect-processes and the @resurrect-strategy-claude line
tmux source-file ~/.tmux.conf

# 5. Remove the strategy script (optional; harmless if left)
rm ~/.tmux/plugins/tmux-resurrect/strategies/claude_autoresume.sh
```

The project-dir symlinks under `~/.claude/projects/` are harmless and useful even without this setup; leave them.

## 10. Maintenance gotchas

| Event | What breaks | How to recover | Frequency |
|---|---|---|---|
| `prefix + U` (TPM plugin update) | TPM runs `git pull`, which leaves untracked symlinks intact. The symlink at `~/.tmux/plugins/tmux-resurrect/strategies/claude_autoresume.sh` should survive. | If it ever doesn't (e.g., a future plugin manager does `git clean -fd`): `ln -s /home/manas.gupta/tmux_continuity/claude_autoresume.sh ~/.tmux/plugins/tmux-resurrect/strategies/claude_autoresume.sh` | Very rare |
| IT changes the `/weka_user_data/manas.gupta` symlink target | Project-dir symlinks in `~/.claude/projects/` point at wrong targets | Update the 5 bridge symlinks to the new physical path | Almost never |
| Claude binary update changes `--resume` semantics | Strategy may inject a now-invalid flag | Read claude release notes when upgrading; update strategy if needed | Roughly yearly |
| New long-lived tmux session in a new workspace | Works automatically — strategy resolves any cwd whose project dir exists | None | Continuous |
| Future systemd deprecates more directives | tmux.service unit warnings | Check `journalctl --user -u tmux.service` after major OS upgrades | Multi-year |

## Appendix A — `claude_autoresume.sh` full contents

Source of truth: `/home/manas.gupta/tmux_continuity/claude_autoresume.sh` (also installed at `~/.tmux/plugins/tmux-resurrect/strategies/claude_autoresume.sh`).

```bash
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
```

To install from scratch:
```bash
chmod +x /home/manas.gupta/tmux_continuity/claude_autoresume.sh
ln -s /home/manas.gupta/tmux_continuity/claude_autoresume.sh \
      ~/.tmux/plugins/tmux-resurrect/strategies/claude_autoresume.sh
```

## Appendix B — `tmux.service` full contents

Installed at `~/.config/systemd/user/tmux.service`:

```ini
[Unit]
Description=tmux server (continuum auto-restore on boot)
After=network-online.target
RequiresMountsFor=/weka_user_data/manas.gupta

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/tmux new-session -d -s _bootstrap

[Install]
WantedBy=default.target
```

`RequiresMountsFor` makes systemd wait for the Weka NFS mount to be ready before starting tmux. Without it, a slow mount at boot would cause continuum to find an empty/missing save → empty tmux on first attach.

To install from scratch:
```bash
mkdir -p ~/.config/systemd/user
# write the file above
loginctl enable-linger              # no username, no sudo
systemctl --user daemon-reload
systemctl --user enable tmux.service
# Do NOT `start` it if tmux is already running — it'll take effect on next boot.
```

## Appendix C — Relevant `~/.tmux.conf` lines

`~/.tmux.conf` is a symlink to `/home/manas.gupta/tmux_continuity/.tmux.conf`. The lines that matter for this system:

```tmux
# Auto-restore last saved session on tmux start
set -g @continuum-restore 'on'

# Save interval in minutes
set -g @continuum-save-interval '1'

# Restore pane contents
set -g @resurrect-capture-pane-contents 'on'

# Restore additional programs (~ prefix means: regex-match anywhere in saved cmd)
set -g @resurrect-processes '~ssh ~python3 ~node ~claude'

# Restore vim sessions
set -g @resurrect-strategy-vim 'session'

# Auto-resume claude with latest matching session UUID
# Strategy script: ~/.tmux/plugins/tmux-resurrect/strategies/claude_autoresume.sh
# Source of truth: ~/tmux_continuity/claude_autoresume.sh
# Debug log:       ~/tmux_continuity/claude_autoresume.log
set -g @resurrect-strategy-claude 'autoresume'
```

## Appendix D — How to verify everything from scratch

If you ever need to confirm the whole system is healthy (e.g., after a major OS update, or just out of caution), run:

```bash
# (1) Config options
[ "$(tmux show-options -gv @resurrect-processes)" = "~ssh ~python3 ~node ~claude" ] && echo "✓ resurrect-processes"
[ "$(tmux show-options -gv @resurrect-strategy-claude)" = "autoresume" ] && echo "✓ resurrect-strategy-claude"

# (2) Files in place + symlink points to source-of-truth
[ -x /home/manas.gupta/tmux_continuity/claude_autoresume.sh ] && echo "✓ source-of-truth script"
[ -L ~/.tmux/plugins/tmux-resurrect/strategies/claude_autoresume.sh ] && echo "✓ plugin-dir entry is a symlink"
[ "$(readlink ~/.tmux/plugins/tmux-resurrect/strategies/claude_autoresume.sh)" = "/home/manas.gupta/tmux_continuity/claude_autoresume.sh" ] && echo "✓ symlink target correct"

# (3) Systemd
[ "$(systemctl --user is-enabled tmux.service)" = "enabled" ] && echo "✓ tmux.service enabled"
[ "$(loginctl show-user manas.gupta -p Linger)" = "Linger=yes" ] && echo "✓ linger enabled"
[ "$(systemctl --user show tmux.service -p RequiresMountsFor --value)" = "/weka_user_data/manas.gupta" ] && echo "✓ Weka mount dep set"

# (3a) Git tracking — local-disk loss recoverable from GitHub
cd /home/manas.gupta/tmux_continuity
[ -z "$(git status --porcelain)" ] && echo "✓ git tree clean"
git ls-files | grep -q "system_continuity_over_restarts.md" && echo "✓ master doc tracked"
git ls-files | grep -q "claude_autoresume.sh" && echo "✓ strategy script tracked"
git fetch -q && [ "$(git rev-parse HEAD)" = "$(git rev-parse @{u})" ] && echo "✓ in sync with origin"

# (4) Resurrect dir on Weka
[ "$(readlink ~/.local/share/tmux/resurrect)" = "/weka_user_data/manas.gupta/state/tmux_resurrect" ] && echo "✓ resurrect dir symlinked to weka"

# (5) Strategy works (smoke test — uses a real project dir)
~/.tmux/plugins/tmux-resurrect/strategies/claude_autoresume.sh "claude" "/weka_team_data/manas_team/manas.gupta/strategy-factory" | grep -q -- "--resume " && echo "✓ strategy injects --resume on real cwd"

# (6) Project-dir bridge symlinks
for ws in strategy-factory dashboards scripts-HF10-Expenses mfqr scripts-index-adjustment; do
  [ -L ~/.claude/projects/-weka-team-data-manas-team-manas-gupta-$ws ] && echo "✓ symlink: $ws" || echo "✗ MISSING symlink: $ws"
done
```

A clean system passes all checks. Any `✗` is actionable per section 7.

## 11. Discoverability + backup

This file is the master and only user-facing source. Lives at `/home/manas.gupta/tmux_continuity/system_continuity_over_restarts.md`. The path `/home/manas.gupta/system_continuity_over_restarts/system_continuity_over_restarts.md` is a backward-compatibility symlink to the same file.

Future Claude sessions discover it via:

- `find ~ -name "system_continuity*"` (the most reliable approach for an agent investigating a tmux/claude issue)
- The prompt template in section 8 (which you paste explicitly when something breaks)

**Off-machine backup via GitHub.** `~/tmux_continuity/` is a git repo with remote `https://github.com/xanaducrypt/tmux_continuity.git`. The repo tracks: `.tmux.conf`, `claude_autoresume.sh`, this doc, `.gitignore`, plus the legacy `tms` and `setup.sh`. The log (`claude_autoresume.log`) is gitignored — it mutates on every restore and isn't worth versioning. If local disk is ever lost or corrupted, the entire setup is recoverable via:

```bash
cd ~ && git clone https://github.com/xanaducrypt/tmux_continuity.git
# then re-install plugin-dir symlink, recreate ~/.tmux.conf symlink,
# re-enable linger + tmux.service per appendix B.
```

The only related artifact still on disk that's NOT in the git repo is Claude's project-scoped behavioral memory at `~/.claude/projects/-home-manas-gupta-system-continuity-over-restarts/memory/` — that's for Claude's own session-context behavior (user has no sudo, weka path is symlinked, etc.) and isn't user-facing documentation. Leave it alone.

The earlier `tmux_continuity/README.md` and `~/.claude/plans/i-have-processes-running-valiant-fountain.md` files were deleted on 2026-05-12 once this doc subsumed them. If you ever see references to those paths in older notes or git history, they no longer exist.
