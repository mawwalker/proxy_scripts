#!/bin/bash
# Nginx + Xray CDN + sing-box Reality + Hysteria2 自动化部署脚本

set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "请使用 root 运行此脚本。"
  exit 1
fi

read -p "请输入你的 CDN 域名 (例如: cdn.yourdomain.com): " DOMAIN
read -p "请输入你想设置的 WebSocket 路径 (需以 / 开头，例如: /secret-ws): " WSPATH
read -p "请输入 Hysteria2 使用的直连域名 (例如: hy2.yourdomain.com): " HY2_DOMAIN

UUID="$(cat /proc/sys/kernel/random/uuid)"
PORT=10000
CDN_PORT=8443
REALITY_PORT=443
HY2_PORT=443
SERVER_IP=""
REALITY_SERVER_NAME="s3.amazonaws.com"
REALITY_FINGERPRINT="chrome"
REALITY_SHORT_ID=""
REPO_RAW_BASE="https://raw.githubusercontent.com/mawwalker/proxy_scripts/main"
REMOTE_INDEX_HTML_URL="$REPO_RAW_BASE/index.html"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LOCAL_INDEX_HTML="$SCRIPT_DIR/index.html"
WEB_ROOT="/var/www/$DOMAIN"
NGINX_CONF="/etc/nginx/conf.d/${DOMAIN}.conf"
ACME_CHALLENGE_DIR="$WEB_ROOT/.well-known/acme-challenge"
HY2_WEB_ROOT="/var/www/$HY2_DOMAIN"
HY2_NGINX_CONF="/etc/nginx/conf.d/${HY2_DOMAIN}.conf"
HY2_ACME_CHALLENGE_DIR="$HY2_WEB_ROOT/.well-known/acme-challenge"
LEGACY_NGINX_CONF="/etc/nginx/conf.d/vless.conf"
METADATA_DIR="/etc/proxy_scripts"
METADATA_FILE="$METADATA_DIR/${DOMAIN}.env"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
REALITY_CONFIG_DIR="/etc/sing-box"
REALITY_CONFIG="$REALITY_CONFIG_DIR/config.json"
HYSTERIA_CONFIG="/etc/hysteria/config.yaml"
HYSTERIA_AUTH="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)"
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""

select_reality_target() {
  local choice

  echo
  echo "请选择 Reality 借用目标："
  echo "1. s3.amazonaws.com (默认)"
  echo "2. www.microsoft.com"
  echo "3. learn.microsoft.com"
  echo "4. 自定义"
  read -r -p "请输入选项 [1-4，默认 1]: " choice

  case "${choice:-1}" in
    1)
      REALITY_SERVER_NAME="s3.amazonaws.com"
      ;;
    2)
      REALITY_SERVER_NAME="www.microsoft.com"
      ;;
    3)
      REALITY_SERVER_NAME="learn.microsoft.com"
      ;;
    4)
      read -r -p "请输入自定义 Reality 借用域名: " REALITY_SERVER_NAME
      ;;
    *)
      echo "无效选项，使用默认值 s3.amazonaws.com"
      REALITY_SERVER_NAME="s3.amazonaws.com"
      ;;
  esac

  if [[ -z "$REALITY_SERVER_NAME" ]]; then
    echo "Reality 借用域名不能为空。"
    exit 1
  fi
}

