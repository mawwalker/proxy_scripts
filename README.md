# proxy_scripts

用于在 VPS 上一键部署三条可切换代理线路：

- `VLESS + WS + TLS + CDN`，走 `8443/tcp`
- `VLESS + Reality`，走 `443/tcp`
- `Hysteria2`，走 `443/udp`

同时自动部署一个内置 `index.html` 小游戏伪装页。

## 功能特点

- 自动安装 `nginx`、`certbot`、`curl`、`unzip`、`openssl`
- 自动安装 `Xray-core`
- 自动安装 `sing-box`
- 自动安装 `Hysteria2`
- 自动生成 `CDN VLESS` 配置
- 自动生成 `Reality` 配置
- 自动生成 `Hysteria2` 配置
- 自动输出可直接导入客户端的 `vless://` 和 `hy2://` 分享链接
- 自动通过 `certbot --webroot` 申请 CDN 域名与 Hysteria2 域名证书
- 自动为当前域名单独生成 Nginx 站点配置，不影响其他站点

## 适用环境

- Debian / Ubuntu 系 VPS
- 需要 `root` 权限执行
- 建议准备 2 个已解析到当前 VPS 的域名或子域名
- `cdn.example.com` 用于 `CDN VLESS`
- `hy2.example.com` 用于 `Hysteria2`
- 需要放行 `80/tcp`、`443/tcp`、`443/udp`、`8443/tcp`

说明：

- `Reality` 不需要单独域名，客户端默认直接连服务器公网 `IPv4`
- `Hysteria2` 直连域名必须保持 `DNS only`
- `CDN` 域名后续可以开启 Cloudflare 橙云

如果当前账号不是 `root`，先执行：

```bash
sudo -i
```

## 一键安装

推荐命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mawwalker/proxy_scripts/main/install_proxy.sh)
```

备选写法：

```bash
curl -fsSL https://raw.githubusercontent.com/mawwalker/proxy_scripts/main/install_proxy.sh | bash
```

如果系统里还没有 `curl`，先安装：

```bash
apt update && apt install -y curl
```

## 脚本会询问什么

执行后会要求你输入：

- CDN 域名，例如：`cdn.example.com`
- WebSocket 路径，例如：`/secret-ws`
- Hysteria2 直连域名，例如：`hy2.example.com`

Reality 这一条不会再要求你输入自有域名，而是会：

- 自动检测服务器公网 `IPv4`
- 让你从预设借用目标里选一个 `SNI`
- 默认使用 `s3.amazonaws.com`

脚本会自动生成：

- 一个随机 `UUID`
- 一个随机 `Reality short_id`
- 一组 `Reality public/private key`
- 一个随机 `Hysteria2` 密码

另外，脚本默认给 `Reality` 使用：

- `SNI`: `s3.amazonaws.com`
- `Fingerprint`: `chrome`

预设借用目标目前包括：

- `s3.amazonaws.com`（默认）
- `www.microsoft.com`
- `learn.microsoft.com`
- 或者你手动输入自定义借用域名

默认没有放 `Google` 系目标，是因为这类域名在中国大陆网络环境下常常本身就不可直连，拿来做默认 Reality 借站会直接导致链接不可用。

## 部署拓扑

部署完成后，三条线路分别是：

1. `CDN VLESS`

- 域名：你输入的 CDN 域名
- 协议：`VLESS + WS + TLS`
- 端口：`8443/tcp`
- 入口：`Nginx + Xray`
- 用途：抗封锁、保底可用

2. `Reality`

- 地址：服务器公网 `IPv4`
- 借用目标：你选择的 `SNI`
- 协议：`VLESS + Reality`
- 端口：`443/tcp`
- 入口：`sing-box`
- 用途：低延迟直连，用借用站点伪装 TLS 外观

3. `Hysteria2`

- 域名：你输入的 Hysteria2 域名
- 协议：`Hysteria2`
- 端口：`443/udp`
- 入口：`hysteria-server`
- 用途：暴力穿透、适合垃圾网络 VPS

## 脚本会自动做什么

执行过程中会依次完成这些动作：

1. 安装基础依赖
2. 安装 `Xray-core`
3. 安装 `sing-box`
4. 安装 `Hysteria2`
5. 写入 `Xray` 的 CDN WebSocket 配置
6. 生成 `Reality` 密钥并写入 `sing-box` 配置
7. 部署小游戏伪装页
8. 写入 CDN 域名和 Hysteria2 域名的 Nginx 配置
9. 申请 CDN 域名和 Hysteria2 域名证书
10. 启动或重载 `nginx`、`xray`、`sing-box`、`hysteria-server.service`
11. 输出三条线路的客户端分享链接

## 部署完成后你会拿到什么

脚本结束时会输出：

- 一条 `CDN VLESS` 的 `vless://` 链接
- 一条 `Reality` 的 `vless://` 链接
- 一条 `Hysteria2` 的 `hy2://` 链接

