#!/usr/bin/env bash
# cf-proxy.sh —— IP 被墙后，一键让节点和网站改走 Cloudflare
#
# 在 VPS 上以 root 运行：
#   bash cf-proxy.sh                          # 菜单
#   bash cf-proxy.sh node edge.example.com    # 新建一个走 Cloudflare 的 3x-ui 节点（VLESS + XHTTP + TLS）
#   bash cf-proxy.sh site www.example.com ... # 让已有网站改走 Cloudflare（橙色云）
#
# 两种用法：
#   半自动（默认，什么都不用准备）：脚本只问 3x-ui 面板的用户名和密码；
#       Cloudflare 上的两步（加 DNS、设 SSL）脚本会告诉你点哪里，你在网页上点完按回车。
#   全自动（可选）：再提供一个 Cloudflare API Token，Cloudflare 上的事也由脚本完成。
#       Token 在 Cloudflare → My Profile → API Tokens → Create Token → Custom token 创建，权限：
#         Zone·Zone·Read、Zone·DNS·Edit、Zone·SSL and Certificates·Edit、Zone·Config Rules·Edit
#
# 可以用环境变量免去输入：XUI_USER + XUI_PASS（或 XUI_TOKEN）、CF_API_TOKEN。
# 不需要 Caddy / Nginx：节点由 xray 直接处理 TLS。

set -uo pipefail

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; NC=$'\033[0m'
die()  { echo "${RED}错误：$*${NC}" >&2; exit 1; }
ok()   { echo "  ${GREEN}✓${NC} $*"; }
warn() { echo "  ${YELLOW}!${NC} $*"; }
step() { echo; echo "${BOLD}$*${NC}"; }

[[ $EUID -eq 0 ]] || die "请用 root 运行（sudo -i 后再执行）"
for c in curl python3 openssl ss; do command -v $c >/dev/null || die "缺少 $c，先安装：apt install -y curl python3 openssl iproute2"; done

CF_API=https://api.cloudflare.com/client/v4
CF_PORTS=(443 2053 2083 2087 2096 8443)   # Cloudflare 代理支持的 HTTPS 端口
CERT_DIR=/etc/x-ui/cert
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# 从 stdin 的 JSON 里取值：jget '表达式'，d 是解析后的对象
jget() { python3 -c 'import sys,json
d=json.load(sys.stdin)
v=eval(sys.argv[1])
print("" if v is None else (json.dumps(v) if isinstance(v,(dict,list)) else v))' "$1" 2>/dev/null; }

public_ip() {
  local ip u
  for u in https://api.ipify.org https://ifconfig.me/ip https://ipv4.icanhazip.com; do
    ip=$(curl -4 -s -m 8 "$u" | tr -d '[:space:]')
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return; }
  done
}

