#!/bin/bash
# This script sets up shell configurations dynamically based on project config

echo "🔧 Running shell setup script..."

CONFIG_FILE="/tmp/vm-config.json"
USER_HOME="/home/vagrant"

# Default values
EMOJI="🚀"
USERNAME="dev"
SHOW_GIT_BRANCH="true"
SHOW_TIMESTAMP="false"

# Extract values from config if available
if [ -f "$CONFIG_FILE" ]; then
    EMOJI=$(jq -r '.terminal.emoji // "🚀"' "$CONFIG_FILE")
    USERNAME=$(jq -r '.terminal.username // "dev"' "$CONFIG_FILE")
    SHOW_GIT_BRANCH=$(jq -r '.terminal.show_git_branch // true' "$CONFIG_FILE")
    SHOW_TIMESTAMP=$(jq -r '.terminal.show_timestamp // false' "$CONFIG_FILE")
    WORKSPACE=$(jq -r '.project.workspace_path // "/workspace"' "$CONFIG_FILE")
    
    # Extract environment variables
    ENV_VARS=$(jq -r '.environment // {} | to_entries | .[] | "export \(.key)=\"\(.value)\""' "$CONFIG_FILE")
    
    # Extract aliases
    ALIASES=$(jq -r '.aliases // {} | to_entries | .[] | "alias \(.key)='\''\(.value)'\''"' "$CONFIG_FILE")
fi

# Create .bashrc
cat > "$USER_HOME/.bashrc" << EOF
# Custom prompt functions for bash
git_branch_name() {
$(if [ "$SHOW_GIT_BRANCH" = "true" ]; then
    echo "  git branch 2>/dev/null | grep '^*' | cut -c3- | sed 's/^/ (/' | sed 's/$/)/'"
else
    echo "  true"
fi)
}

format_timestamp() {
$(if [ "$SHOW_TIMESTAMP" = "true" ]; then
    echo "  echo \" [\$(date '+%H:%M:%S')]\""
else
    echo "  true"
fi)
}

# Set custom prompt
PS1='$EMOJI $USERNAME \W\$(git_branch_name)\$(format_timestamp) > '

# Universal aliases
alias ll='ls -la'
alias dev='cd $WORKSPACE && ls'
alias ports='netstat -tulpn | grep LISTEN'
alias services='systemctl list-units --type=service --state=running'

# Search tools
alias rg='rg --smart-case'
alias rgf='rg --files | rg'

# Git shortcuts
alias gs='git status'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
alias gl='git log --oneline'

# Docker shortcuts
alias dps='docker ps'
alias dimg='docker images'

# Project aliases (from vm.json)
$ALIASES

# Environment
export DISPLAY=:99
export PYTHONDONTWRITEBYTECODE=1
$ENV_VARS

# Auto-cd to workspace
cd $WORKSPACE 2>/dev/null || true
EOF

# Create .zshrc
cat > "$USER_HOME/.zshrc" << EOF
# Custom prompt functions for zsh
function git_branch_name() {
$(if [ "$SHOW_GIT_BRANCH" = "true" ]; then
    echo "  git branch 2>/dev/null | grep '^*' | cut -c3- | sed 's/^/ (/' | sed 's/$/)/'"
else
    echo "  true"
fi)
}

function format_timestamp() {
$(if [ "$SHOW_TIMESTAMP" = "true" ]; then
    echo "  echo \" [\$(date '+%H:%M:%S')]\""
else
    echo "  true"
fi)
}

# Set custom prompt
setopt PROMPT_SUBST
PROMPT='$EMOJI $USERNAME %c\$(git_branch_name)\$(format_timestamp) > '

# Universal aliases
alias ll='ls -la'
alias dev='cd $WORKSPACE && ls'
alias ports='netstat -tulpn | grep LISTEN'
alias services='systemctl list-units --type=service --state=running'

# Search tools
alias rg='rg --smart-case'
alias rgf='rg --files | rg'

# Git shortcuts
alias gs='git status'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
alias gl='git log --oneline'

# Docker shortcuts
alias dps='docker ps'
alias dimg='docker images'

# Project aliases (from vm.json)
$ALIASES

# Environment
export DISPLAY=:99
export PYTHONDONTWRITEBYTECODE=1
$ENV_VARS

# Auto-cd to workspace
cd $WORKSPACE 2>/dev/null || true
EOF

# Set ownership
chown vagrant:vagrant "$USER_HOME/.bashrc" "$USER_HOME/.zshrc"

echo "✅ Shell configuration completed! Created .bashrc and .zshrc with custom prompt: $EMOJI $USERNAME"

# Quick check if Node.js is available and install Claude if possible
if [ -f "$USER_HOME/.nvm/nvm.sh" ]; then
    echo "🔧 Setting up Node.js and Claude Code..."
    
    # Run as vagrant user to ensure proper environment
    su - vagrant -c '
        source ~/.nvm/nvm.sh
        
        # Check if claude is already installed
        if ! which claude > /dev/null 2>&1; then
            echo "📦 Installing Claude Code CLI..."
            npm install -g @anthropic-ai/claude-code
        else
            echo "✅ Claude Code CLI is already installed"
        fi
        
        # Also try to install pnpm directly if corepack fails
        if ! which pnpm > /dev/null 2>&1; then
            echo "📦 Installing pnpm via npm..."
            npm install -g pnpm@10.12.3
        fi
    '
fi

# Fix ownership of shell configuration files
echo "🔧 Fixing shell configuration file ownership..."
chown vagrant:vagrant "$USER_HOME/.bashrc" "$USER_HOME/.zshrc"
chmod 644 "$USER_HOME/.bashrc" "$USER_HOME/.zshrc"