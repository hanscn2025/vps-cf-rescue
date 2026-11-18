#!/usr/bin/env bash
# check-block.sh —— 检查 VPS 的 IP / 端口有没有被墙
#
# 在 VPS 上以 root 运行（在别的机器上运行也可以，只是少了本机检查）：
#   bash check-block.sh                 # 自动取本机公网 IP，测 22 端口 + 所有 xray 公网端口
#   bash check-block.sh 1.2.3.4 22 443  # 指定 IP 和端口
#
# 原理：用 Globalping（https://globalping.io，免费、无需注册）的国内和海外探针，
# 同时对你的 IP:端口 做 TCP 连接测试；再用同一批国内探针测百度作对照，排除探针自身不通。
# 依赖：curl、python3。

set -uo pipefail

API=https://api.globalping.io/v1/measurements
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; NC=$'\033[0m'

die() { echo "${RED}错误：$*${NC}" >&2; exit 1; }
command -v curl >/dev/null || die "缺少 curl，先安装：apt install -y curl"
command -v python3 >/dev/null || die "缺少 python3，先安装：apt install -y python3"

# ---------- 参数 ----------
ARG_IP="${1:-}"
IP="$ARG_IP"
shift 2>/dev/null || true
PORTS=("$@")

if [[ -z "$IP" ]]; then
  for u in https://api.ipify.org https://ifconfig.me/ip https://ipv4.icanhazip.com; do
    IP=$(curl -4 -s -m 8 "$u" | tr -d '[:space:]') && [[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    IP=""
  done
  [[ -n "$IP" ]] || die "取不到本机公网 IP，请手动指定：bash check-block.sh <IP>"
fi
[[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "IP 格式不对：$IP（目前只支持 IPv4）"

echo "${BOLD}== 检查对象：$IP ==${NC}"

# ---------- 1. 本机检查（只在 VPS 上有意义）----------
LOCAL_IPS=$(hostname -I 2>/dev/null || true)
if [[ " $LOCAL_IPS " == *" $IP "* ]] || [[ -z "$ARG_IP" ]]; then
  echo
  echo "${BOLD}[1/3] 本机检查${NC}"
  if command -v systemctl >/dev/null && systemctl list-unit-files 2>/dev/null | grep -q '^x-ui'; then
    if systemctl is-active --quiet x-ui; then echo "  ${GREEN}✓${NC} x-ui 服务在运行"
    else echo "  ${RED}✗${NC} x-ui 服务没在运行 —— 这是服务器问题，不是被墙。先执行：systemctl restart x-ui"; fi
  else
    echo "  - 没装 x-ui，跳过面板检查"
  fi
  XRAY_PORTS=$(ss -tlnpH 2>/dev/null | grep -E 'xray' | awk '{print $4}' | grep -vE '^(127\.|\[::1\]|172\.|10\.|192\.168\.)' | sed -E 's/.*:([0-9]+)$/\1/' | sort -un | tr '\n' ' ')
  if [[ -n "$XRAY_PORTS" ]]; then echo "  ${GREEN}✓${NC} xray 正在监听的公网端口：$XRAY_PORTS"
  else echo "  - 没发现 xray 监听公网端口"; fi
  if [[ ${#PORTS[@]} -eq 0 ]]; then
    PORTS=(22)
    for p in $XRAY_PORTS; do PORTS+=("$p"); done
  fi
fi
[[ ${#PORTS[@]} -gt 0 ]] || PORTS=(22)
# 去重，最多测 6 个端口（Globalping 免费额度每小时 250 次探测）
mapfile -t PORTS < <(printf '%s\n' "${PORTS[@]}" | awk '!s[$0]++' | head -6)
echo "  将测试端口：${PORTS[*]}"

# ---------- 2. 发起测试 ----------
echo
echo "${BOLD}[2/3] 从国内和海外探针发起 TCP 连接测试（约 20 秒）${NC}"

start() { # $1=target $2=port $3=locations-json
  curl -s -m 20 -X POST "$API" -H 'content-type: application/json' \
    -d "{\"type\":\"ping\",\"target\":\"$1\",\"locations\":$3,\"measurementOptions\":{\"protocol\":\"TCP\",\"port\":$2,\"packets\":3}}" |
    python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("id",""))
except Exception: print("")'
}
CN='[{"country":"CN","limit":10}]'
INTL='[{"magic":"HK","limit":2},{"magic":"JP","limit":2},{"magic":"SG","limit":2},{"magic":"US","limit":2}]'

declare -A ID_CN ID_INTL
CTRL=$(start www.baidu.com 443 "$CN")
for p in "${PORTS[@]}"; do
  ID_CN[$p]=$(start "$IP" "$p" "$CN")
  ID_INTL[$p]=$(start "$IP" "$p" "$INTL")
  [[ -n "${ID_CN[$p]}" && -n "${ID_INTL[$p]}" ]] || die "Globalping 拒绝了请求（可能是每小时额度用完了），过一会儿再试，或用 https://www.itdog.cn/tcping/ 手动测"
done

# 统计一次测试：输出 "成功数 总数"，探针丢包 < 100% 算成功
result() {
  local id=$1 i
  for i in $(seq 1 30); do
    out=$(curl -s -m 20 "$API/$id" | python3 -c 'import sys,json
d=json.load(sys.stdin)
if d.get("status")!="finished": print("wait"); sys.exit()
ok=tot=0
for r in d.get("results",[]):
    s=r["result"].get("stats") or {}
    if r["result"].get("status")!="finished": continue
    tot+=1
    if s.get("loss") is not None and s["loss"]<100: ok+=1
print(ok,tot)' 2>/dev/null)
    [[ "$out" != "wait" && -n "$out" ]] && { echo "$out"; return; }
    sleep 2
  done
  echo "0 0"
}

read -r c_ok c_tot < <(result "$CTRL")
if [[ "$c_tot" -eq 0 ]] || (( c_ok * 2 < c_tot )); then
  echo "  ${YELLOW}!${NC} 国内探针连百度都不太通（$c_ok/$c_tot），这次结果不可靠，建议稍后重试或用 itdog 手动测。"
fi

# ---------- 3. 结论 ----------
echo
echo "${BOLD}[3/3] 结果${NC}"
printf "  %-8s %-14s %-14s %s\n" "端口" "国内可连" "海外可连" "结论"
BLOCKED_ALL=1; ANY_BLOCK=0
for p in "${PORTS[@]}"; do
  read -r cn_ok cn_tot < <(result "${ID_CN[$p]}")
  read -r in_ok in_tot < <(result "${ID_INTL[$p]}")
  if (( in_tot == 0 || in_ok * 2 < in_tot )); then
    verdict="${YELLOW}海外也不通：端口没开 / 防火墙拦了 / 服务没跑${NC}"; BLOCKED_ALL=0
  elif (( cn_tot > 0 && cn_ok * 5 <= cn_tot )); then
    verdict="${RED}被墙${NC}"; ANY_BLOCK=1
  elif (( cn_tot > 0 && cn_ok * 2 < cn_tot )); then
    verdict="${YELLOW}国内部分不通（可能被干扰或线路差）${NC}"; BLOCKED_ALL=0
  else
    verdict="${GREEN}正常${NC}"; BLOCKED_ALL=0
  fi
  printf "  %-8s %-14s %-14s %s\n" "$p" "$cn_ok/$cn_tot" "$in_ok/$in_tot" "$verdict"
done

echo
if (( ANY_BLOCK && BLOCKED_ALL )); then
  echo "${RED}${BOLD}结论：整个 IP 被墙了${NC}（所有测试端口国内都不通、海外通）。"
  echo "办法：运行 cf-proxy.sh 新建一个走 Cloudflare 的节点，或找服务商换 IP。"
elif (( ANY_BLOCK )); then
  echo "${YELLOW}${BOLD}结论：部分端口被封${NC}，IP 本身还能用。给被封的节点换个端口即可。"
else
  echo "${GREEN}${BOLD}结论：没有发现被墙${NC}。节点不通的话，检查客户端配置、到期时间和流量。"
fi
echo "（想看每个城市的明细，可以到 https://www.itdog.cn/tcping/$IP:${PORTS[0]} 再测一次。）"
