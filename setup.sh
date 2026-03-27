#!/bin/bash

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# Install TPM if not present
if [ ! -d "$HOME/.tmux/plugins/tpm" ]; then
    echo "Installing TPM..."
    git clone https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm"
else
    echo "TPM already installed."
fi

# Backup existing .tmux.conf if it exists and isn't a symlink
if [ -f "$HOME/.tmux.conf" ] && [ ! -L "$HOME/.tmux.conf" ]; then
    echo "Backing up existing .tmux.conf to .tmux.conf.bak"
    mv "$HOME/.tmux.conf" "$HOME/.tmux.conf.bak"
fi

# Symlink .tmux.conf
ln -sf "$REPO_DIR/.tmux.conf" "$HOME/.tmux.conf"
echo "Symlinked .tmux.conf"

# Install plugins
echo "Installing plugins..."
export TMUX_PLUGIN_MANAGER_PATH="$HOME/.tmux/plugins"
tmux start-server \; set-environment -g TMUX_PLUGIN_MANAGER_PATH "$HOME/.tmux/plugins" 2>/dev/null
"$HOME/.tmux/plugins/tpm/bin/install_plugins"

echo "Done! Restart tmux or run: tmux source-file ~/.tmux.conf"
