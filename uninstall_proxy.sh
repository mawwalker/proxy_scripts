#!/bin/bash

set -euo pipefail

METADATA_DIR="/etc/proxy_scripts"

reload_or_restart_nginx() {
  if systemctl is-active --quiet nginx; then
    systemctl reload nginx
  else
    systemctl restart nginx
  fi
}

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "请使用 root 运行此脚本。"
  exit 1
fi

if [[ $# -ge 1 ]]; then
  DOMAIN="$1"
else
  if compgen -G "$METADATA_DIR/*.env" >/dev/null 2>&1; then
    echo "检测到以下已记录域名："
    for file in "$METADATA_DIR"/*.env; do
      basename "$file" .env
    done
  fi

  read -r -p "请输入要卸载的域名: " DOMAIN
fi

if [[ -z "$DOMAIN" ]]; then
  echo "域名不能为空。"
  exit 1
fi

METADATA_FILE="$METADATA_DIR/${DOMAIN}.env"
NGINX_CONF="/etc/nginx/conf.d/${DOMAIN}.conf"
WEB_ROOT="/var/www/$DOMAIN"
XRAY_CONFIG="/usr/local/etc/xray/config.json"

if [[ -f "$METADATA_FILE" ]]; then
  # The installer writes this file; sourcing it restores the exact managed paths.
  # shellcheck disable=SC1090
  . "$METADATA_FILE"
fi

echo "将卸载当前域名的代理站点资源："
echo "- 域名: $DOMAIN"
echo "- Nginx 配置: $NGINX_CONF"
echo "- 站点目录: $WEB_ROOT"
echo "- Xray 配置: $XRAY_CONFIG"
echo "- 证书: /etc/letsencrypt/live/$DOMAIN"
echo
read -r -p "确认继续？[y/N]: " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "已取消卸载。"
  exit 0
fi

echo -e "\n停止 Xray 服务..."
systemctl stop xray 2>/dev/null || true
systemctl disable xray 2>/dev/null || true

echo -e "\n删除 Xray 配置..."
rm -f "$XRAY_CONFIG"

echo -e "\n删除当前域名的 Nginx 配置和站点目录..."
rm -f "$NGINX_CONF"
rm -rf "$WEB_ROOT"

echo -e "\n删除当前域名的证书..."
if [[ -f "/etc/letsencrypt/renewal/$DOMAIN.conf" ]] || [[ -d "/etc/letsencrypt/live/$DOMAIN" ]]; then
  certbot delete --cert-name "$DOMAIN" --non-interactive || true
fi
rm -rf "/etc/letsencrypt/live/$DOMAIN"
rm -rf "/etc/letsencrypt/archive/$DOMAIN"
rm -f "/etc/letsencrypt/renewal/$DOMAIN.conf"

echo -e "\n删除部署元数据..."
rm -f "$METADATA_FILE"
rmdir "$METADATA_DIR" 2>/dev/null || true

echo -e "\n校验 Nginx 配置..."
if ! nginx -t; then
  echo "Nginx 配置校验失败，请手动检查现有站点配置。"
  exit 1
fi

echo -e "\n重载 Nginx..."
reload_or_restart_nginx

echo -e "\n卸载完成。"
echo "已清理当前域名相关的代理站点资源，未卸载 nginx、certbot 或 xray 二进制本体。"
