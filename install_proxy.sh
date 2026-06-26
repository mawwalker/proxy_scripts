#!/bin/bash
# Bootstrap installer for proxy manager + default triple-line profile

set -euo pipefail

REPO_RAW_BASE="https://raw.githubusercontent.com/mawwalker/proxy_scripts/main"
REMOTE_INDEX_HTML_URL="$REPO_RAW_BASE/index.html"
REMOTE_MANAGER_SCRIPT_URL="$REPO_RAW_BASE/proxy_manager.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LOCAL_INDEX_HTML="$SCRIPT_DIR/index.html"
LOCAL_MANAGER_SCRIPT="$SCRIPT_DIR/proxy_manager.sh"
SHARE_DIR="/usr/local/share/proxy-scripts"
MANAGER_BIN="/usr/local/bin/proxy-manager"
METADATA_DIR="/etc/proxy_scripts"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "请使用 root 运行此脚本。"
  exit 1
fi

install_sing_box() {
  echo -e "\n安装 sing-box..."
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
  chmod a+r /etc/apt/keyrings/sagernet.asc
  cat <<'EOF' >/etc/apt/sources.list.d/sagernet.sources
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
  apt-get update -y
  apt-get install -y sing-box
}

install_proxy_manager() {
  echo -e "\n安装 proxy manager..."
  mkdir -p "$SHARE_DIR"

  if [[ -f "$LOCAL_MANAGER_SCRIPT" ]]; then
    cp "$LOCAL_MANAGER_SCRIPT" "$MANAGER_BIN"
  else
    curl -fsSL "$REMOTE_MANAGER_SCRIPT_URL" -o "$MANAGER_BIN"
  fi
  chmod +x "$MANAGER_BIN"

  if [[ -f "$LOCAL_INDEX_HTML" ]]; then
    cp "$LOCAL_INDEX_HTML" "$SHARE_DIR/index.html"
  else
    curl -fsSL "$REMOTE_INDEX_HTML_URL" -o "$SHARE_DIR/index.html"
  fi
}

echo -e "\n开始安装所需组件..."
apt-get update -y
apt-get install -y nginx curl unzip certbot openssl

echo -e "\n安装 Xray-Core..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

install_sing_box

echo -e "\n安装 Hysteria2..."
HYSTERIA_USER=root bash <(curl -fsSL https://get.hy2.sh/)

install_proxy_manager

mkdir -p "$METADATA_DIR"

echo -e "\n初始化默认三线路配置..."
proxy-manager init default
