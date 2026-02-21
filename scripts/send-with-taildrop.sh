#!/usr/bin/env bash
set -euo pipefail

err() {
  local msg="$1"
  if command -v kdialog >/dev/null 2>&1; then
    kdialog --error "$msg" --title "Send with taildrop"
  else
    printf 'Error: %s\n' "$msg" >&2
  fi
}

info() {
  local msg="$1"
  if command -v kdialog >/dev/null 2>&1; then
    kdialog --msgbox "$msg" --title "Send with taildrop"
  else
    printf '%s\n' "$msg"
  fi
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "Missing required command: $cmd"
    exit 1
  fi
}

pick_device() {
  local status_json
  if ! status_json="$(tailscale status --json 2>/dev/null)"; then
    err "Unable to read Tailscale status. Make sure tailscale is installed and you are logged in."
    exit 1
  fi

  local selection_data
  if ! selection_data="$(python3 - "$status_json" <<'PY'
import json
import sys

raw = sys.argv[1]
try:
    data = json.loads(raw)
except Exception:
    sys.exit(2)

peers = data.get("Peer", {})
self_user_id = (data.get("Self") or {}).get("UserID")
if self_user_id is not None:
  self_user_id = str(self_user_id)

if not peers:
    print("__NO_DEVICES__")
    sys.exit(0)

rows = []
for _, peer in peers.items():
  peer_user_id = peer.get("UserID")
  if self_user_id is not None and str(peer_user_id) != self_user_id:
    continue

  dns_name = (peer.get("DNSName") or "").rstrip(".")
  name = peer.get("HostName") or peer.get("Name") or dns_name or "unknown"
  target = dns_name or name
  online = bool(peer.get("Online", False))
  if not online:
    continue
  rows.append((name.lower(), target, name))

if not rows:
  print("__NO_MATCHING_DEVICES__")
  sys.exit(0)

rows.sort(key=lambda x: x[0])
for _, target, name in rows:
  shown_target = target
  if shown_target.endswith(".vpn.internal"):
      shown_target = shown_target[: -len(".vpn.internal")]
  print(target)
  print(f"{shown_target} [{name}]")
PY
)"; then
    err "Failed to parse Tailscale device list from status output."
    exit 1
  fi

  if [[ "$selection_data" == "__NO_DEVICES__" ]]; then
    err "No Tailnet devices found."
    exit 1
  fi

  if [[ "$selection_data" == "__NO_MATCHING_DEVICES__" ]]; then
    err "No online devices found for your user."
    exit 1
  fi

  local menu_args=()
  while IFS= read -r target && IFS= read -r label; do
    menu_args+=("$target" "$label")
  done <<< "$selection_data"

  if [[ ${#menu_args[@]} -eq 0 ]]; then
    err "No devices available in Tailscale status output."
    exit 1
  fi

  local chosen
  if ! chosen="$(kdialog --menu "Select target device" "${menu_args[@]}" --title "Send with taildrop")"; then
    return 130
  fi

  printf '%s\n' "$chosen"
}

send_paths() {
  local target="$1"
  shift

  local total="$#"
  local sent=0
  local failed=0
  local failed_items=()

  for path in "$@"; do
    if [[ ! -e "$path" ]]; then
      ((failed+=1))
      failed_items+=("$path (not found)")
      continue
    fi

    if tailscale file cp "$path" "$target:" >/dev/null 2>&1; then
      ((sent+=1))
    else
      ((failed+=1))
      failed_items+=("$path")
    fi
  done

  local summary="Sent $sent/$total item(s) to $target."
  if (( failed > 0 )); then
    summary+=$'\n\nFailed item(s):'
    for item in "${failed_items[@]}"; do
      summary+=$'\n- '
      summary+="$item"
    done
  fi

  info "$summary"

  if (( failed > 0 )); then
    exit 1
  fi
}

main() {
  if [[ "$#" -lt 1 ]]; then
    err "No file or directory selected."
    exit 1
  fi

  require_cmd tailscale
  require_cmd kdialog
  require_cmd python3

  local target
  if ! target="$(pick_device)"; then
    local pick_rc=$?
    if [[ $pick_rc -eq 130 ]]; then
      exit 0
    fi
    exit "$pick_rc"
  fi

  if [[ -z "$target" ]]; then
    exit 0
  fi

  send_paths "$target" "$@"
}

main "$@"
