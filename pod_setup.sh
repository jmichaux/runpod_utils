#!/bin/bash
# pod_setup.sh — one-shot pod bring-up. Idempotent; run on every fresh pod.
#
# Container FS (re-installed per pod, ~1-2 min total):
#   - Node 20 via NodeSource apt        (only if Claude Code or Codex is installed)
#   - Claude Code via global npm        (only if --install-claude=1, default: 1)
#   - Codex CLI via global npm          (only if --install-codex=1,  default: 1)
#   - gh CLI via apt
#   - uv (fast pip alternative) at $HOME/.local/bin/uv
#   - Miniconda base at $HOME/miniconda3
#   - Conda envs at /root/conda-envs/ (rebuild per pod from environment.yml)
#   - apt build prereqs (gfortran, openblas, autoconf, etc.)
#
# Persistent state (lives under $WORKSPACE; survives pod restart if /workspace is mounted):
#   - SSH key at $WORKSPACE/.ssh/
#   - Claude auth backup at $WORKSPACE/claude-auth-backup.json  (if --install-claude=1)
#   - Claude settings backup at $WORKSPACE/claude-settings-backup.json  (if --install-claude=1)
#   - HuggingFace cache at $WORKSPACE/.cache/huggingface (HF_HOME)
#   - API secrets at $WORKSPACE/.pod-secrets (chmod 600; sourced by ~/.bashrc)
#
# WORKSPACE auto-detects: /workspace if writable, else $HOME (no persistence —
# fresh keys + fresh HF downloads each pod).
#
# NOTE: conda envs and pkgs caches are NEVER persisted, even with /workspace.
#       MooseFS hits EIO during extraction and is slow for the small-file
#       metadata ops conda does at runtime. Source of truth for envs is
#       each project's environment.yml / requirements.txt in git.
#
# Usage:
#   GH_USER=<you> GIT_NAME='Your Name' GIT_EMAIL=you@example.com bash pod_setup.sh [flags]
#
# Flags (override env vars of the same name):
#   --install-claude=0|1   install Claude Code (default: 1)
#   --install-codex=0|1    install Codex CLI   (default: 1)
#
# Env knobs (all optional):
#   INSTALL_CLAUDE  same as --install-claude (flag takes precedence)
#   INSTALL_CODEX   same as --install-codex  (flag takes precedence)
#   GH_USER         persisted to ~/.bashrc; inherited by project setup scripts.
#   GIT_NAME        if set with GIT_EMAIL, runs `git config --global user.name`.
#   GIT_EMAIL       if set with GIT_NAME, runs `git config --global user.email`.
#   OPENAI_API_KEY  written to $WORKSPACE/.pod-secrets (chmod 600), not ~/.bashrc.
#   WORKSPACE       override persistent-state location. Defaults to /workspace
#                   if mounted+writable, else $HOME.

set -eo pipefail

# --- Defaults (can be overridden by env var or CLI flag) ---------------------
INSTALL_CLAUDE=${INSTALL_CLAUDE:-1}
INSTALL_CODEX=${INSTALL_CODEX:-1}

for arg in "$@"; do
  case "$arg" in
    --install-claude=*) INSTALL_CLAUDE="${arg#*=}" ;;
    --install-codex=*)  INSTALL_CODEX="${arg#*=}"  ;;
    --) break ;;
    --*) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

# --- Auto-detect WORKSPACE ---------------------------------------------------
if [ -z "${WORKSPACE:-}" ]; then
  if [ -d /workspace ] && [ -w /workspace ]; then
    WORKSPACE=/workspace
  else
    WORKSPACE="$HOME"
  fi
fi
if [ "$WORKSPACE" = "$HOME" ]; then
  PERSIST="no — fresh state per pod ($WORKSPACE)"
else
  PERSIST="yes ($WORKSPACE)"
fi
echo "[setup_pod] persistence: $PERSIST"
echo "[setup_pod] install-claude=$INSTALL_CLAUDE  install-codex=$INSTALL_CODEX"

# -----------------------------------------------------------------------------
ensure_line() {
  local line="$1" file="$2"
  touch "$file"
  grep -qxF "$line" "$file" || echo "$line" >> "$file"
}

echo "==> apt prereqs"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  ca-certificates curl git unzip rsync wget gnupg \
  build-essential gfortran pkg-config \
  libopenblas-dev libmetis-dev \
  autoconf automake libtool \
  tmux vim less htop nvtop

