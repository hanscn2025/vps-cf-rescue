// cf-sub —— Cloudflare 优选 IP 订阅（服务端）
//
// 测速由 VPS 上的 cf-sub-optimize.py 定时完成（Globalping 国内电信/联通/移动探针，
// 用 HTTPS 访问一批 Cloudflare IP，SNI/Host = 节点域名），结果推送到这里保存；
// 这里负责生成 v2rayN 等客户端可用的订阅：每个优选 IP 一个节点，最后附带一个直接用域名的保底节点。
// （测速不放在 Worker 里，是因为 Workers 的出口 IP 是共享的，Globalping 免登录额度经常被别人用光。）
//
// 需要的变量（wrangler secret put / dashboard 设置）：
//   TOKEN     订阅路径里的随机串（至少 16 位），访问 https://<域名>/<TOKEN> 看页面
//   PUSH_KEY  VPS 推送测速结果用的密钥
//   UUID      节点 UUID
//   XPATH     XHTTP 路径，例如 /3f9c2a7be1d04c58
//   HOST      节点域名，例如 edge.example.com
//   PORT      可选，默认 443
// KV 绑定：KV

const ISP = { ct: "电信", cu: "联通", cm: "移动" };
const KEEP = 3;          // 总榜保留几个；另外每家运营商再各取最快的一个

// 选出要放进订阅的节点：总榜前 KEEP 个 + 每家运营商最快的一个（去重）
function pick(list) {
  const chosen = [];
  const add = (x, tag) => { if (x && !chosen.some((c) => c.ip === x.ip)) chosen.push({ ...x, tag }); };
  list.slice(0, KEEP).forEach((x, i) => add(x, `优选${i + 1}`));
  for (const k of Object.keys(ISP)) {
    const best = list.filter((x) => x.isp[k] != null && x.isp[k] < 3000).sort((a, b) => a.isp[k] - b.isp[k])[0];
    add(best, ISP[k]);
  }
  return chosen;
}

function link(env, addr, name) {
  const q = new URLSearchParams({
    encryption: "none", security: "tls", sni: env.HOST, alpn: "h2,http/1.1", fp: "chrome",
    type: "xhttp", host: env.HOST, path: env.XPATH, mode: "auto",
  });
  return `vless://${env.UUID}@${addr}:${env.PORT || 443}?${q}#${encodeURIComponent(name)}`;
}

function b64(s) {
  const bytes = new TextEncoder().encode(s);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin);
}

function subscription(env, result) {
  const lines = pick(result?.list || []).map((x) =>
    link(env, x.ip, `CF-${x.tag} ${x.ip} ${x.tag in ISP ? x.isp[x.tag] : x.ms}ms`));
  lines.push(link(env, env.HOST, "CF-域名直连(保底)"));
  return lines.join("\n");
}

const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

