#!/usr/bin/env python3
"""cf-ip-pool.py —— 生成「可用的 Cloudflare IP」候选池，推送给 cfip 网页。

Cloudflare 的 IP 段里有不少地址并不转发普通网站。这个脚本在 VPS（海外）上随机抽一批
Cloudflare IP，逐个用 HTTPS（SNI/Host = 你的一个走 Cloudflare 的域名）访问 /cdn-cgi/trace，
返回内容正确的才进候选池。网页再从候选池里，在每个用户自己的网络上测速。

配置文件 /root/.cfip.env（chmod 600）：
    CFIP_URL=https://cfip.example.com
    PUSH_KEY=<推送密钥>
    HOST=edge.example.com        # 任意一个已开启橙色云的域名，用来验证
用法：python3 cf-ip-pool.py [-v]
"""
import ipaddress, json, os, random, socket, ssl, sys, time, urllib.request
from concurrent.futures import ThreadPoolExecutor

SAMPLE = 1500      # 每次抽多少个 IP 去验证
MAX_PER_24 = 2     # 同一个 /24 最多留几个，保证多样性
MAX_POOL = 800     # 推送上限
FALLBACK = ["173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22", "141.101.64.0/18",
            "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20", "197.234.240.0/22", "198.41.128.0/17",
            "162.158.0.0/15", "104.16.0.0/13", "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22"]
VERBOSE = "-v" in sys.argv


def log(*a):
    print(time.strftime("%F %T"), *a, flush=True)


def load_env(path="/root/.cfip.env"):
    env = {}
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip("'\"")
    for k in ("CFIP_URL", "PUSH_KEY", "HOST"):
        env[k] = os.environ.get(k, env.get(k, ""))
        if not env[k]:
            sys.exit(f"缺少 {k}，请写进 {path}")
    env["CFIP_URL"] = env["CFIP_URL"].rstrip("/")
    return env


def ranges():
    try:
        with urllib.request.urlopen("https://www.cloudflare.com/ips-v4", timeout=15) as r:
            got = [l.strip() for l in r.read().decode().split() if "/" in l]
            if got:
                return got
    except Exception:
        pass
    return FALLBACK


def sample(nets, n):
    nets = [ipaddress.ip_network(c) for c in nets]
    weights = [min(net.num_addresses, 2 ** 16) for net in nets]  # 大段多抽，但不至于全抽大段
    out = set()
    while len(out) < n:
        net = random.choices(nets, weights)[0]
        ip = net.network_address + random.randrange(net.num_addresses)
        if int(ip) % 256 not in (0, 255):
            out.add(str(ip))
    return list(out)


CTX = ssl.create_default_context()


def check(ip, host):
    try:
        with socket.create_connection((ip, 443), timeout=4) as s:
            with CTX.wrap_socket(s, server_hostname=host) as t:
                t.settimeout(4)
                t.sendall(f"GET /cdn-cgi/trace HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode())
                data = b""
                while len(data) < 4096:
                    chunk = t.recv(2048)
                    if not chunk:
                        break
                    data += chunk
        return ("h=" + host).encode() in data
    except Exception:
        return False


def main():
    env = load_env()
    cands = sample(ranges(), SAMPLE)
    t0 = time.time()
    with ThreadPoolExecutor(64) as ex:
        ok = [ip for ip, good in zip(cands, ex.map(lambda i: check(i, env["HOST"]), cands)) if good]
    random.shuffle(ok)
    per24, pool = {}, []
    for ip in ok:
        k = ip.rsplit(".", 1)[0]
        if per24.get(k, 0) < MAX_PER_24:
            per24[k] = per24.get(k, 0) + 1
            pool.append(ip)
    pool = pool[:MAX_POOL]
    log(f"验证 {len(cands)} 个 IP，用时 {time.time() - t0:.0f}s，可用 {len(ok)} 个，入池 {len(pool)} 个")
    if VERBOSE:
        print("  例：", pool[:10])
    if len(pool) < 50:
        log("可用 IP 太少，不推送（检查 HOST 是否开了橙色云）")
        sys.exit(1)

    req = urllib.request.Request(env["CFIP_URL"] + "/pool", data=json.dumps({"ips": pool}).encode(),
                                 headers={"content-type": "application/json", "x-push-key": env["PUSH_KEY"],
                                          "user-agent": "cf-ip-pool/1.0"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            log("已推送：", r.read().decode()[:100])
    except Exception as e:
        log("推送失败：", e)
        sys.exit(1)


if __name__ == "__main__":
    main()
