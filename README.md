# Send with taildrop (Linux)

<p align="center">
  <img src="https://github.com/user-attachments/assets/cf910f8d-4019-46ca-8f5c-b730194607dd"/>
</p>

Adds a right-click action in KDE Dolphin:

**Send via Tailscale...**

The action opens a GUI picker (KDialog), lets you choose a Tailnet device, then sends selected files/directories using Taildrop.

> Device picker note: only **online** devices owned by the same Tailscale user are shown (`peer.UserID == Self.UserID` and `peer.Online == true`).

## Requirements

- Linux desktop with KDE Dolphin service menus
- `tailscale` CLI installed and logged in
- `kdialog`
- `qdbus` (or `qdbus-qt5`/`qdbus-qt6`, ships with KDE Plasma)
- `python3`
- `zip`
- `pv` (pipe viewer — for transfer progress)

## Install

From this repo root:

```bash
chmod +x scripts/install.sh
./scripts/install.sh
```

You can safely re-run the installer any time. It is idempotent and repairs missing/broken launcher files automatically.

This installs:

- `~/.local/bin/send-with-taildrop`
- `~/.local/share/kio/servicemenus/send-with-taildrop.desktop`

## Use

1. In Dolphin, right-click one or more files/directories.
2. Click **Send via Tailscale...**.
3. Select the destination device (only your own-user, online devices are listed).
4. Confirm the result dialog.

## Uninstall

```bash
./scripts/install.sh --uninstall
```

## Troubleshooting

- If the menu item does not appear, restart Dolphin (`killall dolphin`) and open it again.
- If you see an execution/authorization error, repair everything with:
  - `./scripts/install.sh`
- If sending fails, verify:
  - `tailscale status`
  - target device exists in your Tailnet
  - sender is logged in and has network connectivity
- If no device appears, make sure at least one peer device has the same `UserID` as your current `Self.UserID` in `tailscale status --json`, and that it is online.
- Offline devices are filtered out by the picker.

## Why this is safe to use

This integration is designed to be low-risk and transparent:

- **User-triggered only**: It runs only when you explicitly click **Send via Tailscale...** in Dolphin (from [desktop/send-with-taildrop.desktop](desktop/send-with-taildrop.desktop)).
- **Installs to user scope only**: The installer writes only to:
  - `~/.local/bin/send-with-taildrop`
  - `~/.local/share/kio/servicemenus/send-with-taildrop.desktop`  
  (see [scripts/install.sh](scripts/install.sh))
- **No `sudo`, no system-wide modification**: It does not require root and does not modify `/usr`, `/etc`, or system services.
- **No hidden background daemon**: It is a one-shot script execution per click (see [scripts/send-with-taildrop.sh](scripts/send-with-taildrop.sh)).
- **Explicit destination selection**: You must choose the target device in a dialog before anything is sent.
- **Only selected items are sent**: It sends only the files/folders passed from Dolphin using `tailscale file cp`.
- **No destructive file operations**: The send script does not delete or alter your source files; it only reads paths and invokes Tailscale send.
- **Clear error reporting**: Missing dependencies and transfer failures are shown in dialogs, with failed items listed.
- **Auditable code**: The project is plain shell + desktop entry, so all behavior is easy to inspect in this repository.

Security of transport/authentication is provided by your existing Tailscale setup, so safety also depends on your Tailnet access controls and logged-in session state.
