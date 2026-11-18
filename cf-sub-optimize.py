#!/usr/bin/env python3
"""cf-sub-optimize.py —— 给 Cloudflare 节点做 IP 优选，把结果推送给 cf-sub Worker。

在 VPS 上由 cron 定时运行（VPS 的 IP 被墙也没关系：这里只是调用海外的 Globalping API，
真正的测速是 Globalping 在国内的电信/联通/移动探针去访问 Cloudflare IP）。

配置文件 /root/.cf-sub.env（chmod 600）：
    SUB_URL=https://sub.example.com/<TOKEN>
    PUSH_KEY=<推送密钥>
    HOST=edge.example.com
手动运行：python3 cf-sub-optimize.py      加 -v 打印每个 IP 的结果
"""
import json, os, random, sys, time, urllib.request, urllib.error

GP = "https://api.globalping.io/v1/measurements"
# Cloudflare 公开 IPv4 段里常用于普通网站的部分；段内有空洞，测试时会自动剔除不能用的 IP
RANGES = ["104.16.0.0/13", "104.24.0.0/14", "172.64.0.0/13", "188.114.96.0/20",
          "190.93.240.0/20", "173.245.48.0/20", "141.101.64.0/18", "108.162.192.0/18"]
ASN = {4134: "ct", 4812: "ct", 4809: "ct", 4837: "cu", 17621: "cu", 17816: "cu", 4808: "cu",
       9929: "cu", 9808: "cm", 56040: "cm", 56041: "cm", 56042: "cm", 56044: "cm", 56046: "cm", 24400: "cm"}
PROBES = [{"asn": 4134, "limit": 2}, {"asn": 4837, "limit": 2}, {"asn": 9808, "limit": 2}]
CANDIDATES = 20   # 每次测多少个 IP。每个 IP 用 6 个探针，免登录额度每小时 250 次
KEEP_PREV = 8     # 上次的前几名继续参加本次测试，结果更稳定
FAIL = 3000       # 失败记为 3000ms
UA = "cf-sub-optimize/1.0"
VERBOSE = "-v" in sys.argv


def log(*a):
    print(time.strftime("%F %T"), *a, flush=True)


def load_env(path="/root/.cf-sub.env"):
    env = {}
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip("'\"")
    for k in ("SUB_URL", "PUSH_KEY", "HOST"):
        env[k] = os.environ.get(k, env.get(k, ""))
        if not env[k]:
            sys.exit(f"缺少 {k}，请写进 {path}")
    env["SUB_URL"] = env["SUB_URL"].rstrip("/")
    return env


def http(method, url, data=None, headers=None, timeout=30):
    h = {"user-agent": UA, **(headers or {})}
    body = None
    if data is not None:
        body = json.dumps(data).encode()
        h["content-type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")
    except Exception as e:
        return 0, str(e)


def rand_ip(cidr):
    base, bits = cidr.split("/")
    b = 0
    for x in base.split("."):
        b = b * 256 + int(x)
    while True:
        n = b + random.randrange(2 ** (32 - int(bits)))
        if n % 256 not in (0, 255):
            return ".".join(str((n >> s) & 255) for s in (24, 16, 8, 0))


def median(a):
    s = sorted(a)
    return s[len(s) // 2] if s else None


def summarize(ip, host, d):
    allv, by = [], {}
    for r in d.get("results", []):
        x = r.get("result", {})
        if x.get("status") == "in-progress":
            continue
        good = x.get("statusCode") == 200 and ("h=" + host) in (x.get("rawBody") or "")
        ms = (x.get("timings") or {}).get("total") if good else None
        v = FAIL if ms is None else ms
        allv.append(v)
        k = ASN.get((r.get("probe") or {}).get("asn"))
        if k:
            by.setdefault(k, []).append(v)
    return {"ip": ip, "ms": round(median(allv) or FAIL), "ok": sum(v < FAIL for v in allv),
            "tot": len(allv), "isp": {k: round(median(v)) for k, v in by.items()}}


def main():
    env = load_env()
    host = env["HOST"]

    st, body = http("GET", env["SUB_URL"] + "/last")
    prev = json.loads(body).get("list", []) if st == 200 else []
    cands = [x["ip"] for x in prev[:KEEP_PREV]]
    while len(cands) < CANDIDATES:
        ip = rand_ip(random.choice(RANGES))
        if ip not in cands:
            cands.append(ip)

    ids, errs = [], []
    for ip in cands:
        st, body = http("POST", GP, {
            "type": "http", "target": ip, "locations": PROBES,
            "measurementOptions": {"protocol": "HTTPS",
                                   "request": {"host": host, "path": "/cdn-cgi/trace", "method": "GET"}}})
        if st in (200, 202):
            ids.append((ip, json.loads(body)["id"]))
        else:
            errs.append(f"{st} {body[:100]}")
    if not ids:
        log("Globalping 拒绝了全部请求：", errs[:1])
        sys.exit(1)
    if errs:
        log(f"{len(errs)} 个请求被拒绝（可能是额度不够）：", errs[0])

    time.sleep(12)
    out, pending = [], ids
    for rnd in range(3):
        nxt = []
        for ip, mid in pending:
            st, body = http("GET", f"{GP}/{mid}")
            if st != 200:
                continue
            d = json.loads(body)
            if d.get("status") != "finished" and rnd < 2:
                nxt.append((ip, mid))
                continue
            out.append(summarize(ip, host, d))
        pending = nxt
        if pending:
            time.sleep(8)

    # 至少一半探针拿到正确响应、且中位数不是超时，才算可用
    usable = sorted((x for x in out if x["tot"] and x["ok"] * 2 >= x["tot"] and x["ms"] < FAIL),
                    key=lambda x: x["ms"])
    if VERBOSE:
        for x in sorted(out, key=lambda x: x["ms"]):
            print(f"  {x['ip']:<16} {x['ms']:>5}ms  可用 {x['ok']}/{x['tot']}  {x['isp']}")
    log(f"测了 {len(out)} 个 IP，可用 {len(usable)} 个" +
        (f"，最快 {usable[0]['ip']} {usable[0]['ms']}ms" if usable else ""))
    if not usable:
        log("没有可用 IP，保留上次结果，不推送")
        sys.exit(1)

    st, body = http("POST", env["SUB_URL"] + "/push",
                    {"tested": len(out), "list": usable[:20]}, {"x-push-key": env["PUSH_KEY"]})
    if st != 200:
        log("推送失败：", st, body[:200])
        sys.exit(1)
    log("已推送到订阅服务")


if __name__ == "__main__":
    main()
