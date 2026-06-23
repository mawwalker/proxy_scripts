# proxy_scripts

用于在 VPS 上一键部署 `Nginx + Xray (VLESS + WS + TLS)`，并自动放置一个内置小游戏伪装页。

## 功能特点

- 自动安装 `nginx`、`certbot`、`curl`、`unzip`
- 自动安装 `Xray-core`
- 自动生成 `VLESS + WebSocket + TLS` 配置
- 自动申请 Let's Encrypt 证书
- 自动配置 `Nginx` 反代与 WebSocket 分流
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
4. 部署小游戏伪装页
5. 申请 TLS 证书
6. 写入 Nginx 配置
7. 启动并设置 `nginx`、`xray` 开机自启
8. 输出客户端连接参数

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

把这些参数填到你的客户端即可。

## 关于伪装页

- 仓库默认附带一个 `index.html` 小游戏页面，部署后访问 `https://你的域名` 就能看到它。
- 如果你是通过 GitHub 一键命令执行，脚本会自动从仓库下载默认 `index.html`。
- 如果你是先克隆仓库再本地执行脚本，脚本会优先使用脚本同目录下的 `index.html`。
- 如果你想换成自己的伪装页，直接替换仓库里的 `index.html` 后再执行即可。

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

## 仓库地址

GitHub: <https://github.com/mawwalker/proxy_scripts>