# Node 20 is only needed if we're installing Claude Code or Codex.
if [ "$INSTALL_CLAUDE" = "1" ] || [ "$INSTALL_CODEX" = "1" ]; then
  echo "==> Node 20 (NodeSource apt, container FS)"
  if ! command -v node >/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
  fi
fi

if [ "$INSTALL_CLAUDE" = "1" ]; then
  echo "==> Claude Code (global npm, container FS)"
  if ! command -v claude >/dev/null; then
    npm install -g @anthropic-ai/claude-code
  fi
fi

if [ "$INSTALL_CODEX" = "1" ]; then
  echo "==> Codex CLI (global npm, container FS)"
  if ! command -v codex >/dev/null; then
    npm install -g @openai/codex
  fi
fi

echo "==> uv (fast pip alternative, container FS)"
# Use path-based check: $HOME/.local/bin isn't in PATH yet during this script,
# so `command -v uv` would miss an already-installed uv on re-runs.
if [ ! -x "$HOME/.local/bin/uv" ] && [ ! -x "$HOME/.cargo/bin/uv" ]; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  # Source the env file the installer creates so uv is available for the
  # rest of this script without waiting for a new shell.
  [ -f "$HOME/.local/bin/env" ] && . "$HOME/.local/bin/env"
fi

echo "==> gh CLI (apt, container FS)"
if ! command -v gh >/dev/null; then
  GH_KEYRING=/usr/share/keyrings/githubcli-archive-keyring.gpg
  GH_SOURCES=/etc/apt/sources.list.d/github-cli.list
  GH_ARCH=$(dpkg --print-architecture)
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of="$GH_KEYRING"
  chmod go+r "$GH_KEYRING"
  # printf onto one line; variables keep the literal short so paste can't split it
  printf 'deb [arch=%s signed-by=%s] https://cli.github.com/packages stable main\n' \
    "$GH_ARCH" "$GH_KEYRING" | tee "$GH_SOURCES" >/dev/null
  apt-get update -qq
  apt-get install -y gh
fi

echo "==> Miniconda base (container FS at \$HOME/miniconda3)"
CONDA_DIR="$HOME/miniconda3"
if [ ! -x "$CONDA_DIR/bin/conda" ]; then
  curl -fsSL https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -o /tmp/mc.sh
  bash /tmp/mc.sh -b -p "$CONDA_DIR"
  rm -f /tmp/mc.sh
fi

echo "==> conda envs_dirs / pkgs_dirs (container FS only — MFS is unsafe for conda)"
LOCAL_ENVS="/root/conda-envs"
LOCAL_PKGS="/root/conda-pkgs"
mkdir -p "$LOCAL_ENVS" "$LOCAL_PKGS" "$HOME/.conda"
cat > "$HOME/.condarc" <<YAML
envs_dirs:
  - $LOCAL_ENVS
  - $CONDA_DIR/envs
pkgs_dirs:
  - $LOCAL_PKGS
  - $CONDA_DIR/pkgs
auto_activate_base: false
YAML

echo "==> kernel knobs (ptrace, ulimit) for ML profiling + distributed training"
# py-spy + similar profilers need ptrace; default Yama scope blocks attach.
if [ -w /proc/sys/kernel/yama/ptrace_scope ]; then
  echo 0 > /proc/sys/kernel/yama/ptrace_scope || true
fi
# NCCL / distributed training trips the default 1024 open-files limit. We raise
# it here for the script's own shell; the persistent fix for future shells is
# the `ulimit -n 65536` line wired into ~/.bashrc later in this script.
ulimit -n 65536 2>/dev/null || true

echo "==> SSH key ($WORKSPACE/.ssh/, monthly rotation)"
SSH_GENERATED=0
SSH_ROTATED=0
SSH_DIR="$WORKSPACE/.ssh"
KEY="$SSH_DIR/id_ed25519"
ARCHIVE="$SSH_DIR/archive"
mkdir -p "$SSH_DIR" "$ARCHIVE"
chmod 700 "$SSH_DIR" "$ARCHIVE" 2>/dev/null || true

# Rotate when the calendar month has changed since key creation.
# Old key is moved to $ARCHIVE/ so the live .ssh dir stays clean.
# (Without persistent $WORKSPACE the key won't exist, so rotation is a no-op
#  and we just generate a fresh one below.)
if [ -f "$KEY" ] && [ "$(date -r "$KEY" +%Y%m)" -lt "$(date +%Y%m)" ]; then
  STAMP=$(date -r "$KEY" +%Y%m%d)
  echo "    rotating: key from $STAMP, now $(date +%Y%m%d) — archiving to $ARCHIVE/"
  mv "$KEY"     "$ARCHIVE/id_ed25519.$STAMP"
  mv "$KEY.pub" "$ARCHIVE/id_ed25519.pub.$STAMP"
  SSH_ROTATED=1
