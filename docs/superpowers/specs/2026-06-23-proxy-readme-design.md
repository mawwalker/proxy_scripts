# Proxy README And Remote Decoy Page Design

## Context

This repository currently contains:

- `install_proxy.sh`: an interactive installer for `Nginx + Xray (VLESS + WS + TLS)`
- `index.html`: a bundled decoy site, currently a Flappy Bird style game page

The user wants a public-facing `README.md` that explains usage and provides a true one-command installation path for a VPS deployment. The current installer copies `index.html` from the working directory, which breaks when the installer is executed directly from GitHub via `curl` because only the shell script exists on the target machine.

## Goals

- Add a practical `README.md` for public GitHub usage.
- Document two one-command execution forms:
  - `bash <(curl -fsSL ...)`
  - `curl -fsSL ... | bash`
- Recommend one command while still documenting both.
- Make remote single-file execution work by ensuring the decoy page can still be deployed when `index.html` is not present locally.
- Keep the existing local-file workflow working for users who clone the repository first.

## Non-Goals

- Changing the proxy protocol or Xray topology.
- Redesigning the decoy page.
- Adding a full test framework.
- Reworking unrelated parts of the installer.

## Proposed Changes

### 1. Installer decoy page fallback

Update `install_proxy.sh` so that decoy page deployment works in both execution modes:

- If `index.html` exists alongside the installer, copy it into `/var/www/html/index.html`.
- Otherwise, download `index.html` from the GitHub raw URL:
  - `https://raw.githubusercontent.com/mawwalker/proxy_scripts/main/index.html`

This preserves repository-local execution while making remote one-liners actually usable.

### 2. README structure

Add `README.md` with these sections:

1. Project overview
2. Features
3. Prerequisites
4. Recommended one-command install
5. Alternative one-command install
6. Interactive inputs
7. What the script installs/configures
8. Output parameters shown after deployment
9. Important notes and caveats

### 3. Verification approach

Because the repository currently has no test harness, use lightweight verification:

- `bash -n install_proxy.sh` for syntax validation
- a small regression check script that asserts the installer contains the local-or-remote `index.html` fallback logic

## Error Handling

- If remote `index.html` download fails, the installer should exit with a clear error instead of silently continuing with a missing decoy page.
- Status messages should tell the operator whether the decoy page was copied locally or downloaded remotely.

## README Messaging

- Describe the bundled decoy page accurately as a built-in小游戏伪装页.
- State that the server should be prepared with a domain already resolving to the VPS.
- State that ports `80` and `443` must be open.
- State that if Cloudflare is used, the DNS proxy should stay disabled until certificate issuance succeeds, then can be enabled afterward.

## Implementation Summary

Minimal, targeted changes:

- Modify `install_proxy.sh` for decoy page fallback.
- Add `README.md`.
- Add one lightweight regression check script.