detect_public_ipv4() {
  local candidate
  local endpoint
  local endpoints=(
    "https://api.ipify.org"
    "https://ipv4.icanhazip.com"
    "https://ifconfig.me/ip"
  )

  for endpoint in "${endpoints[@]}"; do
    candidate="$(curl -4fsSL --max-time 8 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$candidate" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

reload_or_restart_nginx() {
  if systemctl is-active --quiet nginx; then
    systemctl reload nginx
  else
    systemctl restart nginx
  fi
}

write_metadata_field() {
  local key="$1"
  local value="$2"
  local escaped="$value"

  escaped=${escaped//\'/\'\\\'\'}
  printf "%s='%s'\n" "$key" "$escaped"
}

write_hy2_nginx_conf() {
  cat <<EOF >"$HY2_NGINX_CONF"
server {
    listen 80;
    server_name $HY2_DOMAIN;
    root $HY2_WEB_ROOT;

    location ^~ /.well-known/acme-challenge/ {
        root $HY2_WEB_ROOT;
    }

    location / {
        return 404;
    }
}
EOF
}

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

generate_reality_keys() {
  local keypair_output

  keypair_output="$(sing-box generate reality-keypair)"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "$keypair_output" | awk -F': ' '/^PrivateKey:/ {print $2}')"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "$keypair_output" | awk -F': ' '/^PublicKey:/ {print $2}')"

  if [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
    echo "生成 Reality 密钥失败。"
    exit 1
  fi
}

write_reality_config() {
  mkdir -p "$REALITY_CONFIG_DIR"
  cat <<EOF >"$REALITY_CONFIG"
{
  "log": {
    "level": "warn"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "reality-in",
      "listen_port": $REALITY_PORT,
      "users": [
        {
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$REALITY_SERVER_NAME",
            "server_port": 443
          },
          "private_key": "$REALITY_PRIVATE_KEY",
          "short_id": [
            "$REALITY_SHORT_ID"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
}

urlencode() {
  local raw="${1:-}"
  local encoded=""
  local pos
  local char

  for ((pos = 0; pos < ${#raw}; pos++)); do
    char="${raw:$pos:1}"
    case "$char" in
      [a-zA-Z0-9.~_-])
        encoded+="$char"
        ;;
      *)
        printf -v encoded '%s%%%02X' "$encoded" "'$char"
        ;;
    esac
  done

  printf '%s' "$encoded"
}

if [[ -z "$DOMAIN" || -z "$WSPATH" || -z "$HY2_DOMAIN" ]]; then
  echo "CDN 域名、WebSocket 路径、Hysteria2 域名都不能为空。"
  exit 1
fi

if [[ "$WSPATH" != /* ]]; then
  echo "WebSocket 路径必须以 / 开头。"
  exit 1
fi

if [[ "$HY2_DOMAIN" == "$DOMAIN" ]]; then
  echo "Hysteria2 直连域名不能和 CDN 域名相同。"
  exit 1
fi

select_reality_target

echo -e "\n开始安装所需组件..."
apt-get update -y
apt-get install -y nginx curl unzip certbot openssl

echo -e "\n安装 Xray-Core..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

install_sing_box
REALITY_SHORT_ID="$(openssl rand -hex 8)"
SERVER_IP="$(detect_public_ipv4 || true)"
if [[ -z "$SERVER_IP" ]]; then
  read -r -p "自动检测公网 IPv4 失败，请手动输入服务器公网 IPv4: " SERVER_IP
fi
if [[ ! "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "服务器公网 IPv4 格式不正确。"
  exit 1
fi

echo -e "\n配置 Xray..."
cat <<EOF >"$XRAY_CONFIG"
{
  "inbounds": [{
    "port": $PORT,
    "listen": "127.0.0.1",
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$UUID"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": {"path": "$WSPATH"}
    }
  }],
  "outbounds": [
    {"protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}},
    {"protocol": "blackhole", "tag": "block"}
  ]
}
EOF

echo -e "\n部署小游戏伪装页..."
mkdir -p "$ACME_CHALLENGE_DIR"
mkdir -p "$HY2_ACME_CHALLENGE_DIR"
if [[ -f "$LOCAL_INDEX_HTML" ]]; then
  echo "检测到本地 index.html，正在复制到 $WEB_ROOT/index.html ..."
  cp "$LOCAL_INDEX_HTML" "$WEB_ROOT/index.html"
else
  echo "未检测到本地 index.html，正在从仓库下载默认小游戏页面..."
  if ! curl -fsSL "$REMOTE_INDEX_HTML_URL" -o "$WEB_ROOT/index.html"; then
    echo "下载默认 index.html 失败，请检查网络或仓库地址：$REMOTE_INDEX_HTML_URL"
    exit 1
  fi
fi

if [[ -f "$LEGACY_NGINX_CONF" ]] && grep -Fq "server_name $DOMAIN;" "$LEGACY_NGINX_CONF" && grep -Fq "proxy_pass http://127.0.0.1:$PORT;" "$LEGACY_NGINX_CONF"; then
  LEGACY_BACKUP_PATH="${LEGACY_NGINX_CONF}.bak.$(date +%s)"
  echo -e "\n检测到旧版配置 $LEGACY_NGINX_CONF ，正在备份到 $LEGACY_BACKUP_PATH ..."
  mv "$LEGACY_NGINX_CONF" "$LEGACY_BACKUP_PATH"
fi

echo -e "\n写入 Nginx 引导配置..."
cat <<EOF >"$NGINX_CONF"
server {
    listen 80;
    server_name $DOMAIN;
    root $WEB_ROOT;
    index index.html;

    location ^~ /.well-known/acme-challenge/ {
        root $WEB_ROOT;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
write_hy2_nginx_conf

echo -e "\n校验 Nginx 配置..."
if ! nginx -t; then
  echo "Nginx 配置校验失败，安装终止。"
  exit 1
fi

echo -e "\n启动或重载 Nginx..."
systemctl enable nginx
reload_or_restart_nginx

echo -e "\n申请 CDN 域名 SSL 证书..."
certbot certonly --webroot -w "$WEB_ROOT" -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email

echo -e "\n申请 Hysteria2 域名 SSL 证书..."
certbot certonly --webroot -w "$HY2_WEB_ROOT" -d "$HY2_DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email

echo -e "\n写入 Nginx 最终配置..."
cat <<EOF >"$NGINX_CONF"
server {
    listen 80;
    server_name $DOMAIN;

    location ^~ /.well-known/acme-challenge/ {
        root $WEB_ROOT;
    }

    location / {
        return 301 https://\$host:8443\$request_uri;
    }
}

server {
    listen 8443 ssl http2;
    server_name $DOMAIN;
    root $WEB_ROOT;
    index index.html;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location $WSPATH {
        if (\$http_upgrade != "websocket") {
            return 404;
        }
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
write_hy2_nginx_conf

echo -e "\n生成 Reality 密钥并写入 sing-box 配置..."
generate_reality_keys
write_reality_config

echo -e "\n校验 sing-box 配置..."
if ! sing-box check -D /var/lib/sing-box -C "$REALITY_CONFIG_DIR"; then
  echo "sing-box 配置校验失败，安装终止。"
  exit 1
fi

echo -e "\n安装 Hysteria2..."
HYSTERIA_USER=root bash <(curl -fsSL https://get.hy2.sh/)

echo -e "\n写入 Hysteria2 配置..."
mkdir -p "$(dirname "$HYSTERIA_CONFIG")"
cat <<EOF >"$HYSTERIA_CONFIG"
listen: :$HY2_PORT

tls:
  cert: /etc/letsencrypt/live/$HY2_DOMAIN/fullchain.pem
  key: /etc/letsencrypt/live/$HY2_DOMAIN/privkey.pem
  sniGuard: strict

auth:
  type: password
  password: $HYSTERIA_AUTH
EOF

echo -e "\n校验 Nginx 最终配置..."
if ! nginx -t; then
  echo "Nginx 最终配置校验失败，安装终止。"
  exit 1
fi

echo -e "\n重载服务中..."
systemctl enable xray sing-box hysteria-server.service nginx
systemctl restart xray
systemctl restart sing-box
systemctl restart hysteria-server.service
reload_or_restart_nginx

ENCODED_WSPATH="$(urlencode "$WSPATH")"
ENCODED_REALITY_SNI="$(urlencode "$REALITY_SERVER_NAME")"
VLESS_LINK="vless://$UUID@$DOMAIN:$CDN_PORT?encryption=none&security=tls&type=ws&host=$DOMAIN&path=$ENCODED_WSPATH&sni=$DOMAIN#$DOMAIN-cdn"
REALITY_LINK="vless://$UUID@$SERVER_IP:$REALITY_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$ENCODED_REALITY_SNI&fp=$REALITY_FINGERPRINT&pbk=$REALITY_PUBLIC_KEY&sid=$REALITY_SHORT_ID&type=tcp&headerType=none#reality-direct"
HY2_LINK="hy2://$HYSTERIA_AUTH@$HY2_DOMAIN:$HY2_PORT/?sni=$HY2_DOMAIN#$HY2_DOMAIN-hy2"

echo -e "\n写入部署元数据..."
mkdir -p "$METADATA_DIR"
{
  write_metadata_field "DOMAIN" "$DOMAIN"
  write_metadata_field "UUID" "$UUID"
  write_metadata_field "WSPATH" "$WSPATH"
  write_metadata_field "PORT" "$PORT"
  write_metadata_field "CDN_PORT" "$CDN_PORT"
  write_metadata_field "SERVER_IP" "$SERVER_IP"
  write_metadata_field "WEB_ROOT" "$WEB_ROOT"
  write_metadata_field "NGINX_CONF" "$NGINX_CONF"
  write_metadata_field "REALITY_PORT" "$REALITY_PORT"
  write_metadata_field "REALITY_SERVER_NAME" "$REALITY_SERVER_NAME"
  write_metadata_field "REALITY_FINGERPRINT" "$REALITY_FINGERPRINT"
  write_metadata_field "REALITY_SHORT_ID" "$REALITY_SHORT_ID"
  write_metadata_field "REALITY_PRIVATE_KEY" "$REALITY_PRIVATE_KEY"
  write_metadata_field "REALITY_PUBLIC_KEY" "$REALITY_PUBLIC_KEY"
  write_metadata_field "REALITY_CONFIG_DIR" "$REALITY_CONFIG_DIR"
  write_metadata_field "REALITY_CONFIG" "$REALITY_CONFIG"
  write_metadata_field "HY2_DOMAIN" "$HY2_DOMAIN"
  write_metadata_field "HY2_PORT" "$HY2_PORT"
  write_metadata_field "HY2_WEB_ROOT" "$HY2_WEB_ROOT"
  write_metadata_field "HY2_NGINX_CONF" "$HY2_NGINX_CONF"
  write_metadata_field "XRAY_CONFIG" "$XRAY_CONFIG"
  write_metadata_field "HYSTERIA_CONFIG" "$HYSTERIA_CONFIG"
  write_metadata_field "HYSTERIA_AUTH" "$HYSTERIA_AUTH"
  write_metadata_field "VLESS_LINK" "$VLESS_LINK"
  write_metadata_field "REALITY_LINK" "$REALITY_LINK"
  write_metadata_field "HY2_LINK" "$HY2_LINK"
} >"$METADATA_FILE"

clear
echo -e "================================================="
echo -e "部署成功！以下是你的客户端连接信息："
echo -e "================================================="
echo -e "CDN 线路 (VLESS + WS + TLS)"
echo -e "地址 (Address): $DOMAIN"
echo -e "端口 (Port): $CDN_PORT"
echo -e "用户 ID (UUID): $UUID"
echo -e "传输协议 (Network): ws"
echo -e "伪装域名 (Host): $DOMAIN"
echo -e "路径 (Path): $WSPATH"
echo -e "底层传输安全 (TLS): tls"
echo -e "-------------------------------------------------"
echo -e "Reality 线路 (VLESS + Reality)"
echo -e "地址 (Address): $SERVER_IP"
echo -e "端口 (Port): $REALITY_PORT"
echo -e "用户 ID (UUID): $UUID"
echo -e "借用目标 (SNI): $REALITY_SERVER_NAME"
echo -e "Fingerprint: $REALITY_FINGERPRINT"
echo -e "Public Key: $REALITY_PUBLIC_KEY"
echo -e "Short ID: $REALITY_SHORT_ID"
echo -e "-------------------------------------------------"
echo -e "Hysteria2 线路"
echo -e "地址 (Address): $HY2_DOMAIN"
echo -e "端口 (UDP): $HY2_PORT"
echo -e "认证密码: $HYSTERIA_AUTH"
echo -e "-------------------------------------------------"
echo -e "Nginx 配置文件: $NGINX_CONF"
echo -e "Hysteria2 Challenge 配置: $HY2_NGINX_CONF"
echo -e "伪装站目录: $WEB_ROOT"
echo -e "Hysteria2 Challenge 目录: $HY2_WEB_ROOT"
echo -e "Reality 配置文件: $REALITY_CONFIG"
echo -e "部署元数据文件: $METADATA_FILE"
echo -e "================================================="
echo -e "客户端分享链接 (CDN VLESS URL):"
printf '%s\n' "$VLESS_LINK"
echo -e "客户端分享链接 (Reality VLESS URL):"
printf '%s\n' "$REALITY_LINK"
echo -e "客户端分享链接 (Hysteria2 URL):"
printf '%s\n' "$HY2_LINK"
echo -e "================================================="
echo -e "浏览器伪装页地址: https://$DOMAIN:$CDN_PORT"
echo -e "Reality 不需要单独域名，默认直接连接服务器公网 IP：$SERVER_IP"
echo -e "Reality 当前借用目标: $REALITY_SERVER_NAME"
echo -e "Hysteria2 的 $HY2_DOMAIN 必须保持 DNS only，并确保 443/udp 已放行。"
echo -e "CDN 的 $DOMAIN 可以在确认线路正常后再开启 Cloudflare 小黄云。"
echo -e "后续如需新增其他网站，直接在 /etc/nginx/conf.d/ 新增其他域名的 conf 文件即可。"
echo -e "================================================="
