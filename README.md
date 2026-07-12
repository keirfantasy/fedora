Fedora setup: packages, zsh, dotfiles (in `dotfiles/`, deployed via stow), CLI tools, neovim.

One-line install:

curl -fsSL <https://raw.githubusercontent.com/keirfantasy/fedora/main/bootstrap.sh> | bash

Pass options through with `-s --`, e.g.:

curl -fsSL <https://raw.githubusercontent.com/keirfantasy/fedora/main/bootstrap.sh> | bash -s -- --sync

The bootstrap downloads fedora-setup.sh to a temp file and runs it with the
terminal attached. The setup clones this repo to ~/Workspace/linux/fedora and
stows `dotfiles/` into $HOME.

Maintenance re-run:
  ./fedora-setup.sh --sync