# ================= Cloudflare =================
cf() { # cf METHOD PATH [JSON]
  local args=(-s -m 30 -X "$1" "$CF_API$2" -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json")
  [[ -n "${3:-}" ]] && args+=(--data "$3")
  curl "${args[@]}"
}
cf_ok() { jget 'd.get("success")' | grep -q True; }
cf_err() { jget '"; ".join(e.get("message","") for e in d.get("errors",[]))'; }

# 决定 Cloudflare 那部分走全自动还是半自动：设置 CF_MODE=auto|manual
CF_MODE=manual
cf_login() {
  if [[ -z "${CF_API_TOKEN:-}" && -f /root/.cf-proxy.env ]]; then . /root/.cf-proxy.env; fi
  if [[ -z "${CF_API_TOKEN:-}" && -t 0 ]]; then
    echo "  有 Cloudflare API Token 的话粘贴进来，Cloudflare 上的设置也自动完成；"
    read -rsp "  没有就直接按回车（半自动：稍后按提示在网页上点两下）：" CF_API_TOKEN; echo
  fi
  if [[ -z "${CF_API_TOKEN:-}" ]]; then ok "Cloudflare 部分：半自动（稍后告诉你在网页上点哪里）"; return; fi
  if ! cf GET /user/tokens/verify | cf_ok; then
    warn "Cloudflare Token 无效或已过期，改为半自动"; CF_API_TOKEN=""; return
  fi
  CF_MODE=auto; ok "Cloudflare 部分：全自动（Token 有效）"
  if [[ ! -f /root/.cf-proxy.env && -t 0 ]]; then
    read -rp "  把 Token 存到 /root/.cf-proxy.env，下次免输入？[y/N] " a
    [[ "$a" =~ ^[Yy]$ ]] && { umask 077; echo "CF_API_TOKEN='$CF_API_TOKEN'" > /root/.cf-proxy.env; ok "已保存（仅 root 可读）"; }
  fi
}

wait_user() { # 半自动：等用户在网页上做完
  if [[ -t 0 ]]; then read -rp "  在网页上做完后按回车继续……" _
  else echo "  （非交互运行：不等待，直接进入验证，最多等 5 分钟）"; fi
}

self_signed_cert() { # 半自动用：本机生成 10 年自签证书（Cloudflare SSL 设为「完全」即可接受）
  local host=$1 crt="$CERT_DIR/$host.crt" key="$CERT_DIR/$host.key"
  mkdir -p "$CERT_DIR"; chmod 700 "$CERT_DIR"
  if [[ -s "$crt" && -s "$key" ]] && openssl x509 -in "$crt" -noout -checkend 2592000 >/dev/null 2>&1; then
    ok "已有证书：$crt（继续使用）"; return
  fi
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$host" \
    -addext "subjectAltName=DNS:$host" -keyout "$key" -out "$crt" >/dev/null 2>&1 || die "openssl 生成证书失败"
  chmod 600 "$key"
  ok "已生成自签证书（10 年）：$crt"
}

ssl_name() { case $1 in strict) echo "完全（严格）";; full) echo "完全";; flexible) echo "灵活";; esac; }

manual_cf_steps() { # manual_cf_steps HOST IP(为空=已有记录) MODE
  local host=$1 ip=$2 mode=$3
  echo
  echo "  ${BOLD}请打开 https://dash.cloudflare.com ，点进你的域名，完成下面两步：${NC}"
  if [[ -n "$ip" ]]; then
    echo "  ① 左侧「DNS」→「记录」→「添加记录」"
    echo "       类型：A    名称：${BOLD}$host${NC}    IPv4 地址：${BOLD}$ip${NC}"
    echo "       代理状态：打开（橙色云，显示「已代理」）→ 保存"
  else
    echo "  ① 左侧「DNS」→「记录」，找到 ${BOLD}$host${NC} 那一行 →「编辑」"
    echo "       把代理状态从灰色「仅 DNS」拨成橙色「已代理」→ 保存"
  fi
  echo "  ② 左侧「规则」→「概述」→ Configuration Rules 一栏点「创建规则」"
  echo "       规则名称：随便填，比如 ${BOLD}$host SSL${NC}"
  echo "       点「编辑表达式」，填：${BOLD}http.host eq \"$host\"${NC}"
  echo "       往下找到「SSL」→「+ 添加」→ 选 ${BOLD}$(ssl_name "$mode")${NC} →「部署」"
  echo "     （如果「SSL/TLS → 概述」里整个域名已经是「$(ssl_name "$mode")」，第②步可以跳过）"
  echo
  wait_user
}