fi

if [ ! -f "$KEY" ]; then
  ssh-keygen -t ed25519 -f "$KEY" -N "" -C "runpod-$(hostname)-$(date +%Y%m%d)" -q
  SSH_GENERATED=1
fi

# Stage key into $HOME/.ssh so ssh/git find it. Skip the copy when SSH_DIR is
# already $HOME/.ssh (no-volume case — the keygen above wrote there directly).
mkdir -p "$HOME/.ssh"
if [ "$SSH_DIR" != "$HOME/.ssh" ]; then
  cp "$KEY" "$KEY.pub" "$HOME/.ssh/"
fi
chmod 600 "$HOME/.ssh/id_ed25519"
chmod 644 "$HOME/.ssh/id_ed25519.pub" 2>/dev/null || true

# Pre-populate known_hosts so non-interactive `git clone git@github.com:...` doesn't
# block on a TTY prompt the first time. Idempotent: appended only if missing.
if ! grep -q "^github.com" "$HOME/.ssh/known_hosts" 2>/dev/null; then
  ssh-keyscan -t rsa,ecdsa,ed25519 github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null
fi
chmod 644 "$HOME/.ssh/known_hosts" 2>/dev/null || true

if [ "$INSTALL_CLAUDE" = "1" ]; then
  echo "==> Claude auth + settings ($WORKSPACE backups -> HOME)"
  AUTH_BACKUP="$WORKSPACE/claude-auth-backup.json"
  SETTINGS_BACKUP="$WORKSPACE/claude-settings-backup.json"
  AUTH_TARGET="$HOME/.claude/.credentials.json"
  mkdir -p "$HOME/.claude"
  AUTH_RESTORED=0
  if [ -f "$AUTH_BACKUP" ]; then
    cp "$AUTH_BACKUP" "$AUTH_TARGET"
    chmod 600 "$AUTH_TARGET"
    AUTH_RESTORED=1
  fi
  if [ -f "$SETTINGS_BACKUP" ]; then
    cp "$SETTINGS_BACKUP" "$HOME/.claude/settings.json"
  else
    cat > "$HOME/.claude/settings.json" <<'JSON'
{
  "permissions": {
    "allow": ["Bash(*)","Read(*)","Write(*)","Edit(*)","Glob(*)","Grep(*)","WebFetch(*)","WebSearch"]
  }
}
JSON
    cp "$HOME/.claude/settings.json" "$SETTINGS_BACKUP"
  fi
fi

echo "==> wiring shells (conda, PATH, HF_HOME, ulimit, optional secrets)"
HF_CACHE="$WORKSPACE/.cache/huggingface"
mkdir -p "$HF_CACHE"
ensure_line "# --- pod conda init ---"                                        ~/.bashrc
ensure_line "export PATH=\"$CONDA_DIR/bin:\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH\"" ~/.bashrc
ensure_line ". $CONDA_DIR/etc/profile.d/conda.sh"                            ~/.bashrc
ensure_line "export HF_HOME=$HF_CACHE"                                       ~/.bashrc
ensure_line 'ulimit -n 65536 2>/dev/null'                                    ~/.bashrc
if [ -n "${GH_USER:-}" ]; then
  ensure_line "export GH_USER=$GH_USER"                                      ~/.bashrc
fi

# Secrets (OPENAI_API_KEY, etc.) go to a chmod-600 file sourced by ~/.bashrc,
# not written into ~/.bashrc directly. This keeps key values out of plaintext
# shell config files that could be read by other processes or accidentally shared.
SECRETS_FILE="$WORKSPACE/.pod-secrets"
touch "$SECRETS_FILE"
chmod 600 "$SECRETS_FILE"
upsert_secret() {
  local key="$1" val="$2"
  # Replace existing export line for this key, or append if not present.
  # Value is quoted to handle spaces; | delimiter handles values containing /.
  if grep -q "^export $key=" "$SECRETS_FILE" 2>/dev/null; then
    sed -i "s|^export $key=.*|export $key=\"$val\"|" "$SECRETS_FILE"
  else
    echo "export $key=\"$val\"" >> "$SECRETS_FILE"
  fi
}
if [ -n "${OPENAI_API_KEY:-}" ]; then
  upsert_secret OPENAI_API_KEY "$OPENAI_API_KEY"
