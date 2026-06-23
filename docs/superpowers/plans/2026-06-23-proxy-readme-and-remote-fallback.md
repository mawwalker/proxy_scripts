# Proxy README And Remote Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a public README and make the installer support true one-command execution by downloading the bundled decoy page when it is not available locally.

**Architecture:** Keep the repository shape unchanged. Extend `install_proxy.sh` with a minimal local-first, remote-fallback decoy page deployment path, then document the supported execution modes in `README.md`.

**Tech Stack:** Bash, GitHub raw file hosting, Markdown

---

### Task 1: Capture the required installer behavior in a lightweight regression check

**Files:**
- Create: `tests/check_install_proxy.sh`
- Modify: none
- Test: `tests/check_install_proxy.sh`

- [ ] **Step 1: Write the failing regression check**

```bash
#!/usr/bin/env bash
set -euo pipefail

script_path="${1:-install_proxy.sh}"
required_patterns=(
  'SCRIPT_DIR='
  'LOCAL_INDEX_HTML='
  'REMOTE_INDEX_HTML_URL='
  'if [[ -f "$LOCAL_INDEX_HTML" ]]; then'
  'curl -fsSL "$REMOTE_INDEX_HTML_URL" -o /var/www/html/index.html'
)
```

- [ ] **Step 2: Run the check to verify it fails before the installer is updated**

Run: `bash tests/check_install_proxy.sh`  
Expected: FAIL with one or more missing fallback patterns.

### Task 2: Add local-or-remote decoy page deployment to the installer

**Files:**
- Modify: `install_proxy.sh`
- Test: `tests/check_install_proxy.sh`

- [ ] **Step 1: Add raw repository constants and local script directory detection**

```bash
REPO_RAW_BASE="https://raw.githubusercontent.com/mawwalker/proxy_scripts/main"
REMOTE_INDEX_HTML_URL="$REPO_RAW_BASE/index.html"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_INDEX_HTML="$SCRIPT_DIR/index.html"
```

- [ ] **Step 2: Replace the direct `cp index.html` step with local-first, remote-fallback logic**

```bash
mkdir -p /var/www/html
if [[ -f "$LOCAL_INDEX_HTML" ]]; then
  cp "$LOCAL_INDEX_HTML" /var/www/html/index.html
else
  curl -fsSL "$REMOTE_INDEX_HTML_URL" -o /var/www/html/index.html
fi
```

- [ ] **Step 3: Re-run the regression check**

Run: `bash tests/check_install_proxy.sh`  
Expected: PASS with the fallback logic detected.

### Task 3: Add the public README

**Files:**
- Create: `README.md`
- Modify: none
- Test: manual review against the spec

- [ ] **Step 1: Write the README with both one-command install variants**

```markdown
## 一键安装（推荐）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mawwalker/proxy_scripts/main/install_proxy.sh)
```
```

- [ ] **Step 2: Document prerequisites, prompted inputs, outputs, and Cloudflare note**

```markdown
- 域名已解析到 VPS
- 80/443 端口已放行
- 申请证书前关闭 Cloudflare 代理
```

### Task 4: Verify syntax and docs consistency

**Files:**
- Modify: none
- Test: `install_proxy.sh`, `README.md`, `tests/check_install_proxy.sh`

- [ ] **Step 1: Run shell syntax validation**

Run: `bash -n install_proxy.sh`  
Expected: no output, exit code `0`

- [ ] **Step 2: Run the regression check**

Run: `bash tests/check_install_proxy.sh`  
Expected: PASS with a success message

- [ ] **Step 3: Review README against the final installer behavior**

Check that the README claims:

- both one-command variants
- recommended command
- interactive prompts
- decoy page behavior
- Cloudflare enable-after-success note