cf_zone() { # 找出主机名所属的 Zone，输出 zone_id
  local host=$1 name=$1 id
  while [[ "$name" == *.* ]]; do
    id=$(cf GET "/zones?name=$name" | jget 'd["result"][0]["id"] if d.get("result") else ""')
    [[ -n "$id" ]] && { echo "$id"; return; }
    name=${name#*.}
  done
  die "在这个 Cloudflare 账号里找不到 $host 所属的域名（检查 Token 的 Zone Resources 是否包含它）"
}

# 设置 DNS：cf_dns ZONE HOST IP(为空则保留原记录内容)
cf_dns() {
  local z=$1 host=$2 ip=$3 rec id type content
  rec=$(cf GET "/zones/$z/dns_records?name=$host")
  id=$(echo "$rec" | jget 'next((r["id"] for r in d["result"] if r["type"] in ("A","AAAA","CNAME")),"")')
  type=$(echo "$rec" | jget 'next((r["type"] for r in d["result"] if r["type"] in ("A","AAAA","CNAME")),"")')
  content=$(echo "$rec" | jget 'next((r["content"] for r in d["result"] if r["type"] in ("A","AAAA","CNAME")),"")')
  if [[ -z "$id" ]]; then
    [[ -n "$ip" ]] || die "$host 没有 DNS 记录"
    cf POST "/zones/$z/dns_records" "{\"type\":\"A\",\"name\":\"$host\",\"content\":\"$ip\",\"proxied\":true,\"ttl\":1}" > "$TMP/r"
    cf_ok < "$TMP/r" || die "添加 DNS 记录失败：$(cf_err < "$TMP/r")"
    ok "已添加 DNS：$host → $ip（已代理，橙色云）"
  else
    local body="{\"proxied\":true}"
    [[ -n "$ip" && "$type" == A && "$content" != "$ip" ]] && body="{\"content\":\"$ip\",\"proxied\":true}"
    cf PATCH "/zones/$z/dns_records/$id" "$body" > "$TMP/r"
    cf_ok < "$TMP/r" || die "修改 DNS 记录失败：$(cf_err < "$TMP/r")"
    ok "DNS：$host（$type → ${ip:-$content}）已改为「已代理」"
  fi
}

# 为单个主机名设置 SSL 模式（Configuration Rule），保留已有规则：cf_ssl_rule ZONE HOST MODE(strict|full|flexible)
cf_ssl_rule() {
  local z=$1 host=$2 mode=$3 cur body
  cur=$(cf GET "/zones/$z/rulesets/phases/http_config_settings/entrypoint")
  body=$(echo "$cur" | HOST="$host" MODE="$mode" python3 -c '
import sys,json,os
d=json.load(sys.stdin); host=os.environ["HOST"]; mode=os.environ["MODE"]
desc="cf-proxy: "+host
rules=(d.get("result") or {}).get("rules",[]) if d.get("success") else []
keep=[]
for r in rules:
    if r.get("description")==desc: continue
    keep.append({k:r[k] for k in ("id","ref","expression","action","action_parameters","description","enabled") if k in r})
keep.append({"expression":"http.host eq \"%s\""%host,"action":"set_config","action_parameters":{"ssl":mode},"description":desc,"enabled":True})
print(json.dumps({"rules":keep}))')
  cf PUT "/zones/$z/rulesets/phases/http_config_settings/entrypoint" "$body" > "$TMP/r"
  cf_ok < "$TMP/r" || die "设置 SSL 规则失败：$(cf_err < "$TMP/r")（Token 需要 Zone.Config Rules 编辑权限）"
  local name; case $mode in strict) name="完全（严格）";; full) name="完全";; flexible) name="灵活";; esac
  ok "SSL 规则：$host 使用「$name」"
}

cf_origin_cert() { # 申请 15 年源服务器证书，写到 $CERT_DIR/HOST.crt/.key
  local z=$1 host=$2 crt="$CERT_DIR/$host.crt" key="$CERT_DIR/$host.key"
  mkdir -p "$CERT_DIR"; chmod 700 "$CERT_DIR"
  if [[ -s "$crt" && -s "$key" ]] && openssl x509 -in "$crt" -noout -checkend 2592000 >/dev/null 2>&1; then
    ok "已有源服务器证书：$crt（继续使用）"; return
  fi
  openssl req -new -newkey rsa:2048 -nodes -keyout "$key" -subj "/CN=$host" -out "$TMP/csr" >/dev/null 2>&1 || die "openssl 生成 CSR 失败"
  chmod 600 "$key"
  local body; body=$(CSR="$TMP/csr" HOST="$host" python3 -c 'import json,os;print(json.dumps({"hostnames":[os.environ["HOST"]],"requested_validity":5475,"request_type":"origin-rsa","csr":open(os.environ["CSR"]).read()}))')
  cf POST /certificates "$body" > "$TMP/r"
  cf_ok < "$TMP/r" || die "申请源服务器证书失败：$(cf_err < "$TMP/r")（Token 需要 Zone.SSL and Certificates 编辑权限）"
  jget 'd["result"]["certificate"]' < "$TMP/r" > "$crt"
  ok "已申请源服务器证书（有效期 15 年）：$crt"
}

