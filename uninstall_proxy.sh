#!/bin/bash

set -euo pipefail

METADATA_DIR="/etc/proxy_scripts"

resolve_metadata_file() {
  local input_domain="$1"
  local candidate="$METADATA_DIR/${input_domain}.env"
  local file
  local file_domain
  local file_hy2_domain

  if [[ -f "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  if ! compgen -G "$METADATA_DIR/*.env" >/dev/null 2>&1; then
    return 0
  fi

  for file in "$METADATA_DIR"/*.env; do
    file_domain="$(grep -E '^DOMAIN=' "$file" | head -n 1 | cut -d= -f2- | tr -d "'" | tr -d '"')"
    file_hy2_domain="$(grep -E '^HY2_DOMAIN=' "$file" | head -n 1 | cut -d= -f2- | tr -d "'" | tr -d '"')"
    if [[ "$file_domain" == "$input_domain" || "$file_hy2_domain" == "$input_domain" ]]; then
      printf '%s\n' "$file"
      return 0
    fi
  done

  return 0
}

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

METADATA_FILE="$(resolve_metadata_file "$DOMAIN_INPUT")"
DOMAIN="$DOMAIN_INPUT"
NGINX_CONF="/etc/nginx/conf.d/${DOMAIN}.conf"
WEB_ROOT="/var/www/$DOMAIN"
REALITY_CONFIG="/etc/sing-box/config.json"
HY2_DOMAIN="${HY2_DOMAIN:-}"
HY2_NGINX_CONF="/etc/nginx/conf.d/${HY2_DOMAIN}.conf"
HY2_WEB_ROOT="/var/www/$HY2_DOMAIN"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
HYSTERIA_CONFIG="/etc/hysteria/config.yaml"

if [[ -f "$METADATA_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$METADATA_FILE"
else
  echo "未找到 $DOMAIN_INPUT 对应的部署元数据，无法安全卸载。"
  exit 1
fi

echo "将卸载当前域名的代理站点资源："
echo "- CDN 域名: $DOMAIN"
echo "- Nginx 配置: $NGINX_CONF"
echo "- 站点目录: $WEB_ROOT"
echo "- Reality 配置: $REALITY_CONFIG"
echo "- Hysteria2 域名: ${HY2_DOMAIN:-未记录}"
echo "- Hysteria2 Challenge 配置: ${HY2_NGINX_CONF:-未记录}"
echo "- Hysteria2 Challenge 目录: ${HY2_WEB_ROOT:-未记录}"
echo "- Xray 配置: $XRAY_CONFIG"
echo "- Hysteria2 配置: $HYSTERIA_CONFIG"
echo "- 证书: /etc/letsencrypt/live/$DOMAIN"
if [[ -n "${HY2_DOMAIN:-}" ]]; then
  echo "- Hysteria2 证书: /etc/letsencrypt/live/$HY2_DOMAIN"
fi
echo
read -r -p "确认继续？[y/N]: " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "已取消卸载。"
  exit 0
fi

echo -e "\n停止服务..."
systemctl stop xray 2>/dev/null || true
systemctl disable xray 2>/dev/null || true
systemctl stop sing-box 2>/dev/null || true
systemctl disable sing-box 2>/dev/null || true
systemctl stop hysteria-server.service 2>/dev/null || true
systemctl disable hysteria-server.service 2>/dev/null || true

echo -e "\n删除 Xray / Reality / Hysteria2 配置..."
rm -f "$XRAY_CONFIG"
rm -f "$REALITY_CONFIG"
rm -f "$HYSTERIA_CONFIG"

echo -e "\n删除当前域名的 Nginx 配置和站点目录..."
rm -f "$NGINX_CONF"
rm -rf "$WEB_ROOT"
rm -f "$HY2_NGINX_CONF"
rm -rf "$HY2_WEB_ROOT"

echo -e "\n删除当前域名的证书..."
if [[ -f "/etc/letsencrypt/renewal/$DOMAIN.conf" ]] || [[ -d "/etc/letsencrypt/live/$DOMAIN" ]]; then
  certbot delete --cert-name "$DOMAIN" --non-interactive || true
fi
rm -rf "/etc/letsencrypt/live/$DOMAIN"
rm -rf "/etc/letsencrypt/archive/$DOMAIN"
rm -f "/etc/letsencrypt/renewal/$DOMAIN.conf"

if [[ -n "${HY2_DOMAIN:-}" ]]; then
  echo -e "\n删除 Hysteria2 域名证书..."
  if [[ -f "/etc/letsencrypt/renewal/$HY2_DOMAIN.conf" ]] || [[ -d "/etc/letsencrypt/live/$HY2_DOMAIN" ]]; then
    certbot delete --cert-name "$HY2_DOMAIN" --non-interactive || true
  fi
  rm -rf "/etc/letsencrypt/live/$HY2_DOMAIN"
  rm -rf "/etc/letsencrypt/archive/$HY2_DOMAIN"
  rm -f "/etc/letsencrypt/renewal/$HY2_DOMAIN.conf"
fi

echo -e "\n删除部署元数据..."
rm -f "$METADATA_FILE"
rmdir "$METADATA_DIR" 2>/dev/null || true
rmdir "/etc/sing-box" 2>/dev/null || true

echo -e "\n校验 Nginx 配置..."
if ! nginx -t; then
  echo "Nginx 配置校验失败，请手动检查现有站点配置。"
  exit 1
fi

echo -e "\n重载 Nginx..."
reload_or_restart_nginx

echo -e "\n卸载完成。"
echo "已清理当前域名相关的 CDN VLESS / Reality / Hysteria2 资源，未卸载 nginx、certbot、xray、sing-box 或 hysteria 二进制本体。"
