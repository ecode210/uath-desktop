# UATH NFC Bridge

Localhost companion that reads USB NFC cards (ACR122U) and sends MRNs to the
UATH staff EMR over `ws://127.0.0.1:8787`.

Keep this app open while using the staff portal. Quit other NFC tools (e.g. NFC
Tools) first - the reader can only be used by one app at a time.

## Install (release packages)

Build outputs land in `dist/`.

### macOS (build on a Mac)

```bash
make package-macos
```

Produces:

- `dist/UATH-NFC-Bridge-macos-<version>.dmg` - drag **UATH NFC Bridge** into Applications
- `dist/UATH-NFC-Bridge-macos-<version>.zip` - unzip and run the `.app`

First launch on another Mac: right-click the app → **Open** (Gatekeeper). For
hospital-wide distribution, sign with an Apple Developer ID and notarize.

### Windows (build on a Windows PC)

Flutter cannot cross-compile Windows from macOS. On a Windows machine with
Flutter + Visual Studio (Desktop development with C++):

```powershell
.\scripts\package_windows.ps1
```

Or push a `desktop-v*` tag / run the **Build desktop packages** GitHub Action and
download the Windows artifact.

Produces `dist/UATH-NFC-Bridge-windows-<version>.zip`. Unzip the folder and run
**UATH NFC Bridge.exe** (keep DLLs beside the exe).

## Develop

```bash
flutter run -d macos
```

VS Code / Cursor launch config: **UATH NFC Bridge**.

## Requirements

- USB NFC reader (ACS ACR122U or compatible PC/SC reader)
- Cards with NDEF Text MRN (`UATH/PT/#######`)
- Staff EMR open and logged in in the browser
