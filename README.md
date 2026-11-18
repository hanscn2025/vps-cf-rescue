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

## 可选：IP 优选订阅（sub-worker + cf-sub-optimize.py）

通过 Cloudflare 连接时，默认分到的 IP 不一定快。这部分做的是：VPS 每 6 小时调用 Globalping，用国内电信、联通、移动的探针测一批 Cloudflare IP，选出又通又快的几个，推送到一个 Cloudflare Worker。Worker 把它们做成订阅，v2rayN 添加一次订阅、开启自动更新，以后就不用手动改 IP 了。

VPS 的 IP 被墙不影响测速：VPS 只是调用海外的 Globalping API，真正测速的是国内探针。

**1. 部署 Worker**（在自己电脑上，需要 Node.js）

```bash
cd sub-worker
npm install
npx wrangler login
npx wrangler kv namespace create cf-sub-kv
```

- 把上一步输出的 id 填进 `wrangler.toml`。
- `HOST` 改成你的节点域名。
- 取消 `routes` 那行的注释，改成你的订阅域名（例如 `sub.example.com`）。workers.dev 域名在国内基本打不开。

然后设置密钥并部署：

```bash
npx wrangler secret put TOKEN      # 随机串，至少 16 位，就是订阅地址里的路径
npx wrangler secret put PUSH_KEY   # 随机串，VPS 推送用
npx wrangler secret put UUID       # 节点 UUID
npx wrangler secret put XPATH      # 节点 XHTTP 路径，例如 /3f9c2a7be1d04c58
npx wrangler deploy
```

**2. 在 VPS 上安装测速脚本**

```bash
curl -fsSL https://raw.githubusercontent.com/hanscn2025/vps-cf-rescue/main/cf-sub-optimize.py -o /root/cf-sub-optimize.py
```

创建配置文件，三项分别改成你的订阅域名和 TOKEN、PUSH_KEY、节点域名：

```bash
cat > /root/.cf-sub.env <<'CONF'
SUB_URL=https://sub.example.com/<TOKEN>
PUSH_KEY=<PUSH_KEY>
HOST=edge.example.com
CONF
chmod 600 /root/.cf-sub.env
```

手动运行一次，确认能测出可用 IP：

```bash
python3 /root/cf-sub-optimize.py -v
```

加定时任务，每 6 小时运行一次：

```bash
echo "17 */6 * * * root /usr/bin/python3 /root/cf-sub-optimize.py >> /var/log/cf-sub.log 2>&1" > /etc/cron.d/cf-sub
```

**3. 在客户端里添加订阅**

浏览器打开 `https://sub.example.com/<TOKEN>`，页面上有订阅地址和二维码。在 v2rayN 里：订阅分组 → 添加，粘贴订阅地址，设置自动更新间隔。
