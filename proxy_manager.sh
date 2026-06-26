#!/bin/bash

set -euo pipefail

REPO_RAW_BASE="https://raw.githubusercontent.com/mawwalker/proxy_scripts/main"
REMOTE_INDEX_HTML_URL="$REPO_RAW_BASE/index.html"
SHARE_DIR="/usr/local/share/proxy-scripts"
DEFAULT_INDEX_HTML="$SHARE_DIR/index.html"
METADATA_DIR="/etc/proxy_scripts"
PROFILES_DIR="$METADATA_DIR/profiles"
DEFAULT_PROFILE="default"
ACTIVE_PROFILE_FILE="$METADATA_DIR/active_profile"
LEGACY_NGINX_CONF="/etc/nginx/conf.d/vless.conf"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
REALITY_CONFIG_DIR="/etc/sing-box"
REALITY_CONFIG="$REALITY_CONFIG_DIR/config.json"
HYSTERIA_CONFIG="/etc/hysteria/config.yaml"

die() {
  echo "$*" >&2
  exit 1
}

ensure_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "请使用 root 运行此脚本。"
  fi
}

reload_or_restart_nginx() {
  if systemctl is-active --quiet nginx; then
    systemctl reload nginx
  else
    systemctl restart nginx
  fi
}

write_env_field() {
  local key="$1"
  local value="$2"
  local escaped="$value"

  escaped=${escaped//\'/\'\\\'\'}
  printf "%s='%s'\n" "$key" "$escaped"
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

random_password() {
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true
}

random_path() {
  local path_uuid

  path_uuid="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
  [[ -n "$path_uuid" ]] || die "生成 WebSocket 路径失败。"
  printf '/%s\n' "$path_uuid"
}

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

  [[ -n "$REALITY_SERVER_NAME" ]] || die "Reality 借用域名不能为空。"
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

generate_reality_keys() {
  local keypair_output

  keypair_output="$(sing-box generate reality-keypair)"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "$keypair_output" | awk -F': ' '/^PrivateKey:/ {print $2}')"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "$keypair_output" | awk -F': ' '/^PublicKey:/ {print $2}')"
  [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] || die "生成 Reality 密钥失败。"
}

profile_dir() {
  printf '%s/%s\n' "$PROFILES_DIR" "$1"
}

count_profiles() {
  local count=0
  local _

  if ! compgen -G "$PROFILES_DIR/*/profile.env" >/dev/null 2>&1; then
    printf '0\n'
    return 0
  fi

  for _ in "$PROFILES_DIR"/*/profile.env; do
    ((count += 1))
  done

  printf '%s\n' "$count"
}

current_profile_name() {
  local active_profile=""
  local profile_path

  if [[ -f "$ACTIVE_PROFILE_FILE" ]]; then
    active_profile="$(tr -d '[:space:]' < "$ACTIVE_PROFILE_FILE")"
    if [[ -n "$active_profile" && -d "$(profile_dir "$active_profile")" ]]; then
      printf '%s\n' "$active_profile"
      return 0
    fi
  fi

  if [[ -d "$(profile_dir "$DEFAULT_PROFILE")" ]]; then
    printf '%s\n' "$DEFAULT_PROFILE"
    return 0
  fi

  if compgen -G "$PROFILES_DIR/*/profile.env" >/dev/null 2>&1; then
    profile_path="$(printf '%s\n' "$PROFILES_DIR"/*/profile.env | head -n 1)"
    printf '%s\n' "$(basename "$(dirname "$profile_path")")"
    return 0
  fi

  return 1
}

require_current_profile_name() {
  local profile_name

  profile_name="$(current_profile_name || true)"
  [[ -n "$profile_name" ]] || die "当前还没有初始化配置，请先运行 proxy-manager init，或直接运行 proxy-manager 进入菜单。"
  printf '%s\n' "$profile_name"
}

resolve_effective_profile() {
  if [[ -n "${1:-}" ]]; then
    printf '%s\n' "$1"
  else
    require_current_profile_name
  fi
}

is_change_section() {
  case "${1:-}" in
    shared|cdn|reality|hy2|site)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_url_target() {
  case "${1:-}" in
    cdn|reality|hy2|all)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

confirm_action() {
  local prompt="${1:-确认继续？[y/N]: }"
  local answer

  read -r -p "$prompt" answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

select_url_target() {
  local choice

  echo
  echo "请选择要输出的链接："
  echo "1. CDN VLESS"
  echo "2. Reality"
  echo "3. Hysteria2"
  echo "4. 全部"
  read -r -p "请输入选项 [1-4，默认 4]: " choice

  case "${choice:-4}" in
    1) URL_TARGET="cdn" ;;
    2) URL_TARGET="reality" ;;
    3) URL_TARGET="hy2" ;;
    4) URL_TARGET="all" ;;
    *) die "无效选项: $choice" ;;
  esac
}

