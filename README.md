# proxy_scripts

用于在 VPS 上一键部署 `Nginx + Xray (VLESS + WS + TLS)`，并自动放置一个内置小游戏伪装页。

## 功能特点

- 自动安装 `nginx`、`certbot`、`curl`、`unzip`
- 自动安装 `Xray-core`
- 自动生成 `VLESS + WebSocket + TLS` 配置
- 自动输出可直接导入客户端的 `vless://` 分享链接
- 自动通过 `certbot --webroot` 申请 Let's Encrypt 证书
- 自动配置域名独立的 `Nginx` 反代与 WebSocket 分流
- 自动部署仓库内置的 `index.html` 小游戏伪装页
- 部署完成后直接输出客户端所需参数

## 适用环境

- Debian / Ubuntu 系 VPS
- 需要 `root` 权限执行
- 域名已解析到当前服务器公网 IP
- `80` / `443` 端口已放行

如果当前账号不是 `root`，先执行：

```bash
sudo -i
```

## 一键安装

推荐使用下面这条命令：

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

## 运行时会询问什么

脚本启动后会要求你输入：

- 域名，例如：`demo.example.com`
- WebSocket 路径，例如：`/secret-ws`

脚本会自动生成一个随机 `UUID`，无需手动准备。

## 脚本会自动做什么

执行过程中会依次完成这些动作：

1. 安装依赖组件
2. 安装 Xray
3. 写入 `VLESS + WS` 的 Xray 配置
4. 部署小游戏伪装页到当前域名独立目录
5. 写入 Nginx 引导配置并校验
6. 通过 `certbot --webroot` 申请 TLS 证书
7. 写入 Nginx 最终配置并校验
8. 启动或重载 `nginx`、重启 `xray`
9. 输出客户端连接参数

## 部署完成后你会拿到什么

脚本结束时会在终端输出以下信息：

- `Protocol`: `VLESS`
- `Address`: 你的域名
- `Port`: `443`
- `UUID`: 自动生成
- `Network`: `ws`
- `Host`: 你的域名
- `Path`: 你输入的 WebSocket 路径
- `TLS`: `tls`
- `VLESS URL`: 可直接导入客户端的完整分享链接

把这些参数填到你的客户端即可。

同时脚本还会直接输出一条完整的 `vless://` 链接，常见客户端可以直接导入，不需要再手动逐项填写。

## 客户端快速导入

安装完成后会看到类似下面的一整条链接：

```text
vless://uuid@your-domain.com:443?encryption=none&security=tls&type=ws&host=your-domain.com&path=%2Fsecret-ws&sni=your-domain.com#your-domain.com
```

直接复制整条 `vless://` 链接，到支持 VLESS 的客户端中导入即可。

脚本还会把这次部署的关键参数保存到：

```text
/etc/proxy_scripts/<你的域名>.env
```

这个文件主要用于后续卸载和排查。

## 关于伪装页

- 仓库默认附带一个 `index.html` 小游戏页面，部署后访问 `https://你的域名` 就能看到它。
- 如果你是通过 GitHub 一键命令执行，脚本会自动从仓库下载默认 `index.html`。
- 如果你是先克隆仓库再本地执行脚本，脚本会优先使用脚本同目录下的 `index.html`。
- 如果你想换成自己的伪装页，直接替换仓库里的 `index.html` 后再执行即可。
- 站点目录默认会创建为 `/var/www/<你的域名>`，不会和其他站点共享 `/var/www/html`。

自定义页面的执行方式：

```bash
git clone https://github.com/mawwalker/proxy_scripts.git
cd proxy_scripts
bash install_proxy.sh
```

## 使用注意事项

- 申请证书前，如果域名走了 Cloudflare，请先关闭橙云代理，只保留 DNS 解析。
- 等脚本部署成功、浏览器能正常打开伪装页、客户端也能正常连接后，再去 Cloudflare 开启橙云。
- 本脚本依赖 `apt`，不适用于 CentOS / Alpine 等非 Debian 系系统。
- 请确保服务器没有被其他服务占用 `80` 和 `443` 端口。

## Nginx 配置说明

- 脚本会为当前域名单独生成配置文件：`/etc/nginx/conf.d/<你的域名>.conf`
- 脚本会为当前域名单独生成站点目录：`/var/www/<你的域名>`
- 证书申请方式是 `certbot --webroot`，不会像 `standalone` 模式那样先停掉整台机器上的 Nginx
- 脚本在每次重载前都会先执行 `nginx -t`，避免错误配置影响现有站点
- 后续如果你还要部署别的网站，直接新增其他 `conf.d/*.conf` 文件即可；只要 `server_name` 不冲突，就不会影响这个代理域名
- 如果你曾用旧版本脚本部署过固定的 `/etc/nginx/conf.d/vless.conf`，新脚本在检测到匹配当前域名的旧配置时会自动备份，再写入新的按域名隔离配置

## 一键卸载

如果你要卸载当前代理域名对应的代理站点，可以执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mawwalker/proxy_scripts/main/uninstall_proxy.sh)
```

脚本会提示你输入要卸载的域名，然后只清理当前域名相关资源，包括：

- 当前域名的 Nginx 配置文件
- 当前域名的站点目录
- 当前域名的 Let's Encrypt 证书
- 当前部署保存的元数据文件
- 当前这套脚本生成的 Xray 配置，并停止 `xray` 服务

默认不会做的事情：

- 不卸载 `nginx`
- 不卸载 `certbot`
- 不删除其他域名的 `conf.d/*.conf`
- 不删除其他网站目录
- 不删除 `xray` 二进制程序本体

## 仓库地址

GitHub: <https://github.com/mawwalker/proxy_scripts>