# ================= 3x-ui =================
XUI_BASE=""; XUI_AUTH=()
xui_detect() {
  local bin=/usr/local/x-ui/x-ui info port path scheme
  [[ -x $bin ]] || die "没找到 3x-ui（/usr/local/x-ui/x-ui），请先安装 3x-ui"
  systemctl is-active --quiet x-ui || die "x-ui 服务没在运行：systemctl restart x-ui"
  info=$($bin setting -show 2>/dev/null)
  port=$(echo "$info" | sed -nE 's/^port: *([0-9]+).*/\1/p')
  path=$(echo "$info" | sed -nE 's/^webBasePath: *(.*)$/\1/p')
  [[ -n "$port" ]] || die "读不到面板端口"
  [[ "$path" == /* ]] || path="/$path"; [[ "$path" == */ ]] || path="$path/"
  scheme=http; echo "$info" | grep -qi "secure with SSL" && scheme=https
  XUI_BASE="$scheme://127.0.0.1:$port$path"
}
xui() { # xui METHOD PATH [JSON]
  local args=(-sk -m 30 -X "$1" "$XUI_BASE$2" -H "Accept: application/json" "${XUI_AUTH[@]}")
  [[ -n "${3:-}" ]] && args+=(-H "Content-Type: application/json" --data "$3")
  curl "${args[@]}"
}
xui_login() {
  xui_detect
  if [[ -z "${XUI_TOKEN:-}" && -z "${XUI_USER:-}" ]]; then
    echo "  用 3x-ui 面板的账号登录（就是你平时登录面板用的那组）："
  fi
  if [[ -n "${XUI_TOKEN:-}" ]]; then
    XUI_AUTH=(-H "Authorization: Bearer $XUI_TOKEN")
  else
    [[ -n "${XUI_USER:-}" ]] || read -rp "  面板用户名：" XUI_USER
    [[ -n "${XUI_PASS:-}" ]] || { read -rsp "  面板密码（输入不显示）：" XUI_PASS; echo; }
    curl -sk -m 15 -c "$TMP/jar" --data-urlencode "username=$XUI_USER" --data-urlencode "password=$XUI_PASS" "${XUI_BASE}login" > "$TMP/r"
    jget 'd.get("success")' < "$TMP/r" | grep -q True || die "面板登录失败：$(jget 'd.get("msg")' < "$TMP/r")"
    XUI_AUTH=(-b "$TMP/jar")
  fi
  xui GET panel/api/inbounds/list > "$TMP/inb"
  jget 'd.get("success")' < "$TMP/inb" | grep -q True || die "调用面板 API 失败（Token 或密码不对？）"
  ok "已连上 3x-ui 面板（$XUI_BASE）"
}

pick_port() { # 选一个 Cloudflare 支持、本机空闲、面板里也没用的端口
  local used p; used=$(jget '" ".join(str(i["port"]) for i in d.get("obj") or [])' < "$TMP/inb")
  for p in "${CF_PORTS[@]}"; do
    [[ " $used " == *" $p "* ]] && continue
    [[ -n "$(ss -tlnH "sport = :$p")" ]] && continue
    echo "$p"; return
  done
}

open_firewall() {
  local p=$1
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$p/tcp" >/dev/null && ok "ufw 已放行 $p/tcp"
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$p/tcp" >/dev/null && firewall-cmd --reload >/dev/null && ok "firewalld 已放行 $p/tcp"
  fi
  warn "如果服务商有「安全组 / 防火墙」网页设置，也要放行 TCP $p"
}