同时还会把本次部署关键信息保存到：

```text
/etc/proxy_scripts/<你的 CDN 域名>.env
```

这个文件主要用于后续卸载与排查。

## 客户端快速导入

安装完成后会看到类似下面三条链接：

```text
vless://uuid@cdn.example.com:8443?encryption=none&security=tls&type=ws&host=cdn.example.com&path=%2Fsecret-ws&sni=cdn.example.com#cdn.example.com-cdn
vless://uuid@203.0.113.10:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=s3.amazonaws.com&fp=chrome&pbk=PUBLIC_KEY&sid=SHORT_ID&type=tcp&headerType=none#reality-direct
hy2://password@hy2.example.com:443/?sni=hy2.example.com#hy2.example.com-hy2
```

直接复制整条链接到支持对应协议的客户端中导入即可。

## 关于伪装页

- 仓库默认附带一个 `index.html` 小游戏页面
- CDN 域名访问地址是：`https://你的-CDN-域名:8443`
- 因为 `443/tcp` 被 `Reality` 占用，所以伪装页不再走标准 `443`
- 如果你是本地克隆仓库再执行脚本，脚本会优先使用同目录下的 `index.html`
- 如果你是远程一键执行，脚本会自动从仓库下载默认 `index.html`

自定义页面执行方式：

```bash
git clone https://github.com/mawwalker/proxy_scripts.git
cd proxy_scripts
bash install_proxy.sh
```

## 使用建议

- `CDN VLESS`：作为保命线路，优先用于抗封锁
- `Reality`：作为低延迟直连线路，适合本身网络质量较好的机器
- `Reality` 的借用目标优先选择中国大陆客户端本身能直连的站，不要默认拿 `Google` 系域名做预设
- `Hysteria2`：作为高吞吐直连线路，适合垃圾网络机器
- 客户端里同时导入三条链接，按网络情况自由切换

## Nginx 配置说明

- 脚本只会为当前 `CDN` 域名生成独立配置：`/etc/nginx/conf.d/<你的-CDN-域名>.conf`
- 脚本只会为 `Hysteria2` 域名生成 challenge 配置：`/etc/nginx/conf.d/<你的-HY2-域名>.conf`
- `Reality` 不走 Nginx，直接由 `sing-box` 监听 `443/tcp`
- 伪装站目录默认是：`/var/www/<你的-CDN-域名>`
- Hysteria2 challenge 目录默认是：`/var/www/<你的-HY2-域名>`
- 后续如果你还要部署别的网站，直接新增其他 `conf.d/*.conf` 即可
- 只要 `server_name` 不冲突，就不会影响现有站点

## 一键卸载

如果你要卸载这套代理配置，可以执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mawwalker/proxy_scripts/main/uninstall_proxy.sh)
```

脚本会让你输入：

- CDN 主域名
- 或 Hysteria2 域名

然后只清理当前这套部署生成的资源，包括：

- 当前 CDN 域名的 Nginx 配置
- 当前 CDN 域名的站点目录
- 当前 Hysteria2 域名的 challenge 配置和 challenge 目录
- 当前 CDN / Hysteria2 两套证书
- 当前 `Xray` 配置
- 当前 `sing-box` Reality 配置
- 当前 `Hysteria2` 配置
- 当前部署元数据
- 并停止 `xray`、`sing-box`、`hysteria-server.service`

默认不会做的事情：

- 不卸载 `nginx`
- 不卸载 `certbot`
- 不卸载 `xray` 二进制
- 不卸载 `sing-box` 二进制
- 不卸载 `hysteria` 二进制
- 不删除其他网站配置
- 不删除其他站点目录

## 注意事项

- 首次申请证书时，CDN 域名不要先开橙云，先保证 `DNS only`
- 等脚本部署成功、浏览器能打开 `https://你的-CDN-域名:8443`、客户端能连通后，再开启 CDN 域名的小黄云
- `Reality` 不需要自有域名，但你选的借用 `SNI` 应该尽量是中国大陆本身可访问的站
- `Hysteria2` 域名必须始终保持 `DNS only`
- 本脚本依赖 `apt`，不适用于 CentOS / Alpine
- 如果机器上已经有别的服务占用了 `443/tcp`、`443/udp` 或 `8443/tcp`，请先处理端口冲突

## 仓库地址

GitHub: <https://github.com/mawwalker/proxy_scripts>
