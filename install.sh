#!/usr/bin/env bash
# 葫芦（hyotan）服务器面板 · 一键安装
#
#   curl -fsSL https://etng.github.io/hyotan-release/install.sh | sudo bash
#
# 默认从官方发布页下载，自动识别系统架构并核对文件指纹。
# 离线安装可以先下载安装包，再执行：./install.sh --from hyotan-linux-amd64
#
# 常用参数：
#   --bind 127.0.0.1:8123   面板监听地址（默认只监听本机）
#   --data-root DIR          数据目录
#   --upgrade                已安装时允许覆盖
#   --no-start               只装不启动
#   --url URL                改用其它下载地址
#
# 安装完成会打印访问地址、初始账号，以及忘记入口时的找回方法。
set -euo pipefail

BIN=/usr/local/bin/hyotan
UNIT=/etc/systemd/system/hyotan.service
DATA=/www/server/hyotan/data
BIND=127.0.0.1:8123
FROM=${HYOTAN_BINARY:-}
# 官网与发行清单托管在 GitHub Pages。仍可用 HYOTAN_RELEASE_URL / --url 覆盖，
# 便于内网镜像或分批下发。
DEFAULT_BASE=https://etng.github.io/hyotan-release
BASE=${HYOTAN_RELEASE_URL:-$DEFAULT_BASE}
UPGRADE=0
NO_START=0

show_help() {
  # 不能用 sed 读 $0：脚本被 `curl … | bash` 执行时 $0 只是 "bash"，
  # 帮助会变成一句「找不到文件」。这里把用法直接内联。
  cat <<'HELP'
葫芦（hyotan）服务器面板 · 一键安装

  curl -fsSL https://etng.github.io/hyotan-release/install.sh | sudo bash
  ./install.sh --from <本地安装包>

参数：
  --from FILE       使用本地安装包（离线）
  --url URL         改用其它下载地址
  --bind ADDR:PORT  面板监听地址，默认 127.0.0.1:8123
  --data-root DIR   数据目录
  --upgrade         已安装时允许覆盖
  --no-start        只装不启动
HELP
}

fail() { echo "安装中止：$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)       FROM=${2:?--from 需要文件路径}; shift 2 ;;
    --url)        BASE=${2:?--url 需要更新源地址}; shift 2 ;;
    --bind)       BIND=${2:?--bind 需要 ADDR:PORT}; shift 2 ;;
    --data-root)  DATA=${2:?--data-root 需要目录}; shift 2 ;;
    --upgrade)    UPGRADE=1; shift ;;
    --no-start)   NO_START=1; shift ;;
    -h|--help)    show_help; exit 0 ;;
    *) echo "未知参数：$1（用 --help 看用法）" >&2; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || fail "需要 root（面板要管 nginx / 系统用户 / systemd），请用 sudo 重跑"
command -v systemctl >/dev/null 2>&1 || fail "这台机器没有 systemd，本脚本只支持 systemd 的发行版"
command -v python3 >/dev/null 2>&1 || fail "需要 python3（用来解析发行清单 / 校验文件）"

case "$(uname -s)" in
  Linux) OS=linux ;;
  *) fail "只支持 Linux，当前是 $(uname -s)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) fail "没有为架构 $(uname -m) 准备二进制" ;;
esac

if [[ -x $BIN && $UPGRADE -eq 0 ]]; then
  fail "$BIN 已存在。升级请加 --upgrade（会先备份成 .bak-<时间戳>）"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SRC=$TMP/hyotan

if [[ -n $FROM ]]; then
  [[ -f $FROM ]] || fail "找不到二进制：$FROM"
  cp "$FROM" "$SRC"
  echo "来源        本地文件 $FROM"
else
  [[ -n $BASE ]] || fail "下载地址为空，请用 --url 指定"
  command -v curl >/dev/null 2>&1 || fail "需要 curl 来下载发行清单"
  BASE=${BASE%/}
  echo "发行源      $BASE"
  curl -fsSL --max-time 30 "$BASE/releases.json" -o "$TMP/releases.json" \
    || fail "下载 releases.json 失败（$BASE/releases.json）"

  # 清单格式见 scripts/make-release-index.sh：数组，较新的版本在前，
  # 每项 assets[] 里有 os / arch / name / sha256 / url。
  read -r ASSET SHA < <(BASE="$BASE" OS="$OS" ARCH="$ARCH" python3 - "$TMP/releases.json" <<'PY'
import json, sys, os
base = os.environ["BASE"].rstrip("/")
want_os, want_arch = os.environ["OS"], os.environ["ARCH"]
data = json.load(open(sys.argv[1], encoding="utf-8"))
for rel in data:
    if rel.get("prerelease"):
        continue
    for a in rel.get("assets", []):
        if a.get("os") == want_os and a.get("arch") == want_arch and len(a.get("sha256", "")) == 64:
            url = a["url"]
            if not url.startswith(("http://", "https://")):
                url = base + "/" + url.lstrip("/")
            print(url, a["sha256"])
            sys.exit(0)
sys.exit("清单里没有 linux/%s 且带 sha256 的资产" % want_arch)
PY
) || fail "解析 releases.json 失败"
  echo "资产        $ASSET"
  # 国内到 GitHub 资产 CDN 常见中途断流（真机实测 21 MB 下载报
  # "SSL_read: unexpected eof"，另有多次连接超时）。断点续传 + 重试：
  # 断了从已下载的字节继续，不重头开始；下面的 sha256 仍是对最终整文件逐字节校验，
  # 续传不会绕过完整性检查。
  if ! curl -fSL --retry 6 --retry-all-errors --retry-delay 2 \
       --connect-timeout 15 --max-time 900 -C - \
       -o "$SRC" "$ASSET"; then
    fail "下载安装包失败（已重试 6 次）。可稍后再试，或先手动下载后用 --from 离线安装"
  fi
  # 逐字节校验：清单被改一行、下载被劫持，都必须在这里挡住
  ACTUAL=$(python3 - "$SRC" <<'PY'
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
)
  [[ "$ACTUAL" == "$SHA" ]] || fail "sha256 不匹配：期望 $SHA，实际 $ACTUAL"
  echo "校验        sha256 一致（${SHA:0:16}…）"
