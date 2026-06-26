# proxy_scripts

用于在 VPS 上一键部署并管理一套默认三线路代理组合：

- `VLESS + WS + TLS + CDN`，走 `8443/tcp`
- `VLESS + Reality`，走 `443/tcp`
- `Hysteria2`，走 `443/udp`

同时自动部署一个内置 `index.html` 小游戏伪装页。

这套仓库现在分成两层：

- `install_proxy.sh`
  首次安装入口，负责装依赖并初始化默认配置
- `proxy_manager.sh`
  管理入口，负责后续查看、输出链接、修改参数、重新应用、删除配置

## 功能特点

- 保留原有一键安装体验
- 新增管理命令层，支持后续修改协议内容
- 自动安装 `nginx`、`certbot`、`curl`、`unzip`、`openssl`
- 自动安装 `Xray-core`
- 自动安装 `sing-box`
- 自动安装 `Hysteria2`
- 自动生成并管理默认三线路模板
- 自动输出可直接导入客户端的 `vless://` 和 `hy2://` 链接
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

## 首次安装时会发生什么

`install_proxy.sh` 会先安装：

- `nginx`
- `certbot`
- `Xray-core`
- `sing-box`
- `Hysteria2`
- `proxy-manager`

然后自动执行：

```bash
proxy-manager init default
```

也就是说，首次安装时真正收集配置并生成三条线路的是管理器，而不是 bootstrap 脚本本身。

## 首次安装时会询问什么

执行安装命令后，`proxy-manager` 会要求你输入：

- CDN 域名，例如：`cdn.example.com`
- WebSocket 路径，例如：`/secret-ws`
- Hysteria2 直连域名，例如：`hy2.example.com`

Reality 这一条不会再要求你输入自有域名，而是会：

- 自动检测服务器公网 `IPv4`
- 让你从预设借用目标里选一个 `SNI`
- 默认使用 `s3.amazonaws.com`

脚本会自动生成：

- 一个共享 `UUID`
- 一个随机 `Reality short_id`
- 一组 `Reality public/private key`
- 一个随机 `Hysteria2` 密码

Reality 当前预设借用目标：

- `s3.amazonaws.com`（默认）
- `www.microsoft.com`
- `learn.microsoft.com`
- 或者你手动输入自定义借用域名

默认没有放 `Google` 系目标，因为这类域名在中国大陆网络环境下常常本身就不可直连，拿来做默认 Reality 借站会直接导致链接不可用。

## 部署拓扑

默认模板部署完成后，三条线路分别是：

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

## 客户端快速导入

安装完成后会输出三条链接，类似：

```text
vless://uuid@cdn.example.com:8443?encryption=none&security=tls&type=ws&host=cdn.example.com&path=%2Fsecret-ws&sni=cdn.example.com#cdn.example.com-cdn
vless://uuid@203.0.113.10:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=s3.amazonaws.com&fp=chrome&pbk=PUBLIC_KEY&sid=SHORT_ID&type=tcp&headerType=none#reality-direct
hy2://password@hy2.example.com:443/?sni=hy2.example.com#hy2.example.com-hy2
```

直接复制整条链接到支持对应协议的客户端中导入即可。

## 管理命令

安装完成后，系统里会放一个管理命令：

```bash
/usr/local/bin/proxy-manager
```

常用用法：

```bash
proxy-manager help
proxy-manager info default
proxy-manager url default all
proxy-manager url default reality
proxy-manager apply default
proxy-manager del default
```

当前版本同一台机器一次只运行一个活动 profile。  
如果你后面保存了多套 profile，它们更适合作为“切换预设”，不是并行共存实例。

## 支持修改什么

当前第一版管理器先完整支持你现在这套默认三线路模板，还没有扩成“任意协议任意组合”的通用平台。

目前支持的高频修改项：

```bash
proxy-manager change default shared uuid auto
proxy-manager change default shared uuid 11111111-2222-3333-4444-555555555555

proxy-manager change default cdn path /new-ws
proxy-manager change default cdn path auto

proxy-manager change default reality target s3.amazonaws.com
proxy-manager change default reality key auto

proxy-manager change default hy2 password auto
proxy-manager change default hy2 password myStrongPassword123

proxy-manager change default site html default
proxy-manager change default site html /root/my-site/index.html
```

这些 `change` 命令会自动：

1. 更新 profile 数据
2. 重新渲染 `nginx / xray / sing-box / hysteria` 配置
3. 校验配置
4. 重载服务
5. 输出最新链接

## 配置存储结构

默认 profile 会保存到：

```text
/etc/proxy_scripts/profiles/default/
```

其中主要包括：

- `profile.env`
  共享信息，例如 CDN 域名、服务器 IP、共享 UUID、伪装页来源
- `entries/cdn.env`
  CDN 线路参数，例如 `path`
- `entries/reality.env`
  Reality 参数，例如借用目标、指纹、公私钥、short_id
- `entries/hy2.env`
  Hysteria2 参数，例如域名、密码
- `generated/`
  生成后的链接等派生内容

另外还会保留一个兼容用摘要文件：

```text
/etc/proxy_scripts/<你的-CDN-域名>.env
```

主要用于定位 profile 和兼容现有卸载入口。

## 关于伪装页

- 仓库默认附带一个 `index.html` 小游戏页面
- CDN 域名访问地址是：`https://你的-CDN-域名:8443`
- 因为 `443/tcp` 被 `Reality` 占用，所以伪装页不再走标准 `443`
- 首次安装时默认页面会被放到：
  `/usr/local/share/proxy-scripts/index.html`
- 如果你后续要切换自己的页面，直接用：
  `proxy-manager change default site html /你的/index.html`

## Nginx 配置说明

- 当前 `CDN` 域名配置：`/etc/nginx/conf.d/<你的-CDN-域名>.conf`
- 当前 `Hysteria2` challenge 配置：`/etc/nginx/conf.d/<你的-HY2-域名>.conf`
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

然后内部实际执行的是：

```bash
proxy-manager del <你输入的标识>
```

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

## 后续扩展方向

这一版已经把结构拆成了“安装入口 + 管理器 + profile/entry 数据模型”。  
下一步如果你要继续扩，可以在这个框架上增加：

- 更多 `change` 选项
- 更多 entry 类型
- 更通用的 `add / del / new` 协议能力
- 多 profile 同时管理

## 仓库地址

GitHub: <https://github.com/mawwalker/proxy_scripts>