select_change_item() {
  local choice

  echo
  echo "请选择要修改的内容："
  echo "1. 共享 UUID"
  echo "2. CDN 路径"
  echo "3. Reality 借用目标"
  echo "4. Reality 密钥"
  echo "5. Hysteria2 密码"
  echo "6. 伪装页 HTML"
  read -r -p "请输入选项 [1-6]: " choice

  case "$choice" in
    1)
      CHANGE_SECTION="shared"
      CHANGE_OPTION="uuid"
      ;;
    2)
      CHANGE_SECTION="cdn"
      CHANGE_OPTION="path"
      ;;
    3)
      CHANGE_SECTION="reality"
      CHANGE_OPTION="target"
      ;;
    4)
      CHANGE_SECTION="reality"
      CHANGE_OPTION="key"
      ;;
    5)
      CHANGE_SECTION="hy2"
      CHANGE_OPTION="password"
      ;;
    6)
      CHANGE_SECTION="site"
      CHANGE_OPTION="html"
      ;;
    *)
      die "无效选项: $choice"
      ;;
  esac
}

select_change_option_for_section() {
  local section="$1"
  local choice

  case "$section" in
    shared)
      CHANGE_OPTION="uuid"
      ;;
    cdn)
      CHANGE_OPTION="path"
      ;;
    hy2)
      CHANGE_OPTION="password"
      ;;
    site)
      CHANGE_OPTION="html"
      ;;
    reality)
      echo
      echo "请选择 Reality 修改项："
      echo "1. 借用目标"
      echo "2. 重新生成密钥"
      read -r -p "请输入选项 [1-2，默认 1]: " choice
      case "${choice:-1}" in
        1) CHANGE_OPTION="target" ;;
        2) CHANGE_OPTION="key" ;;
        *) die "无效选项: $choice" ;;
      esac
      ;;
    *)
      die "不支持的更改分组: $section"
      ;;
  esac
}

prompt_change_value() {
  local section="$1"
  local option="$2"
  local value="${3:-}"
  local site_choice

  CHANGE_VALUE="$value"

  case "$section:$option" in
    shared:uuid)
      if [[ -z "$CHANGE_VALUE" ]]; then
        read -r -p "请输入新的 UUID，直接回车自动生成: " CHANGE_VALUE
        [[ -n "$CHANGE_VALUE" ]] || CHANGE_VALUE="auto"
      fi
      ;;
    cdn:path)
      if [[ -z "$CHANGE_VALUE" ]]; then
        read -r -p "请输入新的 CDN 路径，直接回车自动生成: " CHANGE_VALUE
        [[ -n "$CHANGE_VALUE" ]] || CHANGE_VALUE="auto"
      fi
      ;;
    reality:target)
      if [[ -z "$CHANGE_VALUE" ]]; then
        select_reality_target
        CHANGE_VALUE="$REALITY_SERVER_NAME"
      fi
      ;;
    reality:key)
      [[ -n "$CHANGE_VALUE" ]] || CHANGE_VALUE="auto"
      ;;
    hy2:password)
      if [[ -z "$CHANGE_VALUE" ]]; then
        read -r -p "请输入新的 Hysteria2 密码，直接回车自动生成: " CHANGE_VALUE
        [[ -n "$CHANGE_VALUE" ]] || CHANGE_VALUE="auto"
      fi
      ;;
    site:html)
      if [[ -z "$CHANGE_VALUE" ]]; then
        echo
        echo "请选择伪装页来源："
        echo "1. 使用默认页面"
        echo "2. 使用自定义 HTML 文件"
        read -r -p "请输入选项 [1-2，默认 1]: " site_choice
        case "${site_choice:-1}" in
          1)
            CHANGE_VALUE="default"
            ;;
          2)
            read -r -p "请输入自定义 HTML 文件绝对路径: " CHANGE_VALUE
            [[ -n "$CHANGE_VALUE" ]] || die "自定义 HTML 文件路径不能为空。"
            ;;
          *)
            die "无效选项: $site_choice"
            ;;
        esac
      fi
      ;;
    *)
      die "不支持的更改项: $section $option"
      ;;
  esac
}

