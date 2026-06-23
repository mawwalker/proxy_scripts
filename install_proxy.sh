#!/bin/bash
# Nginx + VLESS + WS + TLS 自动化部署脚本配小游戏伪装页

# 1. 收集信息
read -p "请输入你的域名 (例如: demo.yourdomain.com): " DOMAIN
read -p "请输入你想设置的 WebSocket 路径 (需以 / 开头，例如: /secret-ws): " WSPATH
UUID=$(cat /proc/sys/kernel/random/uuid)
PORT=10000
REPO_RAW_BASE="https://raw.githubusercontent.com/mawwalker/proxy_scripts/main"
REMOTE_INDEX_HTML_URL="$REPO_RAW_BASE/index.html"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LOCAL_INDEX_HTML="$SCRIPT_DIR/index.html"
WEB_ROOT="/var/www/$DOMAIN"
NGINX_CONF="/etc/nginx/conf.d/${DOMAIN}.conf"
ACME_CHALLENGE_DIR="$WEB_ROOT/.well-known/acme-challenge"
LEGACY_NGINX_CONF="/etc/nginx/conf.d/vless.conf"

reload_or_restart_nginx() {
  if systemctl is-active --quiet nginx; then
    systemctl reload nginx
  else
    systemctl restart nginx
  fi
}

echo -e "\n开始安装所需组件..."
apt update -y && apt install -y nginx curl unzip certbot

# 2. 安装 Xray-core
echo -e "\n安装 Xray-Core..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 3. 写入 Xray 配置文件 (VLESS-WS)
echo -e "\n配置 Xray..."
cat <<EOF >/usr/local/etc/xray/config.json
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

# 4. 生成小游戏伪装页
echo -e "\n部署小游戏伪装页..."
mkdir -p "$ACME_CHALLENGE_DIR"
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

# 5. 迁移旧版固定文件名配置，避免重复 server_name
if [[ -f "$LEGACY_NGINX_CONF" ]] && grep -Fq "server_name $DOMAIN;" "$LEGACY_NGINX_CONF" && grep -Fq "proxy_pass http://127.0.0.1:$PORT;" "$LEGACY_NGINX_CONF"; then
  LEGACY_BACKUP_PATH="${LEGACY_NGINX_CONF}.bak.$(date +%s)"
  echo -e "\n检测到旧版配置 $LEGACY_NGINX_CONF ，正在备份到 $LEGACY_BACKUP_PATH ..."
  mv "$LEGACY_NGINX_CONF" "$LEGACY_BACKUP_PATH"
fi

# 6. 写入 Nginx 引导配置，用于 webroot 方式申请证书
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

echo -e "\n校验 Nginx 配置..."
if ! nginx -t; then
  echo "Nginx 配置校验失败，安装终止。"
  exit 1
fi

echo -e "\n启动或重载 Nginx..."
systemctl enable nginx
reload_or_restart_nginx

# 7. 申请 SSL 证书
echo -e "\n申请 SSL 证书..."
certbot certonly --webroot -w "$WEB_ROOT" -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email

# 8. 写入 Nginx 最终配置
echo -e "\n写入 Nginx 最终配置..."
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

server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    root $WEB_ROOT;
    index index.html;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    # 根目录伪装网站
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # Xray WebSocket 分流
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

# 9. 校验并重载服务
echo -e "\n校验 Nginx 最终配置..."
if ! nginx -t; then
  echo "Nginx 最终配置校验失败，安装终止。"
  exit 1
fi

echo -e "\n重载服务中..."
systemctl enable xray nginx
systemctl restart xray
reload_or_restart_nginx

# 10. 输出客户端配置信息
clear
echo -e "================================================="
echo -e "部署成功！以下是你的客户端连接信息："
echo -e "================================================="
echo -e "协议 (Protocol): VLESS"
echo -e "地址 (Address): $DOMAIN"
echo -e "端口 (Port): 443"
echo -e "用户 ID (UUID): $UUID"
echo -e "传输协议 (Network): ws"
echo -e "伪装域名 (Host): $DOMAIN"
echo -e "路径 (Path): $WSPATH"
echo -e "底层传输安全 (TLS): tls"
echo -e "Nginx 配置文件: $NGINX_CONF"
echo -e "伪装站目录: $WEB_ROOT"
echo -e "================================================="
echo -e "现在你可以在浏览器中访问 https://$DOMAIN ，你会看到一个小游戏伪装页。"
echo -e "后续如需新增其他网站，直接在 /etc/nginx/conf.d/ 新增其他域名的 conf 文件即可。"
echo -e "确认网页可以正常打开、代理可以正常连接后，即可去 Cloudflare 开启小黄云 CDN。"
echo -e "================================================="