fi
ensure_line "[ -f $SECRETS_FILE ] && . $SECRETS_FILE"                        ~/.bashrc

# Auto-configure git identity if both env vars provided. git config writes to
# ~/.gitconfig (its own persistent file), so no bashrc entry needed.
GIT_CONFIGURED=0
if [ -n "${GIT_NAME:-}" ] && [ -n "${GIT_EMAIL:-}" ]; then
  git config --global user.name  "$GIT_NAME"
  git config --global user.email "$GIT_EMAIL"
  GIT_CONFIGURED=1
elif git config --global user.name >/dev/null 2>&1 \
  && git config --global user.email >/dev/null 2>&1; then
  GIT_CONFIGURED=1
fi

ensure_line '[ -f ~/.bashrc ] && . ~/.bashrc'                                ~/.bash_profile

echo
echo "============================================================"
echo "Pod setup complete."
printf "  node:   %s\n" "$(node --version 2>/dev/null || echo skipped)"
[ "$INSTALL_CLAUDE" = "1" ] && \
  printf "  claude: %s\n" "$(claude --version 2>/dev/null || echo missing)"
[ "$INSTALL_CODEX" = "1" ] && \
  printf "  codex:  %s\n" "$(codex --version 2>/dev/null || echo missing)"
printf "  uv:     %s\n" "$($HOME/.local/bin/uv --version 2>/dev/null \
  || $HOME/.cargo/bin/uv --version 2>/dev/null \
  || echo missing)"
printf "  gh:     %s\n" "$(gh --version 2>/dev/null | head -1 || echo missing)"
printf "  conda:  %s   (envs -> %s)\n" \
  "$("$CONDA_DIR/bin/conda" --version 2>/dev/null || echo missing)" "$LOCAL_ENVS"
printf "  GH_USER:       %s\n" "${GH_USER:-<unset>}"
printf "  git identity:  %s\n" "$([ "$GIT_CONFIGURED" = "1" ] && echo "configured" || echo "<unset — see below>")"
[ "$INSTALL_CODEX" = "1" ] && \
  printf "  OPENAI_API_KEY: %s\n" "$([ -n "${OPENAI_API_KEY:-}" ] && echo "set" || echo "<unset>")"
printf "  persistence:   %s\n" "$PERSIST"
echo
echo "Do next (new shell after 'source ~/.bashrc'):"
if [ "$SSH_ROTATED" = "1" ]; then
  echo "  !! MONTHLY KEY ROTATION — action required !!"
  echo "     1. Show the new pubkey, then paste into https://github.com/settings/ssh/new"
  echo "          cat ~/.ssh/id_ed25519.pub"
  echo "     2. Delete the OLD pubkey at https://github.com/settings/keys"
  echo "        (entry whose comment ends in a date older than today)"
  echo "     3. Verify: ssh -T git@github.com"
elif [ "$SSH_GENERATED" = "1" ]; then
  echo "  * Show your new pubkey, then paste into https://github.com/settings/ssh/new"
  echo "      cat ~/.ssh/id_ed25519.pub"
  echo "    verify: ssh -T git@github.com"
fi
if [ "$INSTALL_CLAUDE" = "1" ] && [ "$AUTH_RESTORED" = "0" ]; then
  echo "  * claude login"
  echo "    then:  cp ~/.claude/.credentials.json $AUTH_BACKUP"
fi
echo "  * gh auth login"
if [ "$GIT_CONFIGURED" = "0" ]; then
  echo "  * git config --global user.name  'Your Name'"
  echo "  * git config --global user.email 'you@example.com'"
  echo "    (or pass GIT_NAME=... GIT_EMAIL=... when running pod_setup.sh)"
fi
if [ -z "${GH_USER:-}" ]; then
  echo "  * echo 'export GH_USER=<your-github-username>' >> ~/.bashrc"
  echo "    (or re-run with: GH_USER=<you> bash pod_setup.sh)"
fi
if [ "$INSTALL_CODEX" = "1" ] && [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "  * (optional) OPENAI_API_KEY=sk-... bash pod_setup.sh   # writes to $SECRETS_FILE"
fi
echo "  * (optional) huggingface-cli login    # or:  export HF_TOKEN=..."
echo "  * Then run the relevant project setup script."
echo "============================================================"