xray_e2e() { # 用临时 xray 客户端，经 Cloudflare 连一次新节点
  local host=$1 port=$2 uuid=$3 path=$4 bin
  bin=$(ls /usr/local/x-ui/bin/xray-linux-* 2>/dev/null | head -1)
  [[ -x "$bin" ]] || { warn "找不到 xray 程序，跳过端到端测试"; return 1; }
  cat > "$TMP/c.json" <<EOF
{"log":{"loglevel":"none"},"inbounds":[{"listen":"127.0.0.1","port":10899,"protocol":"socks","settings":{"udp":false}}],
"outbounds":[{"protocol":"vless","settings":{"vnext":[{"address":"$host","port":$port,"users":[{"id":"$uuid","encryption":"none"}]}]},
"streamSettings":{"network":"xhttp","security":"tls","tlsSettings":{"serverName":"$host","fingerprint":"chrome","alpn":["h2","http/1.1"]},"xhttpSettings":{"path":"$path","mode":"auto"}}}]}
EOF
  "$bin" run -c "$TMP/c.json" >/dev/null 2>&1 & local pid=$!
  sleep 2
  local trace; trace=$(curl -s -m 20 -x socks5h://127.0.0.1:10899 https://www.cloudflare.com/cdn-cgi/trace)
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  if echo "$trace" | grep -q '^colo='; then
    ok "端到端测试通过：经 Cloudflare $(echo "$trace" | sed -n 's/^colo=//p') 机房，出口 IP $(echo "$trace" | sed -n 's/^ip=//p')"
    return 0
  fi
  return 1
}

# ================= 新建节点 =================
do_node() {
  local host=${1:-}
  [[ -n "$host" ]] || read -rp "节点用的子域名（例如 edge.example.com，不能是已有网站的域名）：" host
  [[ "$host" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "域名格式不对：$host"

  step "[1/6] 检查环境"
  local ip; ip=$(public_ip); [[ -n "$ip" ]] || die "取不到本机公网 IP"
  ok "本机公网 IP：$ip"
  xui_login
  cf_login; local z=""
  if [[ $CF_MODE == auto ]]; then z=$(cf_zone "$host") || exit 1; ok "Cloudflare 里找到了 $host 所属的域名"; fi
  jget '[i["remark"] for i in d.get("obj") or []]' < "$TMP/inb" | grep -q "\"cf-$host\"" && die "面板里已经有名为 cf-$host 的入站，如需重建请先在面板删除它"
  local port; port=$(pick_port); [[ -n "$port" ]] || die "Cloudflare 支持的端口（${CF_PORTS[*]}）都被占用了"
  ok "节点端口：$port$([[ $port != 443 ]] && echo "（443 已被占用，改用 Cloudflare 支持的 $port）")"

  step "[2/6] 准备 TLS 证书"
  local sslmode
  if [[ $CF_MODE == auto ]]; then cf_origin_cert "$z" "$host"; sslmode=strict
  else self_signed_cert "$host"; sslmode=full; fi

  step "[3/6] 在 3x-ui 新建入站（VLESS + XHTTP + TLS）"
  local uuid path email sub
  uuid=$(python3 -c 'import uuid;print(uuid.uuid4())')
  path="/$(openssl rand -hex 8)"; email="cf-$(openssl rand -hex 4)"; sub=$(openssl rand -hex 8)
  local payload; payload=$(HOST="$host" PORT="$port" UUID="$uuid" XPATH="$path" EMAIL="$email" SUB="$sub" CRT="$CERT_DIR/$host.crt" KEY="$CERT_DIR/$host.key" python3 -c '
import json,os,time
e=os.environ; port=int(e["PORT"]); now=int(time.time()*1000)
settings={"clients":[{"id":e["UUID"],"flow":"","email":e["EMAIL"],"limitIp":0,"totalGB":0,"expiryTime":0,"enable":True,"tgId":"","subId":e["SUB"],"comment":"","reset":0,"created_at":now,"updated_at":now}],"decryption":"none","fallbacks":[]}
stream={"network":"xhttp","security":"tls",
 "externalProxy":[{"forceTls":"same","dest":e["HOST"],"port":port,"remark":""}],
 "tlsSettings":{"serverName":e["HOST"],"minVersion":"1.2","maxVersion":"1.3","cipherSuites":"","rejectUnknownSni":False,
   "certificates":[{"certificateFile":e["CRT"],"keyFile":e["KEY"],"ocspStapling":3600,"oneTimeLoading":False,"usage":"encipherment","buildChain":False}],
   "alpn":["h2","http/1.1"],"settings":{"allowInsecure":False,"fingerprint":"chrome"}},
 "xhttpSettings":{"path":e["XPATH"],"host":"","headers":{},"scMaxBufferedPosts":30,"scMaxEachPostBytes":"1000000","noSSEHeader":False,"xPaddingBytes":"100-1000","mode":"auto"}}
sniff={"enabled":True,"destOverride":["http","tls","quic","fakedns"]}
print(json.dumps({"up":0,"down":0,"total":0,"remark":"cf-"+e["HOST"],"enable":True,"expiryTime":0,"listen":"","port":port,"protocol":"vless",
 "settings":json.dumps(settings),"streamSettings":json.dumps(stream),"sniffing":json.dumps(sniff)}))')
  xui POST panel/api/inbounds/add "$payload" > "$TMP/r"
  jget 'd.get("success")' < "$TMP/r" | grep -q True || die "添加入站失败：$(jget 'd.get("msg")' < "$TMP/r")"
  ok "入站 cf-$host 已添加，端口 $port"
  sleep 3
  [[ -n "$(ss -tlnH "sport = :$port")" ]] && ok "xray 已在监听 $port" || warn "xray 还没监听 $port，查看日志：journalctl -u x-ui -n 30"
  open_firewall "$port"

  step "[4/6] 设置 Cloudflare：DNS（橙色云）+ SSL「$(ssl_name $sslmode)」"
  if [[ $CF_MODE == auto ]]; then
    cf_ssl_rule "$z" "$host" "$sslmode"
    cf_dns "$z" "$host" "$ip"
  else
    manual_cf_steps "$host" "$ip" "$sslmode"
  fi

  step "[5/6] 验证"
  local code i
  code=$(curl -sk -o /dev/null -w '%{http_code}' -m 8 --resolve "$host:$port:127.0.0.1" "https://$host:$port/")
  [[ "$code" != 000 ]] && ok "本机 TLS 正常（HTTP $code）" || warn "本机 https://$host:$port 连不上"
  echo "  正在经 Cloudflare 访问 https://$host:$port/ （DNS 生效可能要一两分钟）……"
  for i in $(seq 1 30); do   # 最多约 5 分钟
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://$host:$port/")
    [[ "$code" =~ ^(404|400)$ ]] && break
    (( i >= 12 )) && [[ "$code" =~ ^(52[0-9]|30[178])$ ]] && break   # 2 分钟后仍是配置类错误，不再等
    sleep 8
  done
  case $code in
    404|400) ok "经 Cloudflare 访问正常（HTTP $code，这是预期结果）";;
    526) warn "Cloudflare 报 526：SSL 是「完全（严格）」但源站是自签证书 → 把这个域名的 SSL 改成「完全」";;
    525) warn "Cloudflare 报 525：和源站 TLS 握手失败，检查入站的证书路径";;
    521|522|523) warn "Cloudflare 报 $code：连不到 VPS 的 $port 端口，检查防火墙 / 安全组";;
    301|302|308) warn "Cloudflare 返回 $code 重定向：SSL 还是「灵活」，回到第②步把它设为「$(ssl_name $sslmode)」";;
    000) warn "域名还解析不到（DNS 没加或没生效），检查第①步，过几分钟再试：curl -I https://$host:$port/";;
    *) warn "经 Cloudflare 访问返回 $code，过几分钟再试：curl -I https://$host:$port/";;
  esac
  xray_e2e "$host" "$port" "$uuid" "$path" || warn "端到端测试没通过，过几分钟导入客户端再试"

  step "[6/6] 完成"
  local enc; enc=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$path")
  local link="vless://$uuid@$host:$port?encryption=none&security=tls&sni=$host&fp=chrome&alpn=h2%2Chttp%2F1.1&type=xhttp&host=$host&path=$enc&mode=auto#cf-$host"
  umask 077; printf 'host=%s\nport=%s\nuuid=%s\npath=%s\nlink=%s\n' "$host" "$port" "$uuid" "$path" "$link" > "/root/cf-node-$host.txt"
  echo
  echo "${BOLD}分享链接（导入 v2rayN / v2rayNG / Shadowrocket）：${NC}"
  echo "$link"
  echo
  echo "已保存到 /root/cf-node-$host.txt。也可以在 3x-ui 面板里复制同一个链接。"
  echo "${YELLOW}v2rayN 用户：设置 → 参数设置 → Core 类型设置，把 VLESS 改成 Xray，否则会报「配置不正确 - xhttp」。${NC}"
}

