# vps-cf-rescue

VPS 的 IP 被墙后，用两个脚本完成检查和补救：

- **check-block.sh**：检查 IP 和端口是不是被墙了。用国内、海外两组探针同时测，再拿百度做对照。
- **cf-proxy.sh**：让 3x-ui 节点和网站改走 Cloudflare。节点用 VLESS + XHTTP + TLS，不需要 Caddy 或 Nginx。

## 用法

在 VPS 上以 root 运行。

检查是否被墙：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hanscn2025/vps-cf-rescue/main/check-block.sh)
```

新建走 Cloudflare 的节点（把域名换成你自己的子域名）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hanscn2025/vps-cf-rescue/main/cf-proxy.sh) node edge.example.com
```

让已有网站走 Cloudflare：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hanscn2025/vps-cf-rescue/main/cf-proxy.sh) site www.example.com
```

请用 `bash <(curl ...)` 运行，不要用 `curl ... | bash`：后一种写法下，脚本没法读取你的键盘输入。

## cf-proxy.sh 的两种模式

- **半自动（默认）**：脚本只问 3x-ui 面板的用户名和密码。Cloudflare 上要做的两步（添加 DNS 记录、设置 SSL）由脚本打印出来，你在网页上点完后按回车，脚本接着验证并输出分享链接。
- **全自动（可选）**：另外提供一个 Cloudflare API Token，Cloudflare 上的操作也由脚本完成。创建 Token 时选 Custom token，授予以下权限：
  - Zone · Zone · Read
  - Zone · DNS · Edit
  - Zone · SSL and Certificates · Edit
  - Zone · Config Rules · Edit

也可以用环境变量 `XUI_USER`、`XUI_PASS`（或 `XUI_TOKEN`）、`CF_API_TOKEN` 提前传入，就不用在运行时输入。

客户端导入链接后，如果是 v2rayN，要把 VLESS 的内核设为 **Xray**（sing-box 内核不支持 XHTTP）。

## 依赖

需要 curl、python3、openssl、iproute2，以及已安装的 3x-ui。
