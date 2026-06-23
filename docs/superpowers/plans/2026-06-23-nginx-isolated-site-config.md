# Nginx Isolated Site Config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Isolate the proxy domain into its own Nginx conf file and web root so additional sites can later coexist on the same server without interfering with it.

**Architecture:** The installer will write a bootstrap HTTP-only Nginx config for ACME webroot validation, obtain the certificate with `certbot --webroot`, then replace that config with the final HTTPS + WebSocket split config. Both configs are domain-scoped and validated with `nginx -t` before reload.

**Tech Stack:** Bash, Nginx, Certbot, Markdown

---

### Task 1: Extend the local regression check for isolated Nginx behavior

**Files:**
- Modify: `tests/check_install_proxy.sh`
- Test: `tests/check_install_proxy.sh`

- [ ] **Step 1: Update the check to require the new installer patterns**

```bash
required_patterns=(
  'WEB_ROOT="/var/www/$DOMAIN"'
  'NGINX_CONF="/etc/nginx/conf.d/${DOMAIN}.conf"'
  'certbot certonly --webroot -w "$WEB_ROOT" -d "$DOMAIN"'
  'nginx -t'
  'location ^~ /.well-known/acme-challenge/'
)
```

- [ ] **Step 2: Run the check to verify it fails on the current installer**

Run: `bash tests/check_install_proxy.sh`  
Expected: FAIL with one or more missing isolated-config patterns.

### Task 2: Update installer paths and decoy deployment

**Files:**
- Modify: `install_proxy.sh`
- Test: `tests/check_install_proxy.sh`

- [ ] **Step 1: Add domain-scoped paths**

```bash
WEB_ROOT="/var/www/$DOMAIN"
NGINX_CONF="/etc/nginx/conf.d/${DOMAIN}.conf"
ACME_CHALLENGE_DIR="$WEB_ROOT/.well-known/acme-challenge"
```

- [ ] **Step 2: Deploy `index.html` into the domain-scoped web root**

```bash
mkdir -p "$ACME_CHALLENGE_DIR"
cp "$LOCAL_INDEX_HTML" "$WEB_ROOT/index.html"
```

### Task 3: Replace standalone cert issuance with bootstrap + final Nginx configs

**Files:**
- Modify: `install_proxy.sh`
- Test: `tests/check_install_proxy.sh`

- [ ] **Step 1: Write a bootstrap HTTP config and validate it**

```bash
cat <<EOF >"$NGINX_CONF"
server {
    listen 80;
    server_name $DOMAIN;
    root $WEB_ROOT;
    index index.html;

    location ^~ /.well-known/acme-challenge/ {
        root $WEB_ROOT;
    }
}
EOF
nginx -t
```

- [ ] **Step 2: Obtain the certificate with the webroot plugin**

```bash
certbot certonly --webroot -w "$WEB_ROOT" -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
```

- [ ] **Step 3: Write the final domain-scoped config and validate it**

```bash
cat <<EOF >"$NGINX_CONF"
server {
    listen 80;
    server_name $DOMAIN;

    location ^~ /.well-known/acme-challenge/ {
        root $WEB_ROOT;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
nginx -t
```

### Task 4: Update README to describe isolated site behavior

**Files:**
- Modify: `README.md`
- Test: manual review against installer behavior

- [ ] **Step 1: Document domain-specific config and web root**

```markdown
- Nginx 配置文件会生成在 `/etc/nginx/conf.d/<你的域名>.conf`
- 站点目录会生成在 `/var/www/<你的域名>`
```

- [ ] **Step 2: Document that additional sites can be added as separate `conf.d` files**

```markdown
- 后续如果你还要部署别的网站，直接新增其他 `conf.d/*.conf` 文件即可，只要 `server_name` 不冲突就不会影响这个代理域名。
```

### Task 5: Verify the final behavior

**Files:**
- Modify: none
- Test: `install_proxy.sh`, `tests/check_install_proxy.sh`

- [ ] **Step 1: Run shell syntax validation**

Run: `bash -n install_proxy.sh`  
Expected: no output, exit code `0`

- [ ] **Step 2: Run the local regression check**

Run: `bash tests/check_install_proxy.sh`  
Expected: PASS with all isolated-config patterns found

- [ ] **Step 3: Review README claims against installer behavior**

Check that README matches:

- `conf.d/<domain>.conf`
- `/var/www/<domain>`
- `certbot --webroot`
- coexistence with future sites
