---
name: provision-3x-ui-server
description: One-click provisioning or reuse of a Linux server's 3X-UI installation over password-authenticated SSH. Use when the user supplies a server address, SSH port, username, and password and asks to install or deliver 3X-UI with tested VLESS TCP and SOCKS5 access, panel credentials, an API token, and a VLESS QR code.
---

# Provision 3X-UI Server

Provision a server end to end with `scripts/provision_3x_ui.sh`. Preserve every existing 3X-UI resource and install 3X-UI only when it is absent.

## Required Input

- Require the server address, SSH port, SSH username, and SSH password.
- Default the SSH username to `root` and the SSH port to `22` only when the user omits them.
- Never place the SSH password in a command argument, source file, log, or chat update.
- Treat a request to perform the setup as authorization to modify that server. Use `--dry-run` when the user asks to inspect or plan only.

## Run

Run the script interactively so it can prompt for the password without echo:

```bash
scripts/provision_3x_ui.sh --host SERVER --ssh-port PORT --ssh-user root
```

For noninteractive execution, export `PROVISION_SSH_PASSWORD` only for the process environment. Do not echo it:

```bash
PROVISION_SSH_PASSWORD='...' scripts/provision_3x_ui.sh --host SERVER --ssh-port PORT
```

Use `--panel-port`, `--vless-port`, or `--socks-port` only when the user requests specific ports. Use `--output-dir` for a user-selected delivery directory. Read `references/api.md` only when troubleshooting an API-version mismatch.

## Completion Rules

- Reuse existing 3X-UI installations. Never reinstall, reset credentials, overwrite the SQLite database, delete clients, edit existing inbounds, or replace certificates.
- Accept installation completion only when the service is active and enabled and the panel responds.
- Create a unique VLESS TCP inbound and attach a unique generated client.
- Create a separate authenticated `mixed` inbound for SOCKS5 compatibility.
- Require real requests through both proxies to return the server's public IP. API success alone is not completion.
- Generate the PNG QR code only from the canonical VLESS URL returned by 3X-UI.
- Report `panelTls: false` when strict certificate validation fails. Do not describe such a panel as securely verified.
- On failure, report the returned `status`, `stage`, and `message`. Do not claim partial resources are working.

## Deliver

Read the script's JSON output and give the user:

- Panel URL, username, password, and API token
- VLESS server, port, UUID, canonical import URL, and rendered QR PNG
- SOCKS5 server, port, username, and password
- Service, panel HTTP/TLS, VLESS, and SOCKS5 verification results
- The absolute paths to `result.json` and the QR PNG

Always warn that plain VLESS TCP and SOCKS5 do not encrypt transport traffic. Render the QR in the final response with its absolute local path.