fi

# 别把 HTML 错误页 / 压缩包当二进制装进去：ELF 魔数是最便宜的一道闸
python3 - "$SRC" <<'PY' || fail "这不是 ELF 可执行文件"
import sys
magic = open(sys.argv[1], "rb").read(4)
sys.exit(0 if magic == b"\x7fELF" else 1)
PY

if [[ -x $BIN ]]; then
  cp -a "$BIN" "$BIN.bak-$(date +%Y%m%d-%H%M%S)"
fi
install -d -m 755 "$(dirname "$BIN")" "$DATA"
install -m 755 "$SRC" "$BIN"
"$BIN" --version >/dev/null 2>&1 || fail "装上去的二进制跑不起来（架构不对？缺动态库？）"
VER=$("$BIN" --version 2>&1 | head -1 || true)
echo "已安装      $BIN ($VER)"

# 已存在的 unit 不覆盖：用户可能改过 HYOTAN_BIND / 加了 drop-in。
# 全新安装才写一份；重装时只换二进制。
if [[ ! -f $UNIT ]]; then
  cat > "$UNIT" <<EOF
[Unit]
Description=hyotan server panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# 面板要执行 systemctl / nginx -t / chown / 改 vhost，只能是 root
User=root
Group=root
Environment=HYOTAN_DATA_ROOT=$DATA
Environment=HYOTAN_BIND=$BIND
ExecStart=$BIN serve
Restart=always
RestartSec=2
LimitNOFILE=65535
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
EOF
  echo "服务单元    $UNIT（HYOTAN_BIND=$BIND）"
else
  echo "服务单元    已存在，保持不动（要改监听地址请编辑 $UNIT）"
fi

systemctl daemon-reload
systemctl enable hyotan >/dev/null

if [[ $NO_START -eq 1 ]]; then
  echo "按 --no-start 要求未启动。手动启动：systemctl start hyotan"
else
  systemctl restart hyotan
  # 首次启动要建表 + 生成 owner，等它把 stdout 打完再读入口
  for _ in $(seq 1 20); do
    systemctl is-active --quiet hyotan && break
    sleep 0.5
  done
  systemctl is-active --quiet hyotan || fail "服务没起来，看日志：journalctl -u hyotan -n 50 --no-pager"
  sleep 1
fi

echo
echo "================ 装好了 ================"
ENTRY=$("$BIN" entry show 2>/dev/null || echo "<服务未启动，启动后执行 hyotan entry show>")
HOSTIP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
# 重装时 unit 是旧的，里面写的 HYOTAN_BIND 可能和本次 --bind 完全不同。
# 从 systemd 读**实际生效**的环境（含 drop-in 覆盖），不能拿默认参数糊弄，
# 尤其不能把 0.0.0.0 的服务说成「只监听回环」。
ACTUAL_BIND=$(systemctl show hyotan -p Environment --value 2>/dev/null \
  | tr ' ' '\n' | sed -n 's/^HYOTAN_BIND=//p' | tail -1 || true)
[[ -n "$ACTUAL_BIND" ]] || ACTUAL_BIND=$BIND
PORT=${ACTUAL_BIND##*:}
echo "访问入口    http://<服务器公网IP>:${PORT}${ENTRY}/"
case "$ACTUAL_BIND" in
  127.0.0.1:*|localhost:*|\[::1\]*) ;;
  *) [[ -n "$HOSTIP" ]] && echo "本机内网    http://${HOSTIP}:${PORT}${ENTRY}/" ;;
esac
echo "实际监听    $ACTUAL_BIND（来自 systemd，不是安装参数）"
echo "数据目录    $DATA"
echo
echo "忘了入口：  hyotan entry show"
echo "改入口：    hyotan entry set /my-new-entry"
echo "初始密码：  journalctl -u hyotan --no-pager | grep '首次安装已创建'"
echo "服务状态：  systemctl status hyotan"
echo "面板库备份：hyotan db backup      （还原前先 hyotan db list / db verify）"
echo
case "$ACTUAL_BIND" in
  127.0.0.1:*|localhost:*|\[::1\]*)
    echo "安全提示：面板只监听回环，外网访问请在 nginx 上反代并加 TLS。"
    echo "          需要临时直连，改 $UNIT 里的 HYOTAN_BIND 后 daemon-reload + restart。"
    ;;
  *)
    echo "安全提示：面板直接监听 $ACTUAL_BIND。请确认云安全组只放行这一个端口，"
    echo "          并尽快在「设置 → 两步验证」绑定 TOTP。"
    ;;
esac
echo "======================================="
