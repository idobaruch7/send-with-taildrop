#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_SRC="$ROOT_DIR/scripts/send-with-taildrop.sh"
DESKTOP_SRC="$ROOT_DIR/desktop/send-with-taildrop.desktop"

BIN_DST="$HOME/.local/bin/send-with-taildrop"
SERVICE_DIR="$HOME/.local/share/kio/servicemenus"
DESKTOP_DST="$SERVICE_DIR/send-with-taildrop.desktop"

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

refresh_kde_cache() {
  if command -v kbuildsycoca6 >/dev/null 2>&1; then
    kbuildsycoca6 >/dev/null 2>&1 || true
  elif command -v kbuildsycoca5 >/dev/null 2>&1; then
    kbuildsycoca5 >/dev/null 2>&1 || true
  fi
}

verify_install() {
  local expected_exec="Exec=/usr/bin/env bash \"$BIN_DST\" %F"
  local expected_tryexec="TryExec=/usr/bin/env"

  if [[ ! -x "$BIN_DST" ]]; then
    printf 'Install verification failed: %s is not executable.\n' "$BIN_DST" >&2
    exit 1
  fi

  if ! grep -Fxq "$expected_exec" "$DESKTOP_DST"; then
    printf 'Install verification failed: desktop Exec entry is not set correctly.\n' >&2
    exit 1
  fi

  if ! grep -Fxq "$expected_tryexec" "$DESKTOP_DST"; then
    printf 'Install verification failed: desktop TryExec entry is not set correctly.\n' >&2
    exit 1
  fi
}

usage() {
  cat <<'EOF'
Usage:
  ./scripts/install.sh           Install Send with taildrop integration
  ./scripts/install.sh --uninstall  Remove installed integration
EOF
}

install_files() {
  mkdir -p "$(dirname "$BIN_DST")"
  mkdir -p "$SERVICE_DIR"

  install -m 0755 "$BIN_SRC" "$BIN_DST"
  sed "s|@BIN_PATH@|$(escape_sed_replacement "$BIN_DST")|g" "$DESKTOP_SRC" > "$DESKTOP_DST"
  chmod 0755 "$DESKTOP_DST"
  chmod 0755 "$BIN_DST"

  verify_install
  refresh_kde_cache

  cat <<EOF
Installed:
- $BIN_DST
- $DESKTOP_DST

Right-click a file or directory in Dolphin and choose:
Send with taildrop
EOF
}

uninstall_files() {
  rm -f "$BIN_DST" "$DESKTOP_DST"

  refresh_kde_cache

  cat <<EOF
Removed:
- $BIN_DST
- $DESKTOP_DST
EOF
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  if [[ "${1:-}" == "--uninstall" ]]; then
    uninstall_files
    exit 0
  fi

  install_files
}

main "$@"
