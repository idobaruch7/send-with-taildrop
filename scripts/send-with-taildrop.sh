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

QDBUS=""

find_qdbus() {
  local cmd
  for cmd in qdbus6 qdbus-qt6 qdbus-qt5 qdbus; do
    if command -v "$cmd" >/dev/null 2>&1; then
      QDBUS="$cmd"
      return 0
    fi
  done
  err "Missing required command: qdbus (install qdbus6, qdbus-qt6, qdbus-qt5, or qdbus)"
  exit 1
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

  local shown_target="$target"
  if [[ "$shown_target" == *.vpn.internal ]]; then
    shown_target="${shown_target%.vpn.internal}"
  fi

  local total="$#"
  local sent=0
  local failed=0
  local failed_items=()
  local cancelled=false

  # --- Preparation phase: validate paths, zip directories, collect sizes ---
  local -a send_paths_arr=()   # actual path to send (file or zip)
  local -a orig_paths_arr=()   # original user-facing path
  local -a send_sizes_arr=()   # byte size of send_path
  local -a temp_dirs_arr=()    # temp dir to clean up (empty string if none)
  local total_size=0

  for path in "$@"; do
    if [[ ! -e "$path" ]]; then
      ((failed+=1))
      failed_items+=("$path (not found)")
      continue
    fi

    local send_path="$path"
    local temp_zip_dir=""

    if [[ -d "$path" ]]; then
      local normalized_path="$path"
      if [[ "$normalized_path" != "/" ]]; then
        normalized_path="${normalized_path%/}"
      fi

      local folder_parent
      local folder_name
      folder_parent="$(dirname "$normalized_path")"
      folder_name="$(basename "$normalized_path")"

      temp_zip_dir="$(mktemp -d)"
      send_path="$temp_zip_dir/$folder_name.zip"

      if ! (cd "$folder_parent" && zip -rq "$send_path" "$folder_name"); then
        ((failed+=1))
        failed_items+=("$path (zip failed)")
        rm -rf "$temp_zip_dir"
        continue
      fi
    fi

    local fsize
    fsize="$(stat -c%s "$send_path")"

    send_paths_arr+=("$send_path")
    orig_paths_arr+=("$path")
    send_sizes_arr+=("$fsize")
    temp_dirs_arr+=("$temp_zip_dir")
    total_size=$((total_size + fsize))
  done

  local sendable=${#send_paths_arr[@]}

  # Cleanup helper for all remaining temp dirs
  cleanup_temp_dirs() {
    local i
    for i in "${!temp_dirs_arr[@]}"; do
      if [[ -n "${temp_dirs_arr[$i]}" ]]; then
        rm -rf "${temp_dirs_arr[$i]}"
        temp_dirs_arr[$i]=""
      fi
    done
  }

  if (( sendable == 0 )); then
    # Nothing sendable — just show failures
    local summary="Sent 0/$total item(s) to $shown_target."
    if (( failed > 0 )); then
      summary+=$'\n\nFailed item(s):'
      for item in "${failed_items[@]}"; do
        summary+=$'\n- '
        summary+="$item"
      done
    fi
    info "$summary"
    cleanup_temp_dirs
    exit 1
  fi

  # --- Progress bar setup ---
  local dbus_ref
  dbus_ref="$(kdialog --progressbar "Preparing to send..." 100 --title "Send with taildrop")"
  $QDBUS $dbus_ref showCancelButton true 2>/dev/null || true

  close_progress() {
    $QDBUS $dbus_ref close 2>/dev/null || true
  }

  # Ensure progress bar is closed on unexpected exit
  trap 'close_progress; cleanup_temp_dirs' EXIT

  # --- Sending loop with pv byte-level progress ---
  local base_pct=0

  for i in "${!send_paths_arr[@]}"; do
    local sp="${send_paths_arr[$i]}"
    local op="${orig_paths_arr[$i]}"
    local fsize="${send_sizes_arr[$i]}"
    local tdir="${temp_dirs_arr[$i]}"
    local fname
    fname="$(basename "$sp")"

    # Check for cancellation
    if [[ "$($QDBUS $dbus_ref wasCancelled 2>/dev/null)" == "true" ]]; then
      cancelled=true
      break
    fi

    # Calculate this file's weight in the overall 0-100% bar
    local file_weight=0
    if (( total_size > 0 )); then
      file_weight=$(( fsize * 100 / total_size ))
    fi

    local file_num=$(( i + 1 ))
    $QDBUS $dbus_ref setLabelText "Sending: $fname ($file_num/$sendable)" 2>/dev/null || true

    # Send via pv | tailscale file cp - target:
    # pv -n outputs percentage (0-100) lines on stderr
    local pv_rc=0
    local ts_rc=0

    pv -n -s "$fsize" "$sp" \
      2> >(while IFS= read -r pct; do
             local overall=$(( base_pct + pct * file_weight / 100 ))
             if (( overall > 100 )); then overall=100; fi
             $QDBUS $dbus_ref Set "" value "$overall" 2>/dev/null || true
           done) \
      | tailscale file cp --name="$fname" - "$target:" >/dev/null 2>&1 \
      || ts_rc=$?

    # Small delay to let the progress reader subshell finish
    sleep 0.05

    if (( ts_rc == 0 )); then
      ((sent+=1))
    else
      ((failed+=1))
      failed_items+=("$op")
    fi

    # Clean up this item's temp dir immediately
    if [[ -n "$tdir" ]]; then
      rm -rf "$tdir"
      temp_dirs_arr[$i]=""
    fi

    base_pct=$(( base_pct + file_weight ))

    # Snap progress to the accumulated base after each file
    if (( base_pct > 100 )); then base_pct=100; fi
    $QDBUS $dbus_ref Set "" value "$base_pct" 2>/dev/null || true
  done

  # --- Done: close progress bar, clean up, show summary ---
  if ! $cancelled; then
    $QDBUS $dbus_ref Set "" value 100 2>/dev/null || true
  fi
  close_progress
  cleanup_temp_dirs
  trap - EXIT

  if $cancelled; then
    info "Transfer cancelled. Sent $sent/$total item(s) to $shown_target before cancellation."
    exit 0
  fi

  local summary="Sent $sent/$total item(s) to $shown_target."
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

  require_cmd kdialog
  require_cmd tailscale
  require_cmd python3
  require_cmd zip
  require_cmd pv
  find_qdbus

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