function page(env, result, origin) {
  const subUrl = `${origin}/${env.TOKEN}/sub`;
  const t = result ? new Date(result.time).toLocaleString("zh-CN", { timeZone: "Asia/Shanghai" }) : "还没有测过";
  const fmt = (v) => (v == null ? "–" : v >= 3000 ? "不通" : v + " ms");
  const rows = (result?.list || []).slice(0, 10).map((x) => `<tr><td>${esc(x.ip)}</td><td>${fmt(x.ms)}</td>` +
    Object.keys(ISP).map((k) => `<td>${fmt(x.isp[k])}</td>`).join("") + `<td>${x.ok}/${x.tot}</td></tr>`).join("");
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex">
<title>CF 优选订阅</title>
<style>
:root{--bg:#f7f7f5;--fg:#1d1d1b;--mute:#6b6b66;--card:#fff;--line:#e4e4df;--acc:#2563eb}
@media (prefers-color-scheme:dark){:root{--bg:#161615;--fg:#ececea;--mute:#9a9a94;--card:#1f1f1d;--line:#33332f;--acc:#6ea0ff}}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.6 -apple-system,"PingFang SC",system-ui,sans-serif}
main{max-width:720px;margin:0 auto;padding:24px 16px}
h1{font-size:22px;margin:0 0 4px}.mute{color:var(--mute);font-size:13px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px;margin:16px 0}
.row{display:flex;gap:8px;flex-wrap:wrap}
input{flex:1;min-width:0;font:13px ui-monospace,monospace;padding:8px;border:1px solid var(--line);border-radius:8px;background:var(--bg);color:var(--fg)}
button{font:inherit;padding:8px 14px;border:0;border-radius:8px;background:var(--acc);color:#fff;cursor:pointer}
button:disabled{opacity:.5}
table{width:100%;border-collapse:collapse;font-size:13px}td,th{padding:6px 4px;border-bottom:1px solid var(--line);text-align:left}
.tw{overflow-x:auto}#qr{background:#fff;padding:8px;display:inline-block;border-radius:8px;margin-top:12px}
ol{padding-left:20px;margin:8px 0}
</style></head><body><main>
<h1>CF 优选订阅</h1><div class="mute">节点 ${esc(env.HOST)} · 上次优选：${esc(t)}${result?.note ? " · " + esc(result.note) : ""}</div>
<div class="card"><b>订阅地址</b>（只给自己用，不要外传）
<div class="row" style="margin-top:8px"><input id="u" readonly value="${esc(subUrl)}"><button onclick="navigator.clipboard.writeText(u.value).then(()=>this.textContent='已复制')">复制</button></div>
<div id="qr"></div>
<ol class="mute"><li>v2rayN：订阅分组 → 订阅分组设置 → 添加，粘贴上面的地址，填一个“自动更新间隔”（比如 360 分钟）</li>
<li>订阅分组 → 更新全部订阅，然后测速，选延迟最低的节点用</li>
<li>VLESS 内核要用 Xray（设置 → 参数设置 → Core 类型设置）</li></ol></div>
<div class="card"><b>当前测速结果</b>
<div class="mute">VPS 每 6 小时自动测一次。数据来自国内电信/联通/移动的测试点，是一次 HTTPS 访问的总耗时（越小越好）。</div>
<div class="tw"><table><tr><th>IP</th><th>中位</th><th>电信</th><th>联通</th><th>移动</th><th>可用</th></tr>${rows || '<tr><td colspan="6" class="mute">暂无数据，等 VPS 第一次测速完成</td></tr>'}</table></div></div>
</main>
<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
<script>
try{new QRCode(document.getElementById("qr"),{text:${JSON.stringify(subUrl)},width:180,height:180})}catch(e){}
</script></body></html>`;
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    const parts = url.pathname.split("/").filter(Boolean);
    if (!env.TOKEN || env.TOKEN.length < 16 || parts[0] !== env.TOKEN) return new Response("Not Found", { status: 404 });
    const result = await env.KV.get("result", "json");

    if (parts.length === 1) {
      return new Response(page(env, result, url.origin), {
        headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
    }
    if (parts[1] === "sub") {
      return new Response(b64(subscription(env, result)), {
        headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store",
          "profile-update-interval": "6" } });
    }
    if (parts[1] === "push" && req.method === "POST") {
      if (!env.PUSH_KEY || req.headers.get("x-push-key") !== env.PUSH_KEY) return new Response("forbidden", { status: 403 });
      const body = await req.json().catch(() => null);
      const ip4 = /^\d{1,3}(\.\d{1,3}){3}$/;
      if (!body || !Array.isArray(body.list) || body.list.length > 50 ||
          !body.list.every((x) => ip4.test(x.ip) && Number.isFinite(x.ms) && typeof x.isp === "object"))
        return new Response("bad data", { status: 400 });
      const clean = {
        time: Date.now(), tested: +body.tested || 0, note: String(body.note || "").slice(0, 100),
        list: body.list.map((x) => ({ ip: x.ip, ms: +x.ms, ok: +x.ok || 0, tot: +x.tot || 0,
          isp: Object.fromEntries(Object.keys(ISP).filter((k) => Number.isFinite(x.isp[k])).map((k) => [k, +x.isp[k]])) })),
      };
      await env.KV.put("result", JSON.stringify(clean));
      return new Response("ok");
    }
    if (parts[1] === "last" && req.method === "GET") {
      return Response.json(result || { list: [] }, { headers: { "cache-control": "no-store" } });
    }
    return new Response("Not Found", { status: 404 });
  },
};
