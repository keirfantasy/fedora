#!/usr/bin/env bash
#
# fedora-setup.sh — Fedora workstation bootstrap
# (packages, zsh, stow dotfiles, CLI tools, neovim)
#
# One-line install:
#   curl -fsSL https://raw.githubusercontent.com/Fantasy1231/fedora-setup/main/bootstrap.sh | bash
#
# Options: --desktop | --headless | --sync   (auto-detects desktop by default)
#   curl -fsSL https://raw.githubusercontent.com/Fantasy1231/fedora-setup/main/bootstrap.sh | bash -s -- --desktop
#
set -euo pipefail
set +H
export LC_ALL=C

DOTFILES_DIR="$HOME/Workspace/linux/dotfiles"

# ---- PATH ----
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/go/bin:$HOME/.opencode/bin:$HOME/.atuin/bin:$HOME/.fzf/bin:$PATH"
[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"

# ---- Helpers ----
log_info()  { printf '\033[1;34m%s\033[0m\n' "$*"; }
log_warn()  { printf '\033[1;33m%s\033[0m\n' "$*"; }
log_error() { printf '\033[1;31m%s\033[0m\n' "$*"; }

# ---- Sudo keep-alive ----
# A single `sudo -v` expires after ~5 min; this refreshes it in the background
# so long unattended runs never block on a password prompt mid-install.
SUDO_KEEPALIVE_PID=""
start_sudo_keepalive() {
  ( while true; do sudo -n true 2>/dev/null; sleep 50; kill -0 "$$" 2>/dev/null || exit 0; done ) &
  SUDO_KEEPALIVE_PID=$!
  trap 'stop_sudo_keepalive' EXIT
}
stop_sudo_keepalive() {
  [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
}

# Git identity: ~/.gitconfig.local (referenced by the dotfiles .gitconfig include).
# Kept out of the public dotfiles repo, so it must be created per-machine.
setup_gitconfig_local() {
  local target="$HOME/.gitconfig.local"

  if [[ -e "$target" ]]; then
    log_info "  git identity: ~/.gitconfig.local exists — leaving as-is"
    return 0
  fi

  local name="" email=""
  log_info "Configuring git identity (~/.gitconfig.local)..."
  # Only prompt if we have a terminal; otherwise fall through to the template stub.
  if [[ -e /dev/tty ]]; then
    read -rp "  Git user name  (blank = fill in later): " name < /dev/tty || true
    read -rp "  Git email      (blank = fill in later): " email < /dev/tty || true
  fi

  if [[ -n "$name" && -n "$email" ]]; then
    cat > "$target" <<EOF
[user]
	name = $name
	email = $email
EOF
    log_info "  git identity written to $target"
  else
    cat > "$target" <<'EOF'
# Local git identity — NOT tracked by the dotfiles repo.
# Fill in and uncomment:
#[user]
#	name = Your Name
#	email = you@example.com
EOF
    log_warn "  git identity left as a template — edit $target before committing"
  fi
}

STOW_TARGETS=(
  ".config/alacritty"
  ".config/atuin"
  ".config/fastfetch"
  ".config/herdr"
  ".config/lazygit"
  ".config/nvim"
  ".config/starship.toml"
  ".gitconfig"
  ".zshrc"
  ".zsh_aliases"
  ".zsh_apps"
  ".zsh_functions"
  ".zsh_keybinds"
  ".zsh_plugins"
)

# ---- Parse CLI flags ----
MODE_SYNC=0
IS_DESKTOP=-1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --desktop) IS_DESKTOP=1; shift ;;
    --headless) IS_DESKTOP=0; shift ;;
    --sync) MODE_SYNC=1; shift ;;
    --help) echo "Usage: $0 [--desktop|--headless|--sync]"; exit 0 ;;
    *) log_error "Unknown flag: $1"; exit 1 ;;
  esac
done