show_main_menu() {
  local choice

  while true; do
    echo
    echo "proxy-manager 菜单"
    echo "1. 初始化默认配置"
    echo "2. 查看当前配置"
    echo "3. 输出客户端链接"
    echo "4. 修改配置"
    echo "5. 重新应用配置"
    echo "6. 卸载当前配置"
    echo "7. 查看帮助"
    echo "0. 退出"
    read -r -p "请输入选项 [0-7]: " choice

    case "$choice" in
      1)
        cmd_init "$DEFAULT_PROFILE"
        return 0
        ;;
      2)
        cmd_info
        return 0
        ;;
      3)
        cmd_url
        return 0
        ;;
      4)
        cmd_change
        return 0
        ;;
      5)
        cmd_apply
        return 0
        ;;
      6)
        cmd_del
        return 0
        ;;
      7)
        cmd_help
        return 0
        ;;
      0)
        return 0
        ;;
      *)
        echo "无效选项，请重新输入。"
        ;;
    esac
  done
}

derive_profile_storage_paths() {
  PROFILE_DIR="$(profile_dir "$PROFILE_NAME")"
  ENTRIES_DIR="$PROFILE_DIR/entries"
  GENERATED_DIR="$PROFILE_DIR/generated"
  PROFILE_ENV="$PROFILE_DIR/profile.env"
  CDN_ENV="$ENTRIES_DIR/cdn.env"
  REALITY_ENV="$ENTRIES_DIR/reality.env"
  HY2_ENV="$ENTRIES_DIR/hy2.env"
}

derive_profile_paths() {
  derive_profile_storage_paths
  WEB_ROOT="/var/www/$DOMAIN"
  NGINX_CONF="/etc/nginx/conf.d/${DOMAIN}.conf"
  ACME_CHALLENGE_DIR="$WEB_ROOT/.well-known/acme-challenge"
  HY2_WEB_ROOT="/var/www/$HY2_DOMAIN"
  HY2_NGINX_CONF="/etc/nginx/conf.d/${HY2_DOMAIN}.conf"
  HY2_ACME_CHALLENGE_DIR="$HY2_WEB_ROOT/.well-known/acme-challenge"
  COMPAT_METADATA_FILE="$METADATA_DIR/${DOMAIN}.env"
}

ensure_profile_dirs() {
  mkdir -p "$PROFILE_DIR" "$ENTRIES_DIR" "$GENERATED_DIR"
}

save_profile() {
  derive_profile_paths
  ensure_profile_dirs

  {
    write_env_field "PROFILE_NAME" "$PROFILE_NAME"
    write_env_field "DOMAIN" "$DOMAIN"
    write_env_field "SERVER_IP" "$SERVER_IP"
    write_env_field "PORT" "$PORT"
    write_env_field "CDN_PORT" "$CDN_PORT"
    write_env_field "REALITY_PORT" "$REALITY_PORT"
    write_env_field "SHARED_UUID" "$SHARED_UUID"
    write_env_field "WEB_ROOT" "$WEB_ROOT"
    write_env_field "NGINX_CONF" "$NGINX_CONF"
    write_env_field "ACME_CHALLENGE_DIR" "$ACME_CHALLENGE_DIR"
    write_env_field "XRAY_CONFIG" "$XRAY_CONFIG"
    write_env_field "REALITY_CONFIG_DIR" "$REALITY_CONFIG_DIR"
    write_env_field "REALITY_CONFIG" "$REALITY_CONFIG"
    write_env_field "HYSTERIA_CONFIG" "$HYSTERIA_CONFIG"
    write_env_field "SITE_HTML_MODE" "$SITE_HTML_MODE"
    write_env_field "SITE_HTML_PATH" "$SITE_HTML_PATH"
  } >"$PROFILE_ENV"

  {
    write_env_field "ENTRY_NAME" "cdn"
    write_env_field "WSPATH" "$WSPATH"
  } >"$CDN_ENV"

  {
    write_env_field "ENTRY_NAME" "reality"
    write_env_field "REALITY_SERVER_NAME" "$REALITY_SERVER_NAME"
    write_env_field "REALITY_FINGERPRINT" "$REALITY_FINGERPRINT"
    write_env_field "REALITY_SHORT_ID" "$REALITY_SHORT_ID"
    write_env_field "REALITY_PRIVATE_KEY" "$REALITY_PRIVATE_KEY"
    write_env_field "REALITY_PUBLIC_KEY" "$REALITY_PUBLIC_KEY"
  } >"$REALITY_ENV"

  {
    write_env_field "ENTRY_NAME" "hy2"
    write_env_field "HY2_DOMAIN" "$HY2_DOMAIN"
    write_env_field "HY2_PORT" "$HY2_PORT"
    write_env_field "HY2_WEB_ROOT" "$HY2_WEB_ROOT"
    write_env_field "HY2_NGINX_CONF" "$HY2_NGINX_CONF"
    write_env_field "HY2_ACME_CHALLENGE_DIR" "$HY2_ACME_CHALLENGE_DIR"
    write_env_field "HYSTERIA_AUTH" "$HYSTERIA_AUTH"
  } >"$HY2_ENV"
}

