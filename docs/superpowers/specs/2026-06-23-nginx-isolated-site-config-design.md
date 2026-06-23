# Nginx Isolated Site Config Design

## Context

The installer currently deploys a proxy domain with these characteristics:

- writes a fixed Nginx config to `/etc/nginx/conf.d/vless.conf`
- uses a shared web root at `/var/www/html`
- stops Nginx and uses `certbot --standalone` for certificate issuance

That works for a single-purpose VPS, but it is a poor default when the same server may later host additional sites or services. The user wants the proxy domain and its decoy site isolated so new Nginx-managed sites can be added without interfering with this one.

## Goals

- Keep using `conf.d`, not `sites-available`.
- Generate one Nginx config file per domain, for example `/etc/nginx/conf.d/example.com.conf`.
- Give each deployed domain its own web root, for example `/var/www/example.com`.
- Replace `certbot --standalone` with `certbot --webroot` so certificate issuance no longer requires stopping Nginx.
- Validate Nginx configuration with `nginx -t` before reloading.
- Preserve the existing proxy behavior:
  - `/` serves the decoy page
  - the configured WebSocket path proxies to local Xray on `127.0.0.1:10000`

## Non-Goals

- Supporting multiple proxy domains in one run.
- Changing the Xray topology or transport type.
- Redesigning the decoy page.

## Proposed Architecture

### 1. Domain-scoped file paths

Introduce domain-scoped paths in the installer:

- `WEB_ROOT=/var/www/$DOMAIN`
- `NGINX_CONF=/etc/nginx/conf.d/$DOMAIN.conf`
- `ACME_CHALLENGE_DIR=$WEB_ROOT/.well-known/acme-challenge`

This isolates the proxy domain from any future sites on the same server.

### 2. Two-phase Nginx configuration

Certificate issuance must happen before the final HTTPS server block can reference the generated certificate files. To avoid downtime for unrelated sites while still supporting fresh installation, use two Nginx config phases:

1. **Bootstrap HTTP-only config**
   - listens on port `80`
   - serves the web root
   - exposes `/.well-known/acme-challenge/`
   - allows `certbot --webroot` to succeed

2. **Final config**
   - keeps port `80` only for ACME challenge handling and HTTP-to-HTTPS redirects
   - adds the `443 ssl http2` server block
   - serves the decoy page from the domain-specific web root
   - proxies the WebSocket path to Xray

### 3. Nginx reload safety

Every time the installer writes a config, run `nginx -t` first. Only reload or restart Nginx if the test passes. This prevents one bad generated config from breaking unrelated sites on the same host.

### 4. Legacy config migration

Older versions of the script created `/etc/nginx/conf.d/vless.conf`. To reduce duplicate `server_name` conflicts on reruns, the installer should detect that legacy file when it clearly matches the current domain and Xray upstream, then move it to a timestamped backup before writing the new domain-scoped config.

## README Changes

Update the README so it accurately documents:

- generated config path format: `/etc/nginx/conf.d/<domain>.conf`
- generated web root format: `/var/www/<domain>`
- new certificate issuance mode: `certbot --webroot`
- the fact that future sites can be added as additional `conf.d/*.conf` files as long as `server_name` values do not conflict

## Verification

Use lightweight local verification:

- `bash -n install_proxy.sh`
- extend the local regression check to assert:
  - domain-specific `NGINX_CONF`
  - domain-specific `WEB_ROOT`
  - `certbot --webroot`
  - `nginx -t`
  - challenge location handling in the generated config

## Risks And Mitigations

- **Risk:** rerunning on a host with an older `vless.conf` causes duplicate Nginx server definitions.
  - **Mitigation:** detect and back up the matching legacy file before writing the new config.
- **Risk:** certificate issuance fails because Nginx is not serving the ACME challenge path.
  - **Mitigation:** write and test the bootstrap HTTP config before running Certbot.
- **Risk:** a generated config error impacts other hosted sites.
  - **Mitigation:** gate reloads behind `nginx -t`.
