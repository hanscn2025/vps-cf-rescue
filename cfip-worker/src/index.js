// cfip —— 在浏览器里给 Cloudflare 节点优选 IP 的网页
//
// GET  /           网页（测速、生成链接全部在用户浏览器里完成，节点信息不会发到服务器）
// GET  /pool.json  候选 IP 池（由 VPS 上的 cf-ip-pool.py 每天验证后推送）
// POST /pool       推送候选池，需要请求头 x-push-key = PUSH_KEY
//
// 变量：PUSH_KEY（secret）；KV 绑定：KV

import PAGE from "./page.html";

const ip4 = /^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}$/;

export default {
  async fetch(req, env) {
    const url = new URL(req.url);

    if (url.pathname === "/" && req.method === "GET") {
      return new Response(PAGE, {
        headers: {
          "content-type": "text/html; charset=utf-8",
          "cache-control": "no-cache",
          "x-content-type-options": "nosniff",
          "referrer-policy": "no-referrer",
          "content-security-policy":
            "default-src 'self'; script-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com; " +
            "style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self' https:; " +
            "frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
        },
      });
    }

    if (url.pathname === "/pool.json") {
      const p = await env.KV.get("pool");
      return new Response(p || '{"time":0,"ips":[]}', {
        headers: { "content-type": "application/json", "cache-control": "public, max-age=600" },
      });
    }

    if (url.pathname === "/pool" && req.method === "POST") {
      if (!env.PUSH_KEY || req.headers.get("x-push-key") !== env.PUSH_KEY)
        return new Response("forbidden", { status: 403 });
      const body = await req.json().catch(() => null);
      const ips = Array.isArray(body?.ips) ? [...new Set(body.ips.filter((x) => ip4.test(x)))] : [];
      if (ips.length < 10 || ips.length > 2000) return new Response("bad data", { status: 400 });
      await env.KV.put("pool", JSON.stringify({ time: Date.now(), ips }));
      return new Response(`ok ${ips.length}`);
    }

    return new Response("Not Found", { status: 404 });
  },
};