if (( IS_DESKTOP == -1 )); then
  if [[ -n "${WSL_DISTRO_NAME:-}" || -f /proc/sys/fs/binfmt_misc/WSLInterop ]]; then
    IS_DESKTOP=0
    log_info "WSL detected — desktop extras (fonts, nvidia) will be skipped."
  elif [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
    IS_DESKTOP=1
  else
    IS_DESKTOP=0
    log_warn "No display detected — desktop extras (fonts, nvidia) will be skipped."
    log_warn "Override with --desktop if this is a GUI system running headless."
  fi
fi
# ----------------------------------------------------------------------
# PHASE 0 — Prerequisites
# ----------------------------------------------------------------------
phase0() {
  log_info "--- Phase 0: Prerequisites ---"

  if ! command -v sudo &>/dev/null; then
    log_error "sudo is required"
    exit 1
  fi
  sudo -v  # refresh sudo timestamp
  start_sudo_keepalive  # keep sudo alive for the whole unattended run

  if ! command -v dnf &>/dev/null; then
    log_error "dnf is not available — this script targets Fedora only"
    exit 1
  fi

  if ! command -v stow &>/dev/null; then
    log_info "stow: installing..."
    sudo dnf install -y stow
  fi

  log_info "Phase 0 complete"
}

# ----------------------------------------------------------------------
# PHASE 1 — System packages
# ----------------------------------------------------------------------
phase1() {
  log_info "--- Phase 1: System packages ---"

  local -a packages=()
  local -a desktop_packages=()

  # Core
  # Note: Rust toolchain is provided by rustup (phase 4), not distro cargo/rust,
  # so those are intentionally omitted here to avoid a conflicting rustc on PATH.
  for pkg in zsh stow neovim git unzip fontconfig gcc make cmake curl wget perl \
             python3 python3-pip python3-devel nodejs npm go ruby ruby-devel php graphviz \
             ripgrep fd-find luarocks ImageMagick ghostscript htop \
             trash-cli tree net-tools bzip2 strace p7zip p7zip-plugins snapd flatpak; do
    if ! rpm -q "$pkg" &>/dev/null; then
      packages+=("$pkg")
    fi
  done

  if (( IS_DESKTOP )); then
    for pkg in alacritty wl-clipboard xclip; do
      if ! rpm -q "$pkg" &>/dev/null; then
        desktop_packages+=("$pkg")
      fi
    done
  fi

  if (( ${#packages[@]} > 0 )); then
    log_info "Installing packages: ${packages[*]}"
    sudo dnf install -y --skip-broken --skip-unavailable "${packages[@]}"
  fi

  if (( ${#desktop_packages[@]} > 0 )); then
    log_info "Installing desktop packages: ${desktop_packages[*]}"
    sudo dnf install -y --skip-broken --skip-unavailable "${desktop_packages[@]}"
  fi

  # ---- GitHub CLI ----
  if ! command -v gh &>/dev/null; then
    log_info "gh: adding GitHub CLI repo and installing..."
    sudo dnf install -y dnf-plugins-core
    local gh_repo="https://cli.github.com/packages/rpm/gh-cli.repo"
    # dnf5 (Fedora 41+) uses `config-manager addrepo`; dnf4 uses `--add-repo`.
    if sudo dnf config-manager addrepo --from-repofile="$gh_repo" 2>/dev/null; then
      :
    else
      sudo dnf config-manager --add-repo "$gh_repo"
    fi
    sudo dnf install -y gh
  fi

  log_info "Phase 1 complete"
}

# ----------------------------------------------------------------------
# PHASE 2 — Zsh
# ----------------------------------------------------------------------
phase2() {
  log_info "--- Phase 2: Zsh ---"

  if ! rpm -q zsh &>/dev/null; then
    sudo dnf install -y zsh
  fi

  local zsh_path
  zsh_path="$(command -v zsh)"
  if [[ "$SHELL" != "$zsh_path" ]]; then
    sudo usermod -s "$zsh_path" "$USER"
    log_info "Default shell set to $zsh_path"
    log_info "Log out and back in, or run: exec zsh"
  else
    log_info "zsh is already the default shell"
  fi

  log_info "Phase 2 complete"
}

# ----------------------------------------------------------------------
# PHASE 3 — Dotfiles via stow
# ----------------------------------------------------------------------
phase3() {
  log_info "--- Phase 3: Dotfiles ---"

  # Clone or pull the dotfiles repo (public HTTPS — no SSH key required)
  if [[ -d "$DOTFILES_DIR/.git" ]]; then
    cd "$DOTFILES_DIR"
    if ! git pull --ff-only; then
      log_error "dotfiles repo has diverged — resolve manually in $DOTFILES_DIR"
      exit 1
    fi
  else
    log_info "Cloning dotfiles repo..."
    mkdir -p "$(dirname "$DOTFILES_DIR")"
    git clone https://github.com/Fantasy1231/dotfiles.git "$DOTFILES_DIR"
  fi

  # Verify .stow-local-ignore exists
  if [[ ! -f "$DOTFILES_DIR/.stow-local-ignore" ]]; then
    log_warn ".stow-local-ignore not found in dotfiles repo — zinit/ and usr/ may be symlinked"
  fi

  # Backup conflicting targets
  local backup_dir="$HOME/.config-backup/setup-$(date +%Y%m%d-%H%M%S)"
  local has_conflicts=0
  for t in "${STOW_TARGETS[@]}"; do
    if [ -e "$HOME/$t" ] && [ ! -L "$HOME/$t" ]; then
      mkdir -p "$backup_dir/$(dirname "$t")"
      mv "$HOME/$t" "$backup_dir/$t"
      log_info "  Backed up $t → $backup_dir/$t"
      has_conflicts=1
    fi
  done

  # Stow
  cd "$DOTFILES_DIR"
  stow --no-folding . --target="$HOME"
  if (( has_conflicts )); then
    log_info "Backups saved to $backup_dir"
  fi

  # Git identity (~/.gitconfig.local, referenced by the dotfiles .gitconfig include)
  setup_gitconfig_local

  log_info "Phase 3 complete"
}

# ----------------------------------------------------------------------
# PHASE 4 — CLI tools
# ----------------------------------------------------------------------
phase4() {
  log_info "--- Phase 4: CLI tools ---"

  local -a tools=(rustup fzf zoxide atuin starship lazygit uv opencode herdr)
  for tool in "${tools[@]}"; do
    if install_"$tool"; then
      log_info "  $tool: OK"
    else
      log_error "  $tool: FAILED"
    fi
  done

  # Tree-sitter via npm
  if install_tree_sitter_cli; then
    log_info "  tree-sitter-cli: OK"
  else
    log_warn "  tree-sitter-cli: FAILED"
  fi

  # pip
  if install_pip_tools; then
    log_info "  pynvim: OK"
  else
    log_warn "  pynvim: FAILED"
  fi

  # npm
  if install_npm_tools; then
    log_info "  npm tools: OK"
  else
    log_warn "  npm tools: FAILED"
  fi

  # gem
  if install_gem_tools; then
    log_info "  neovim gem: OK"
  else
    log_warn "  neovim gem: FAILED"
  fi

  # composer
  if install_composer; then
    log_info "  composer: OK"
  else
    log_warn "  composer: FAILED"
  fi

  # fastfetch
  if install_fastfetch; then
    log_info "  fastfetch: OK"
  else
    log_warn "  fastfetch: FAILED"
  fi

  # ---- Docker ----
  if ! command -v docker &>/dev/null; then
    log_info "docker: installing..."
    sudo dnf install -y moby-engine docker-compose
    if systemctl is-system-running &>/dev/null; then
      sudo systemctl enable --now docker
    fi
    sudo usermod -aG docker "$USER"
    log_info "docker installed — log out and back in for group membership to take effect"
  fi

  # ---- Snapd ----
  if command -v snap &>/dev/null && ! snap list 2>/dev/null | grep -q .; then
    if systemctl is-system-running &>/dev/null; then
      sudo systemctl enable --now snapd.socket
      sudo ln -sf /var/lib/snapd/snap /snap
      log_info "snapd socket enabled"
    fi
  fi

  log_info "Phase 4 complete"
}

# ----------------------------------------------------------------------
# PHASE 5 — Desktop extras
# ----------------------------------------------------------------------
phase5() {
  if (( ! IS_DESKTOP )); then
    log_info "--- Phase 5: Desktop extras (skipped — headless mode) ---"
    return
  fi

  log_info "--- Phase 5: Desktop extras ---"

  # ---- RPM Fusion (needed for Nvidia) ----
  if ! rpm -q rpmfusion-free-release &>/dev/null; then
    log_info "RPM Fusion: enabling..."
    local fedora_ver
    fedora_ver=$(rpm -E %fedora)
    sudo dnf install -y \
      "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedora_ver}.noarch.rpm" \
      "https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedora_ver}.noarch.rpm"
  fi

  # ---- Hack Nerd Font ----
  local font_dir="$HOME/.local/share/fonts"
  if ls "$font_dir"/Hack*NF* &>/dev/null 2>&1; then
    log_info "Hack Nerd Font already installed"
  else
    log_info "Hack Nerd Font: installing..."
    local tmp_dir
    tmp_dir=$(mktemp -d)
    if curl -L --fail -o "$tmp_dir/Hack.zip" "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.4.0/Hack.zip"; then
      mkdir -p "$font_dir"
      unzip -o "$tmp_dir/Hack.zip" -d "$font_dir" >/dev/null 2>&1
      fc-cache -f "$font_dir" 2>/dev/null
      log_info "Hack Nerd Font installed"
    else
      log_warn "Failed to download Hack Nerd Font"
    fi
    rm -rf "$tmp_dir"
  fi

  # ---- Nvidia driver ----
  if rpm -q akmod-nvidia &>/dev/null; then
    log_info "Nvidia driver already installed"
  else
    log_info "Nvidia: installing driver..."
    sudo dnf install -y akmod-nvidia xorg-x11-drv-nvidia-cuda || log_warn "Nvidia install had issues"
  fi

  # ---- unrar (requires RPM Fusion nonfree) ----
  if ! rpm -q unrar &>/dev/null; then
    sudo dnf install -y unrar || log_warn "unrar not available (RPM Fusion nonfree may be missing)"
  fi

  log_info "Phase 5 complete"
}

# ----------------------------------------------------------------------
# PHASE 6 — Neovim
# ----------------------------------------------------------------------
# nvim_headless_sync <restore|sync>
#   restore = install exactly the pinned commits from lazy-lock.json (fresh provision)
#   sync    = update plugins to latest and refresh the lockfile (maintenance)
# Lazy + Treesitter run in a single nvim invocation so treesitter parsers are
# only built after the plugins they depend on are installed (no cross-process race).
nvim_headless_sync() {
  local mode="${1:-restore}"
  local lazy_cmd
  case "$mode" in
    sync) lazy_cmd='+Lazy! sync' ;;
    *)    lazy_cmd='+Lazy! restore' ;;
  esac

  echo "--- $(date) ($mode) ---" >> /tmp/nvim-setup.log

  log_info "Neovim: running headless $mode + treesitter update..."
  for attempt in 1 2; do
    if nvim --headless "$lazy_cmd" \
         '+TSUpdateSync bash regex lua json yaml toml python javascript typescript' \
         +qa 2>>/tmp/nvim-setup.log; then
      log_info "  Neovim provisioned (attempt $attempt)"
      break
    else
      log_warn "  Neovim provisioning failed (attempt $attempt)"
      if (( attempt == 2 )); then
        log_error "  Neovim provisioning failed after 2 attempts"
        log_error "  Log: /tmp/nvim-setup.log"
      fi
      sleep 5
    fi
  done
}

phase6() {
  log_info "--- Phase 6: Neovim ---"

  local init_lua="$HOME/.config/nvim/init.lua"

  if [ -L "$init_lua" ]; then
    log_info "Neovim config deployed via dotfiles stow"
  elif [ -e "$init_lua" ]; then
    log_warn "~/.config/nvim/init.lua exists but is not the stowed dotfiles config — leaving as-is"
  else
    log_error "Neovim config not found at $init_lua — did phase 3 (stow) run? Skipping nvim provisioning."
    return
  fi

  # Install plugins at their pinned versions (lazy-lock.json) and compile parsers.
  nvim_headless_sync restore

  log_info "Phase 6 complete"
}

# ----------------------------------------------------------------------
# Install functions
# ----------------------------------------------------------------------

install_rustup() {
  command -v rustc && return 0
  log_info "rustup: installing..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
  command -v rustc || { log_error "rustup install failed"; exit 1; }
}

install_fzf() {
  command -v fzf && return 0
  log_info "fzf: installing..."
  if [[ -d ~/.fzf ]]; then
    cd ~/.fzf && git pull
  else
    git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
  fi
  ~/.fzf/install --all
  [[ -x ~/.fzf/bin/fzf ]] && ln -sf ~/.fzf/bin/fzf ~/.local/bin/fzf
  command -v fzf || { log_error "fzf install failed"; exit 1; }
}

install_zoxide() {
  command -v zoxide && return 0
  log_info "zoxide: installing..."
  curl -sSfL https://webi.sh/zoxide | sh
  command -v zoxide || { log_error "zoxide install failed"; exit 1; }
}

install_atuin() {
  command -v atuin && return 0
  log_info "atuin: installing..."
  curl -fsSL https://setup.atuin.sh | bash
  [[ -x ~/.atuin/bin/atuin ]] && ln -sf ~/.atuin/bin/atuin ~/.local/bin/atuin
  command -v atuin || { log_error "atuin install failed"; exit 1; }
}

install_starship() {
  command -v starship && return 0
  log_info "starship: installing..."
  curl -fsSL https://starship.rs/install.sh | sh -s -- -y
  command -v starship || { log_error "starship install failed"; exit 1; }
  if command -v starship &>/dev/null && [ ! -L "$HOME/.config/starship.toml" ] && [ ! -f "$HOME/.config/starship.toml" ]; then
    mkdir -p "$HOME/.config"
    starship preset pure-preset -o "$HOME/.config/starship.toml" 2>/dev/null || true
  fi
}

install_lazygit() {
  command -v lazygit && return 0
  log_info "lazygit: installing..."
  GOBIN="$HOME/.local/bin" go install github.com/jesseduffield/lazygit@latest
  command -v lazygit || { log_error "lazygit install failed"; exit 1; }
}

install_uv() {
  command -v uv && return 0
  log_info "uv: installing..."
  curl -fsSL https://astral.sh/uv/install.sh | sh
  command -v uv || { log_error "uv install failed"; exit 1; }
}

install_opencode() {
  command -v opencode && return 0
  log_info "opencode: installing..."
  curl -fsSL https://opencode.ai/install | bash
  command -v opencode || { log_error "opencode install failed"; exit 1; }
}

install_herdr() {
  command -v herdr && return 0
  log_info "herdr: installing..."
  curl -fsSL https://herdr.dev/install.sh | sh
  command -v herdr || { log_error "herdr install failed"; exit 1; }
}

update_opencode() {
  log_info "opencode: updating..."
  curl -fsSL https://opencode.ai/install | bash
  command -v opencode || log_warn "opencode update failed"
}

update_fzf() {
  if [[ ! -d ~/.fzf ]]; then
    install_fzf
    return
  fi
  log_info "fzf: updating..."
  cd ~/.fzf && git pull --ff-only
  ~/.fzf/install --all
  [[ -x ~/.fzf/bin/fzf ]] && ln -sf ~/.fzf/bin/fzf ~/.local/bin/fzf
  command -v fzf || { log_error "fzf update failed"; return 1; }
}

install_tree_sitter_cli() {
  command -v tree-sitter && return 0
  log_info "tree-sitter-cli: installing via npm..."
  npm install --prefix "$HOME/.local" tree-sitter-cli
  command -v tree-sitter || { log_error "tree-sitter-cli install failed"; exit 1; }
}

install_pip_tools() {
  python3 -c "import pynvim" 2>/dev/null && return 0
  log_info "pip tools: installing..."
  pip install --user --upgrade pynvim
  python3 -c "import pynvim" || { log_error "pynvim install failed"; exit 1; }
}

install_npm_tools() {
  local npm_prefix="$HOME/.local"
  if [[ -d "$npm_prefix/lib/node_modules/neovim" ]]; then
    return 0
  fi
  log_info "npm tools: installing..."
  npm install --prefix "$npm_prefix" neovim @mermaid-js/mermaid-cli
}

install_gem_tools() {
  gem list -i neovim 2>/dev/null && return 0
  log_info "gem tools: installing..."
  gem install --user-install --no-document neovim
  gem list -i neovim || { log_error "neovim gem install failed"; exit 1; }
}

install_composer() {
  command -v composer && return 0
  log_info "composer: installing via dnf..."
  sudo dnf install -y composer
  command -v composer || { log_error "composer install failed"; exit 1; }
}

install_fastfetch() {
  command -v fastfetch && return 0
  log_info "fastfetch: installing via dnf..."
  sudo dnf install -y fastfetch 2>/dev/null || log_warn "fastfetch not in repos (enable RPM Fusion or install manually)"
}

# ----------------------------------------------------------------------
# Sync (maintenance mode)
# ----------------------------------------------------------------------
sync_main() {
  local dotfiles="$HOME/Workspace/linux/dotfiles"

  log_info "--- Sync: dotfiles ---"
  cd "$dotfiles"
  if ! git pull --ff-only; then
    log_error "dotfiles repo has diverged — resolve manually in $dotfiles"
    exit 1
  fi
  log_info "  OK"

  log_info "--- Sync: stow ---"
  local backup_dir="$HOME/.config-backup/sync-$(date +%s)"
  for t in "${STOW_TARGETS[@]}"; do
    if [ -e "$HOME/$t" ] && [ ! -L "$HOME/$t" ]; then
      mkdir -p "$backup_dir/$(dirname "$t")"
      mv "$HOME/$t" "$backup_dir/$t"
      log_info "  Backed up $t"
    fi
  done
  cd "$dotfiles" && stow --restow --no-folding . --target="$HOME"
  log_info "  OK"

  log_info "--- Sync: tools ---"
  for tool in rustup zoxide atuin starship lazygit uv herdr; do
    if install_"$tool"; then log_info "  $tool: OK"; else log_warn "  $tool: FAILED"; fi
  done
  if update_fzf; then log_info "  fzf: OK"; else log_warn "  fzf: FAILED"; fi
  if update_opencode; then log_info "  opencode: OK"; else log_warn "  opencode: FAILED"; fi

  if [[ -d "$HOME/.local/lib/node_modules/neovim" ]]; then
    npm update --prefix "$HOME/.local" 2>/dev/null && log_info "  npm tools: OK" || log_warn "  npm tools: FAILED"
    npm update -g 2>/dev/null && log_info "  npm global: OK" || log_warn "  npm global: FAILED"
  fi
  pip install --user --upgrade pip pynvim 2>/dev/null && log_info "  pip: OK" || log_warn "  pip: FAILED"

  log_info "--- Sync: neovim ---"
  nvim_headless_sync sync

  log_info "--- Sync complete ---"
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
main() {
  if (( MODE_SYNC )); then
    sync_main
    return
  fi

  phase0
  phase1
  phase2
  phase3
  phase4
  phase5
  phase6

  echo
  log_info "--- Setup complete ---"
  log_info "Log out and back in (or exec zsh) to switch to zsh."
}

# Run main when executed (normally or piped); skip only when sourced.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] || [[ -z "${BASH_SOURCE[0]:-}" ]]; then
  main "$@"
fi
true
