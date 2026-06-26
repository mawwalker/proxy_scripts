#!/bin/bash

set -euo pipefail

METADATA_DIR="/etc/proxy_scripts"
MANAGER_BIN="/usr/local/bin/proxy-manager"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "请使用 root 运行此脚本。"
  exit 1
fi

if [[ ! -x "$MANAGER_BIN" ]]; then
  echo "未找到 $MANAGER_BIN ，无法执行新的卸载流程。"
  exit 1
fi

if [[ $# -ge 1 ]]; then
  DOMAIN_INPUT="$1"
else
  if compgen -G "$METADATA_DIR/*.env" >/dev/null 2>&1; then
    echo "检测到以下已记录主域名："
    for file in "$METADATA_DIR"/*.env; do
      basename "$file" .env
    done
  fi

  read -r -p "请输入要卸载的主域名或 Hysteria2 域名: " DOMAIN_INPUT
fi

if [[ -z "$DOMAIN_INPUT" ]]; then
  echo "域名不能为空。"
  exit 1
fi

read -r -p "确认继续？[y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "已取消卸载。"
  exit 0
fi

proxy-manager del "$DOMAIN_INPUT"

echo -e "\n卸载完成。"