resolve_profile_name() {
  local identifier="${1:-$DEFAULT_PROFILE}"
  local profile
  local profile_path
  local profile_domain
  local hy2_domain

  if [[ -d "$(profile_dir "$identifier")" ]]; then
    printf '%s\n' "$identifier"
    return 0
  fi

  if [[ -f "$METADATA_DIR/${identifier}.env" ]]; then
    profile="$(grep -E '^PROFILE_NAME=' "$METADATA_DIR/${identifier}.env" | head -n 1 | cut -d= -f2- | tr -d "'" | tr -d '"')"
    [[ -n "$profile" ]] || die "无法解析 profile: $identifier"
    printf '%s\n' "$profile"
    return 0
  fi

  if ! compgen -G "$PROFILES_DIR/*/profile.env" >/dev/null 2>&1; then
    die "未找到任何 profile。"
  fi

  for profile_path in "$PROFILES_DIR"/*/profile.env; do
    profile="$(basename "$(dirname "$profile_path")")"
    profile_domain="$(grep -E '^DOMAIN=' "$profile_path" | head -n 1 | cut -d= -f2- | tr -d "'" | tr -d '"')"
    hy2_domain="$(grep -E '^HY2_DOMAIN=' "$(dirname "$profile_path")/entries/hy2.env" | head -n 1 | cut -d= -f2- | tr -d "'" | tr -d '"')"
    if [[ "$profile_domain" == "$identifier" || "$hy2_domain" == "$identifier" ]]; then
      printf '%s\n' "$profile"
      return 0
    fi
  done

  die "未找到对应的 profile: $identifier"
}

load_profile() {
  PROFILE_NAME="$(resolve_profile_name "${1:-$DEFAULT_PROFILE}")"
  derive_profile_storage_paths
  [[ -f "$PROFILE_ENV" && -f "$CDN_ENV" && -f "$REALITY_ENV" && -f "$HY2_ENV" ]] || die "profile 文件不完整: $PROFILE_NAME"
  # shellcheck disable=SC1090
  . "$PROFILE_ENV"
  # shellcheck disable=SC1090
  . "$CDN_ENV"
  # shellcheck disable=SC1090
  . "$REALITY_ENV"
  # shellcheck disable=SC1090
  . "$HY2_ENV"
  derive_profile_paths
}

maybe_backup_legacy_nginx_conf() {
  local backup_path

  if [[ -f "$LEGACY_NGINX_CONF" ]] && grep -Fq "server_name $DOMAIN;" "$LEGACY_NGINX_CONF" && grep -Fq "proxy_pass http://127.0.0.1:$PORT;" "$LEGACY_NGINX_CONF"; then
    backup_path="${LEGACY_NGINX_CONF}.bak.$(date +%s)"
    echo "检测到旧版配置 $LEGACY_NGINX_CONF ，正在备份到 $backup_path ..."
    mv "$LEGACY_NGINX_CONF" "$backup_path"
  fi
}

deploy_decoy_html() {
  mkdir -p "$ACME_CHALLENGE_DIR" "$HY2_ACME_CHALLENGE_DIR"

  case "$SITE_HTML_MODE" in
    default)
      if [[ -f "$DEFAULT_INDEX_HTML" ]]; then
        cp "$DEFAULT_INDEX_HTML" "$WEB_ROOT/index.html"
      else
        curl -fsSL "$REMOTE_INDEX_HTML_URL" -o "$WEB_ROOT/index.html"
      fi
      ;;
    custom)
      [[ -f "$SITE_HTML_PATH" ]] || die "自定义伪装页不存在: $SITE_HTML_PATH"
      cp "$SITE_HTML_PATH" "$WEB_ROOT/index.html"
      ;;
    *)
      die "未知的伪装页模式: $SITE_HTML_MODE"
      ;;
  esac
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

write_bootstrap_nginx_conf() {
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
}

write_final_nginx_conf() {
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
}

ensure_certificate() {
  local domain="$1"
  local webroot="$2"

  if [[ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]]; then
    return 0
  fi

  certbot certonly --webroot -w "$webroot" -d "$domain" --non-interactive --agree-tos --register-unsafely-without-email
}

write_xray_config() {
  cat <<EOF >"$XRAY_CONFIG"
{
  "inbounds": [{
    "port": $PORT,
    "listen": "127.0.0.1",
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$SHARED_UUID"}],
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
          "uuid": "$SHARED_UUID",
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
            ""
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

write_hysteria_config() {
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
}

compute_links() {
  local encoded_ws_path
  local encoded_reality_sni

  encoded_ws_path="$(urlencode "$WSPATH")"
  encoded_reality_sni="$(urlencode "$REALITY_SERVER_NAME")"
  VLESS_LINK="vless://$SHARED_UUID@$DOMAIN:$CDN_PORT?encryption=none&security=tls&type=ws&host=$DOMAIN&path=$encoded_ws_path&sni=$DOMAIN#$DOMAIN-cdn"
  REALITY_LINK="vless://$SHARED_UUID@$SERVER_IP:$REALITY_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$encoded_reality_sni&fp=$REALITY_FINGERPRINT&pbk=$REALITY_PUBLIC_KEY&type=tcp#reality-direct"
  HY2_LINK="hy2://$HYSTERIA_AUTH@$HY2_DOMAIN:$HY2_PORT/?sni=$HY2_DOMAIN#$HY2_DOMAIN-hy2"
}

save_generated_links() {
  mkdir -p "$GENERATED_DIR"
  compute_links
  {
    write_env_field "VLESS_LINK" "$VLESS_LINK"
    write_env_field "REALITY_LINK" "$REALITY_LINK"
    write_env_field "HY2_LINK" "$HY2_LINK"
  } >"$GENERATED_DIR/links.env"
}

write_compat_metadata() {
  {
    write_env_field "PROFILE_NAME" "$PROFILE_NAME"
    write_env_field "DOMAIN" "$DOMAIN"
    write_env_field "SERVER_IP" "$SERVER_IP"
    write_env_field "SHARED_UUID" "$SHARED_UUID"
    write_env_field "WSPATH" "$WSPATH"
    write_env_field "PORT" "$PORT"
    write_env_field "CDN_PORT" "$CDN_PORT"
    write_env_field "REALITY_PORT" "$REALITY_PORT"
    write_env_field "WEB_ROOT" "$WEB_ROOT"
    write_env_field "NGINX_CONF" "$NGINX_CONF"
    write_env_field "REALITY_SERVER_NAME" "$REALITY_SERVER_NAME"
    write_env_field "REALITY_FINGERPRINT" "$REALITY_FINGERPRINT"
    write_env_field "REALITY_SHORT_ID" "$REALITY_SHORT_ID"
    write_env_field "REALITY_PUBLIC_KEY" "$REALITY_PUBLIC_KEY"
    write_env_field "REALITY_CONFIG" "$REALITY_CONFIG"
    write_env_field "HY2_DOMAIN" "$HY2_DOMAIN"
    write_env_field "HY2_PORT" "$HY2_PORT"
    write_env_field "HY2_WEB_ROOT" "$HY2_WEB_ROOT"
    write_env_field "HY2_NGINX_CONF" "$HY2_NGINX_CONF"
    write_env_field "XRAY_CONFIG" "$XRAY_CONFIG"
    write_env_field "HYSTERIA_CONFIG" "$HYSTERIA_CONFIG"
    write_env_field "HYSTERIA_AUTH" "$HYSTERIA_AUTH"
    write_env_field "VLESS_LINK" "$VLESS_LINK"
    write_env_field "REALITY_LINK" "$REALITY_LINK"
    write_env_field "HY2_LINK" "$HY2_LINK"
  } >"$COMPAT_METADATA_FILE"
}

print_profile_summary() {
  compute_links
  echo "================================================="
  echo "CDN 域名: $DOMAIN"
  echo "CDN 路径: $WSPATH"
  echo "共享 UUID: $SHARED_UUID"
  echo "Reality 地址: $SERVER_IP"
  echo "Reality 借用目标: $REALITY_SERVER_NAME"
  echo "Reality 指纹: $REALITY_FINGERPRINT"
  echo "HY2 域名: $HY2_DOMAIN"
  echo "HY2 密码: $HYSTERIA_AUTH"
  echo "伪装页模式: $SITE_HTML_MODE"
  if [[ "$SITE_HTML_MODE" == "custom" ]]; then
    echo "伪装页来源: $SITE_HTML_PATH"
  else
    echo "伪装页来源: $DEFAULT_INDEX_HTML"
  fi
  echo "================================================="
}

print_urls() {
  local target="${1:-all}"

  compute_links
  case "$target" in
    cdn)
      printf '%s\n' "$VLESS_LINK"
      ;;
    reality)
      printf '%s\n' "$REALITY_LINK"
      ;;
    hy2)
      printf '%s\n' "$HY2_LINK"
      ;;
    all)
      echo "CDN VLESS URL:"
      printf '%s\n' "$VLESS_LINK"
      echo "Reality VLESS URL:"
      printf '%s\n' "$REALITY_LINK"
      echo "Hysteria2 URL:"
      printf '%s\n' "$HY2_LINK"
      ;;
    *)
      die "未知的线路名称: $target"
      ;;
  esac
}

cmd_apply_internal() {
  load_profile "${1:-$DEFAULT_PROFILE}"

  maybe_backup_legacy_nginx_conf
  deploy_decoy_html
  write_bootstrap_nginx_conf

  nginx -t
  systemctl enable nginx
  reload_or_restart_nginx

  ensure_certificate "$DOMAIN" "$WEB_ROOT"
  ensure_certificate "$HY2_DOMAIN" "$HY2_WEB_ROOT"

  write_final_nginx_conf
  write_xray_config
  write_reality_config
  write_hysteria_config

  nginx -t
  sing-box check -D /var/lib/sing-box -C "$REALITY_CONFIG_DIR"

  systemctl enable xray sing-box hysteria-server.service nginx
  systemctl restart xray
  systemctl restart sing-box
  systemctl restart hysteria-server.service
  reload_or_restart_nginx

  save_generated_links
  write_compat_metadata
  printf '%s\n' "$PROFILE_NAME" >"$ACTIVE_PROFILE_FILE"
}

cmd_help() {
  cat <<'EOF'
proxy-manager usage:
  proxy-manager                  交互菜单
  proxy-manager init            首次初始化
  proxy-manager info            查看当前配置
  proxy-manager url [cdn|reality|hy2|all]
  proxy-manager change          交互式修改配置
  proxy-manager apply           重新应用当前配置
  proxy-manager del             卸载当前配置
  proxy-manager help

快捷命令:
  id [uuid|auto]
  path [/path|auto]
  sni [domain]
  passwd [password|auto]
  web [default|/abs/path/index.html]

兼容完整写法:
  proxy-manager init [profile]
  proxy-manager apply [profile]
  proxy-manager info [profile]
  proxy-manager url [profile] [cdn|reality|hy2|all]
  proxy-manager change [profile] [shared|cdn|reality|hy2|site] [option] [value|auto]
  proxy-manager del [profile|cdn-domain|hy2-domain]

注意:
  当前版本同一台机器一次只运行一个活动 profile。

当前支持的 change 项：
  shared uuid [uuid|auto]
  cdn path [/path|auto]
  reality target [domain]
  reality key [auto]
  hy2 password [password|auto]
  site html [default|/abs/path/index.html]
EOF
}

cmd_init() {
  local profile="${1:-$DEFAULT_PROFILE}"

  ensure_root
  [[ ! -d "$(profile_dir "$profile")" ]] || die "当前已经存在一套配置。如需重装，请先执行 proxy-manager del 卸载后再初始化。"

  PROFILE_NAME="$profile"
  read -r -p "请输入你的 CDN 域名 (例如: cdn.yourdomain.com): " DOMAIN
  read -r -p "请输入 Hysteria2 使用的直连域名 (例如: hy2.yourdomain.com): " HY2_DOMAIN

  [[ -n "$DOMAIN" && -n "$HY2_DOMAIN" ]] || die "CDN 域名和 Hysteria2 域名都不能为空。"
  [[ "$HY2_DOMAIN" != "$DOMAIN" ]] || die "Hysteria2 直连域名不能和 CDN 域名相同。"

  select_reality_target

  SHARED_UUID="$(cat /proc/sys/kernel/random/uuid)"
  WSPATH="$(random_path)"
  SERVER_IP="$(detect_public_ipv4 || true)"
  if [[ -z "$SERVER_IP" ]]; then
    read -r -p "自动检测公网 IPv4 失败，请手动输入服务器公网 IPv4: " SERVER_IP
  fi
  [[ "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "服务器公网 IPv4 格式不正确。"

  PORT=10000
  CDN_PORT=8443
  REALITY_PORT=443
  HY2_PORT=443
  REALITY_FINGERPRINT="chrome"
  REALITY_SHORT_ID=""
  HYSTERIA_AUTH="$(random_password)"
  SITE_HTML_MODE="default"
  SITE_HTML_PATH=""
  generate_reality_keys
  save_profile
  cmd_apply_internal "$PROFILE_NAME"
  print_profile_summary
  print_urls all
}

cmd_apply() {
  local profile="${1:-}"

  ensure_root
  profile="$(resolve_effective_profile "$profile")"
  cmd_apply_internal "$profile"
  print_profile_summary
}

cmd_info() {
  local profile="${1:-}"

  ensure_root
  profile="$(resolve_effective_profile "$profile")"
  load_profile "$profile"
  print_profile_summary
}

cmd_url() {
  local first_arg="${1:-}"
  local second_arg="${2:-}"
  local profile
  local target

  ensure_root

  if is_url_target "$first_arg"; then
    profile="$(require_current_profile_name)"
    target="$first_arg"
  else
    profile="$(resolve_effective_profile "$first_arg")"
    target="$second_arg"
  fi

  if [[ -z "$target" ]]; then
    select_url_target
    target="$URL_TARGET"
  fi

  load_profile "$profile"
  print_urls "$target"
}

cmd_change() {
  local first_arg="${1:-}"
  local second_arg="${2:-}"
  local third_arg="${3:-}"
  local fourth_arg="${4:-}"
  local profile
  local section
  local option
  local value

  ensure_root

  if is_change_section "$first_arg"; then
    profile="$(require_current_profile_name)"
    section="$first_arg"
    option="$second_arg"
    value="$third_arg"
  else
    profile="$(resolve_effective_profile "$first_arg")"
    section="$second_arg"
    option="$third_arg"
    value="$fourth_arg"
  fi

  load_profile "$profile"

  if [[ -z "$section" ]]; then
    select_change_item
    section="$CHANGE_SECTION"
    option="$CHANGE_OPTION"
  fi

  if [[ -z "$option" ]]; then
    select_change_option_for_section "$section"
    option="$CHANGE_OPTION"
  fi

  prompt_change_value "$section" "$option" "$value"
  value="$CHANGE_VALUE"

  case "$section:$option" in
    shared:uuid)
      if [[ "$value" == "auto" || -z "$value" ]]; then
        SHARED_UUID="$(cat /proc/sys/kernel/random/uuid)"
      else
        SHARED_UUID="$value"
      fi
      ;;
    cdn:path)
      if [[ "$value" == "auto" || -z "$value" ]]; then
        WSPATH="$(random_path)"
      else
        [[ "$value" == /* ]] || die "路径必须以 / 开头。"
        WSPATH="$value"
      fi
      ;;
    reality:target)
      [[ -n "$value" ]] || die "Reality target 不能为空。"
      REALITY_SERVER_NAME="$value"
      ;;
    reality:key)
      if [[ -n "$value" && "$value" != "auto" ]]; then
        die "当前仅支持 reality key auto"
      fi
      REALITY_SHORT_ID=""
      generate_reality_keys
      ;;
    hy2:password)
      if [[ "$value" == "auto" || -z "$value" ]]; then
        HYSTERIA_AUTH="$(random_password)"
      else
        HYSTERIA_AUTH="$value"
      fi
      ;;
    site:html)
      if [[ "$value" == "default" || -z "$value" ]]; then
        SITE_HTML_MODE="default"
        SITE_HTML_PATH=""
      else
        [[ -f "$value" ]] || die "伪装页文件不存在: $value"
        SITE_HTML_MODE="custom"
        SITE_HTML_PATH="$value"
      fi
      ;;
    *)
      die "不支持的更改项: $section $option"
      ;;
  esac

  save_profile
  cmd_apply_internal "$PROFILE_NAME"
  print_profile_summary
  print_urls all
}

cmd_del() {
  local profile="${1:-}"
  local profile_count
  local active_profile=""

  ensure_root
  profile="$(resolve_effective_profile "$profile")"
  load_profile "$profile"
  profile_count="$(count_profiles)"

  if [[ -z "${1:-}" ]]; then
    echo
    echo "将卸载当前配置："
    echo "- CDN 域名: $DOMAIN"
    echo "- Hysteria2 域名: $HY2_DOMAIN"
    if ! confirm_action "确认卸载？[y/N]: "; then
      echo "已取消卸载。"
      return 0
    fi
  fi

  if [[ "$profile_count" -gt 1 ]]; then
    if [[ -f "$ACTIVE_PROFILE_FILE" ]]; then
      active_profile="$(tr -d '[:space:]' < "$ACTIVE_PROFILE_FILE")"
    fi
    [[ -n "$active_profile" ]] || die "检测到多个 profile，但没有 active_profile 记录，无法安全删除。"
    [[ "$active_profile" == "$PROFILE_NAME" ]] || die "当前版本仅支持删除活动 profile: $active_profile"
  fi

  systemctl stop xray 2>/dev/null || true
  systemctl disable xray 2>/dev/null || true
  systemctl stop sing-box 2>/dev/null || true
  systemctl disable sing-box 2>/dev/null || true
  systemctl stop hysteria-server.service 2>/dev/null || true
  systemctl disable hysteria-server.service 2>/dev/null || true

  rm -f "$XRAY_CONFIG" "$REALITY_CONFIG" "$HYSTERIA_CONFIG"
  rm -f "$NGINX_CONF" "$HY2_NGINX_CONF"
  rm -rf "$WEB_ROOT" "$HY2_WEB_ROOT"

  if [[ -f "/etc/letsencrypt/renewal/$DOMAIN.conf" ]] || [[ -d "/etc/letsencrypt/live/$DOMAIN" ]]; then
    certbot delete --cert-name "$DOMAIN" --non-interactive || true
  fi
  rm -rf "/etc/letsencrypt/live/$DOMAIN" "/etc/letsencrypt/archive/$DOMAIN"
  rm -f "/etc/letsencrypt/renewal/$DOMAIN.conf"

  if [[ -n "$HY2_DOMAIN" ]]; then
    if [[ -f "/etc/letsencrypt/renewal/$HY2_DOMAIN.conf" ]] || [[ -d "/etc/letsencrypt/live/$HY2_DOMAIN" ]]; then
      certbot delete --cert-name "$HY2_DOMAIN" --non-interactive || true
    fi
    rm -rf "/etc/letsencrypt/live/$HY2_DOMAIN" "/etc/letsencrypt/archive/$HY2_DOMAIN"
    rm -f "/etc/letsencrypt/renewal/$HY2_DOMAIN.conf"
  fi

  rm -rf "$PROFILE_DIR"
  rm -f "$COMPAT_METADATA_FILE"
  if [[ -f "$ACTIVE_PROFILE_FILE" ]] && [[ "$(cat "$ACTIVE_PROFILE_FILE")" == "$PROFILE_NAME" ]]; then
    rm -f "$ACTIVE_PROFILE_FILE"
  fi

  nginx -t
  reload_or_restart_nginx
  rmdir "$REALITY_CONFIG_DIR" 2>/dev/null || true
}

main() {
  local cmd="${1:-menu}"

  case "$cmd" in
    menu|main)
      show_main_menu
      ;;
    init)
      shift
      cmd_init "$@"
      ;;
    apply)
      shift
      cmd_apply "$@"
      ;;
    info)
      shift
      cmd_info "$@"
      ;;
    url)
      shift
      cmd_url "$@"
      ;;
    change)
      shift
      cmd_change "$@"
      ;;
    del)
      shift
      cmd_del "$@"
      ;;
    id)
      shift
      cmd_change shared uuid "${1:-}"
      ;;
    path)
      shift
      cmd_change cdn path "${1:-}"
      ;;
    sni)
      shift
      cmd_change reality target "${1:-}"
      ;;
    passwd)
      shift
      cmd_change hy2 password "${1:-}"
      ;;
    web)
      shift
      cmd_change site html "${1:-}"
      ;;
    help|-h|--help)
      cmd_help
      ;;
    *)
      die "未知命令: $cmd"
      ;;
  esac
}

main "$@"
