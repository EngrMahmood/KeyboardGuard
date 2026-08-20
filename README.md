# KeyboardGuard

A Windows utility to **block** or **remap** a single key on a **specific physical keyboard**, without affecting any other key, any other keyboard (e.g. an external USB keyboard), the on-screen keyboard, or the touch keyboard. Built to fix a laptop with a stuck/faulty key on its built-in keyboard.

## Why this exists

A normal "disable a key" trick (Windows Scancode Map registry hack) is global — it disables that key on *every* keyboard plugged into the machine, including an external one, and can also affect the on-screen keyboard. Disabling the entire built-in keyboard device works, but you lose every key, not just the broken one.

KeyboardGuard uses the [Interception](https://github.com/oblitum/Interception) kernel driver to filter input **per physical device**, so it can block or remap exactly one key on exactly one keyboard.

## Features

- **Block a Key** — swallow a specific key on a specific keyboard so it never reaches Windows.
- **Remap a Key** — swallow a specific key on a specific keyboard and send a different key/combo instead (so you can reuse a faulty key's position for something else).
- **Protect the lock/login screen** — installs itself as a Windows Service (via [NSSM](https://nssm.cc/)) that starts at boot, before any user logs in, so blocking/remapping is active even on the password screen.
- Self-contained: the compiled exe embeds its own copy of the AutoHotInterception bridge, the Interception driver installer, and NSSM, and extracts them next to itself on first run.

## Requirements

- Windows 10/11
- Administrator rights (the app self-elevates)
- A reboot after installing the Interception driver (kernel drivers only load after a restart)

## Install

Run `KeyboardGuard-Setup.exe`. It installs to `C:\Program Files\KeyboardGuard`, adds Start Menu/Desktop shortcuts, and automatically installs the Interception driver (you'll be asked to restart).

## Usage

1. **Step 1** — confirm the driver is installed (the installer does this for you); reboot if you just installed it.
2. **Step 2** — click "Refresh Keyboard List" and select the keyboard with the faulty key (an internal/laptop keyboard usually shows an `ACPI\...` handle).
3. **Block a Key tab** — "Capture Key From Selected", press the faulty key, "Add As Blocked Rule", then "Start Blocking".
   **Remap a Key tab** — "Capture Source Key" (the faulty key), "Capture Key To Send Instead" (any key/combo, from any keyboard), "Add As Remap Rule", then "Start Remapping".
4. **Step 3** — "Install As Service" to keep the block/remap active from boot, including the lock/login screen.

## Building from source

Requires [AutoHotkey v2](https://www.autohotkey.com/) (specifically its compiler, [Ahk2Exe](https://github.com/AutoHotkey/Ahk2Exe)) and [Inno Setup](https://jrsoftware.org/isinfo.php).

1. Place these third-party files next to `KeyboardGuard.ahk` before compiling (see Third-party components below for sources):
   - `AutoHotInterception.dll` and `Lib\AutoHotInterception.ahk`, `Lib\CLR.ahk`, `Lib\x64\interception.dll`, `Lib\x86\interception.dll` (from [AutoHotInterception](https://github.com/evilC/AutoHotInterception))
   - `install-interception.exe` (from [Interception](https://github.com/oblitum/Interception))
   - `nssm.exe` (from [NSSM](https://nssm.cc/))
2. Compile: `Ahk2Exe.exe /in KeyboardGuard.ahk /out KeyboardGuard.exe /base AutoHotkey64.exe`
3. Build the installer: `ISCC.exe KeyboardGuard.iss`

## Third-party components

This project bundles/relies on:
- [Interception](https://github.com/oblitum/Interception) - LGPL 3.0 (non-commercial usage license included in its release; see its repo for commercial terms)
- [AutoHotInterception](https://github.com/evilC/AutoHotInterception) by evilC
- [NSSM](https://nssm.cc/) - public domain / dual-licensed
- [AutoHotkey v2](https://www.autohotkey.com/)

## Disclaimer

This tool filters raw keyboard input at the driver level. Use it responsibly, and always keep a way to type "=" (on-screen keyboard, an external keyboard) reachable while testing a new rule, in case a rule is misconfigured.
