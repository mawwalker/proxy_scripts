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
mkdir -p /var/www/html
if [[ -f "$LOCAL_INDEX_HTML" ]]; then
  echo "检测到本地 index.html，正在复制到 /var/www/html/index.html ..."
  cp "$LOCAL_INDEX_HTML" /var/www/html/index.html
else
  echo "未检测到本地 index.html，正在从仓库下载默认小游戏页面..."
  if ! curl -fsSL "$REMOTE_INDEX_HTML_URL" -o /var/www/html/index.html; then
    echo "下载默认 index.html 失败，请检查网络或仓库地址：$REMOTE_INDEX_HTML_URL"
    exit 1
  fi
fi

# 5. 申请 SSL 证书
echo -e "\n停止 Nginx 以申请证书..."
systemctl stop nginx
certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos --register-unsafely-without-email

# 6. 配置 Nginx 反向代理分流
echo -e "\n配置 Nginx..."
cat <<EOF >/etc/nginx/conf.d/vless.conf
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    # 根目录伪装网站
    location / {
        root /var/www/html;
        index index.html;
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

# 7. 重启服务
echo -e "\n重启服务中..."
systemctl enable xray nginx
systemctl restart xray nginx

# 8. 输出客户端配置信息
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
echo -e "================================================="
echo -e "现在你可以在浏览器中访问 https://$DOMAIN ，你会看到一个小游戏伪装页。"
echo -e "确认网页可以正常打开、代理可以正常连接后，即可去 Cloudflare 开启小黄云 CDN。"
echo -e "================================================="