# ================= 网站走代理 =================
do_site() {
  local hosts=("$@")
  if [[ ${#hosts[@]} -eq 0 ]]; then
    read -rp "要改走 Cloudflare 的网站域名（多个用空格隔开）：" -a hosts
  fi
  [[ ${#hosts[@]} -gt 0 ]] || die "没有输入域名"
  cf_login
  local h z rec target code mode
  for h in "${hosts[@]}"; do
    step "== $h =="
    if [[ $CF_MODE == auto ]]; then
      z=$(cf_zone "$h") || exit 1
      rec=$(cf GET "/zones/$z/dns_records?name=$h")
      target=$(echo "$rec" | jget 'next((r["content"] for r in d["result"] if r["type"]=="A"),"")')
      [[ -n "$target" ]] || { warn "$h 没有 A 记录（CNAME 等请在控制台手动打开代理），跳过"; continue; }
    else
      # 半自动：还没开代理时，域名解析出来就是源站 IP
      target=$(getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1}')
      [[ -n "$target" ]] || { warn "解析不到 $h，跳过"; continue; }
      if [[ "$target" =~ ^(104\.(1[6-9]|2[0-9]|3[01])|172\.6[4-9]|172\.7[01]|162\.15[89]|188\.114|190\.93|197\.234|198\.41|141\.101|108\.162|173\.245|103\.(21|22|31)) ]]; then
        warn "$h 已经解析到 Cloudflare（$target），看起来已经开了代理，跳过"; continue
      fi
    fi
    # 判断源站支持什么：有正式证书 → 严格；自签证书 → 完全；只有 HTTP → 灵活
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 8 --resolve "$h:443:$target" "https://$h/")
    if [[ "$code" != 000 ]]; then mode=strict
    else
      code=$(curl -sk -o /dev/null -w '%{http_code}' -m 8 --resolve "$h:443:$target" "https://$h/")
      if [[ "$code" != 000 ]]; then mode=full
      else
        code=$(curl -s -o /dev/null -w '%{http_code}' -m 8 --resolve "$h:80:$target" "http://$h/")
        [[ "$code" != 000 ]] && mode=flexible || { warn "$target 的 80 和 443 端口上都没有这个网站，跳过（Cloudflare 只能代理标准网页端口）"; continue; }
      fi
    fi
    ok "源站 $target 检测结果：$( case $mode in strict) echo "HTTPS，正式证书 → SSL 用「完全（严格）」";; full) echo "HTTPS，自签证书 → SSL 用「完全」";; flexible) echo "只有 HTTP → SSL 用「灵活」";; esac)"
    if [[ $CF_MODE == auto ]]; then
      cf_ssl_rule "$z" "$h" "$mode"
      cf_dns "$z" "$h" ""
    else
      manual_cf_steps "$h" "" "$mode"
    fi
    local i
    for i in $(seq 1 30); do
      curl -s -o /dev/null -m 15 -D "$TMP/h" "https://$h/"
      grep -qi '^server: cloudflare' "$TMP/h" && break
      sleep 10
    done
    code=$(sed -n '1s/.* \([0-9][0-9][0-9]\).*/\1/p' "$TMP/h")
    if grep -qi '^server: cloudflare' "$TMP/h"; then
      case $code in
        2*|3*|401|403|404) ok "已经通过 Cloudflare 访问（HTTP $code）";;
        *) warn "已经走 Cloudflare，但返回 $code（52x 一般是 SSL 模式不对或源站没开）";;
      esac
    else warn "还没走 Cloudflare（代理没打开或 DNS 缓存），几分钟后再试：curl -I https://$h/"; fi
  done
  echo
  echo "注意：经 Cloudflare 免费版上传的单个请求最大 100 MB；网站看到的访客 IP 会变成 Cloudflare 的。"
  echo "SSH、DNS、邮件、面板的非标准端口不能走 Cloudflare，不要对这些子域名用本命令。"
}

# ================= 入口 =================
case "${1:-}" in
  node) shift; do_node "${1:-}";;
  site) shift; do_site "$@";;
  "")
    echo "${BOLD}cf-proxy：让被墙的 VPS 改走 Cloudflare${NC}"
    echo "  1) 新建一个走 Cloudflare 的节点"
    echo "  2) 让已有网站改走 Cloudflare"
    read -rp "选择 [1/2]：" c
    case $c in 1) do_node;; 2) do_site;; *) die "无效选择";; esac;;
  *) die "用法：bash cf-proxy.sh [node <子域名> | site <域名>...]";;
esac
