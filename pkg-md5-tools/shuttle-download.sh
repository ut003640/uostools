#!/usr/bin/env bash
# ============================================================================
# shuttle-download.sh —— 机器 B 上运行
# 读取机器 A 导出的指纹文件(export-pkg-md5.sh 的输出),
# 登录 https://shuttle.uniontech.com/(LDAP 账号),
# 按包名/版本/MD5 查询对应构建,下载安装包(.deb)与符号包(debug/dbgsym),
# 保存到当前脚本目录下以包名新建的目录,并把下载地址写入该目录。
#
# 用法:
#   ./shuttle-download.sh <指纹文件> [--dry-run]
#   --dry-run: 只演示流程(凭据输入、请求构造),不发起任何网络请求。
#
# 依赖: bash、curl、python3(机器 B 默认具备)。
# 注意: 机器 B 必须能访问 shuttle.uniontech.com(内网/VPN)。
#
# ------- 已实测确认的接口(2026-11 逆向前端并用真实账号登录验证) -------
#   POST /api/shuttle/user/login   body {"username","password"}
#       password 必须用上面的 RSA 公钥加密(PKCS#1 v1.5,base64 密文),
#       与前端 JSEncrypt.encrypt() 一致;发明文会被服务端报
#       "Password resolution failed"(所有登录失败也统一报这条)。
#       成功: {"code":0,"data":{"token":"..."},"message":"welcome back"}
#   POST /api/shuttle/task/list   body {"params":{"pkgname","pkgver"},"pageSize","current"}
#       键名是裸键 pkgname/pkgver(带 query. 前缀或 name/version 均查不到);
#       task.hashsum 是 SHA-1,无法按 MD5 查。
#       返回 {"tasks":[{key,pkgname,pkgver,status,jobs:[{id,arch,status}],...}],"total"}
#   GET /api/shuttle/job/info?jobid=<id>
#       返回 job 详情,cacheurl 字段是产物目录索引页(可列目录),
#       .deb/.ddeb/源码包/buildlog 都在里面。
#   鉴权方式: 登录后以请求头 "Authorization: <token>" 携带。
# ------- 需用真实账号确认的部分(如有出入,改下方"可配置区") -------
#   POST /api/shuttle/task/list 的查询字段名,以及返回 JSON 中
#   产物下载链接所在的字段/格式。脚本对返回做通用 URL 提取,并在
#   提取不到时打印原始响应便于排查(浏览器 F12 抓一次真实请求即可对齐)。
# ============================================================================
set -euo pipefail

# ----------------------------- 可配置区 -------------------------------------
BASE_URL="https://shuttle.uniontech.com"
API_LOGIN="${BASE_URL}/api/shuttle/user/login"
API_TASKLIST="${BASE_URL}/api/shuttle/task/list"   # 构建任务查询接口
API_JOBINFO="${BASE_URL}/api/shuttle/job/info"     # job 详情(含 cacheurl 产物目录)
PAGE_SIZE=50
TIMEOUT=60                     # 单次 HTTP 超时(秒)
# shuttle 登录密码加密用的 RSA 公钥(提取自前端 chunk-68c1f25c,
# 与前端 JSEncrypt.encrypt 相同: PKCS#1 v1.5 填充,密文 base64)
PUB_KEY_B64="MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCkA9WqirWQII3D8/M9UG8X8ybQOu+cPSNTgR9b4HenJ7A5zSfkXZnetb5q6MmKTJLGCl9MSsHveQPHmLGDG+xw2MlBw3Yefd/jJ1Cg8pP69wlHRX+wiyh5p8KY55ehFNsQLm3kDGXgVJdtrZn/MiBOlCtEfe9YvvT0lqy2BtBpaQIDAQAB"
# ----------------------------------------------------------------------------

die() { echo "错误: $*" >&2; exit 1; }
log() { echo "[$(date '+%T')] $*"; }
# 打印 JSON body,密码值脱敏(容忍值内的 \" \\ 等转义序列,避免泄漏)
mask_body() {
    sed 's/"password"[[:space:]]*:[[:space:]]*"[^"\\]*\(\\.[^"\\]*\)*"/"password":"***"/g' "$1"
}

FP=""; DRY_RUN=0
for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=1 ;;
        *) FP=$arg ;;
    esac
done
[[ -n $FP ]] || die "用法: $0 <指纹文件> [--dry-run]"
[[ -f $FP ]] || die "指纹文件不存在: $FP"

# --------------------------- 解析指纹文件 -----------------------------------
parse_fp() { awk -F': ' '/^package:/{print $2}' "$FP"; }
get_ver()  { awk -F': ' '/^version:/{print $2}' "$FP"; }
get_arch() { awk -F': ' '/^architecture:/{print $2}' "$FP"; }
# 指纹中 md5 行为 md5sums 原生格式:"<md5>  <路径>"(32位哈希开头)
first_md5() { awk '/^[0-9a-f]{32}[[:space:]]/{print $1; exit}' "$FP"; }

PKG=$(parse_fp)      || die "指纹文件缺少 package 行"
VER=$(get_ver)       || die "指纹文件缺少 version 行"
ARCH=$(get_arch)     || die "指纹文件缺少 architecture 行"
MD5=$(first_md5)     || die "指纹文件缺少 file 行(没有文件 MD5)"
[[ -n $PKG && -n $VER && -n $ARCH && -n $MD5 ]] || die "指纹文件解析不完整"

FILE_COUNT=$(grep -cE '^[0-9a-f]{32}[[:space:]]' "$FP" || true)
OUT_DIR="$(cd "$(dirname "$0")" && pwd)/$PKG"

log "指纹: 包=$PKG 版本=$VER 架构=$ARCH (含 $FILE_COUNT 个文件 MD5,查询用首个: $MD5)"
log "下载目录: $OUT_DIR"

# --------------------------- 构造请求体(python3 生成,防特殊字符) ----------
make_login_body() {
    SH_USER=${LDAP_USER} SH_PASS=${LDAP_PASS} PUBKEY="$TMP/shuttle-pub.pem" python3 - \
        <<'PYEOF' > "$TMP/login.body"
import os, json, base64, subprocess
# 密码用 shuttle 的 RSA 公钥加密(PKCS#1 v1.5),等价于前端 JSEncrypt.encrypt()
enc = subprocess.run(
    ["openssl", "rsautl", "-encrypt", "-pubin", "-inkey", os.environ["PUBKEY"]],
    input=os.environ["SH_PASS"].encode(), capture_output=True, check=True).stdout
print(json.dumps({"username": os.environ["SH_USER"],
                  "password": base64.b64encode(enc).decode()}))
PYEOF
}
make_query_body() {
    python3 - "$PKG" "$VER" "$PAGE_SIZE" \
        <<'PYEOF' > "$TMP/query.body"
import json, sys
pkg, ver, size = sys.argv[1], sys.argv[2], int(sys.argv[3])
# 服务端只认裸键 pkgname/pkgver;hashsum 是 SHA-1,不能按 MD5 查
print(json.dumps({"params": {"pkgname": pkg, "pkgver": ver},
                  "pageSize": size, "current": 1}))
PYEOF
}

# --------------------------- 临时文件与清理 ---------------------------------
TMP=$(mktemp -d /tmp/shuttle-dl.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
COOKIE_JAR="$TMP/cookies.txt"
chmod 700 "$TMP"
# RSA 公钥 PEM(供 openssl 加密密码用)
{ echo '-----BEGIN PUBLIC KEY-----'; echo "$PUB_KEY_B64" | fold -w 64; echo '-----END PUBLIC KEY-----'; } > "$TMP/shuttle-pub.pem"

# --------------------------- 凭据输入 ---------------------------------------
echo "需要登录 shuttle.uniontech.com,请输入 LDAP 账号:"
IFS= read -rp "  用户名: " LDAP_USER    # IFS= 保留首尾空白,防止密码尾空格被吞
IFS= read -rsp "  密码:   " LDAP_PASS; echo
[[ -n $LDAP_USER && -n $LDAP_PASS ]] || die "用户名/密码不能为空"

if [[ $DRY_RUN -eq 1 ]]; then
    echo "----- DRY-RUN 演示(不发起网络请求) -----"
    make_login_body
    echo "1) POST $API_LOGIN"
    echo "   body: $(mask_body "$TMP/login.body")"
    make_query_body
    echo "2) POST $API_TASKLIST  (Authorization: <token>)"
    echo "   body: $(cat "$TMP/query.body")"
    echo "3) 对每个成功 job: GET $API_JOBINFO?jobid=N → cacheurl → 目录索引提取 .deb/.ddeb →"
    echo "   mkdir -p $OUT_DIR && curl -L 下载 → 写 $OUT_DIR/download-urls.txt"
    log "DRY-RUN 结束,未做任何下载。"
    exit 0
fi

# --------------------------- 登录 ------------------------------------------
make_login_body
log "正在登录 $BASE_URL ..."
HTTP_CODE=$(curl -sS -m "$TIMEOUT" -c "$COOKIE_JAR" -o "$TMP/login.resp" \
        -w '%{http_code}' \
        -H 'Content-Type: application/json' \
        --data @"$TMP/login.body" "$API_LOGIN") \
    || die "网络请求失败,请检查机器 B 到 shuttle 的连通性(VPN/内网)"
RESP=$(cat "$TMP/login.resp")

CODE=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("code",-1))' <<<"$RESP" 2>/dev/null || echo -1)
if [[ $CODE != 0 ]]; then
    MSG=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("message","未知错误"))' <<<"$RESP" 2>/dev/null || echo "$RESP")
    {
        echo "----- 登录失败诊断信息 -----"
        echo "HTTP 状态码 : $HTTP_CODE (200 才说明请求到达了业务层)"
        echo "请求 URL    : $API_LOGIN"
        echo "发送 body   : $(mask_body "$TMP/login.body")"
        echo "原始响应    : ${RESP:-<空>}"
        echo "提示: 若 message 仍为 'Password resolution failed',多为 RSA 加密/公钥不匹配"
        echo "      (公钥以服务端前端为准);否则请核对: 1) 用户名格式是否与网页登录一致;"
        echo "      2) 密码首尾是否有空格等特殊字符; 3) 网页端用同一账号能否登录。"
    } >&2
    die "LDAP 验证失败: $MSG"
fi
TOKEN=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["data"].get("token",""))' <<<"$RESP" 2>/dev/null || true)
[[ -n $TOKEN ]] || TOKEN=$(awk '$6=="Authorization"{print $7}' "$COOKIE_JAR" | tail -1)
log "登录成功(token: ${TOKEN:0:8}...)" 

# --------------------------- 查询构建任务 ----------------------------------
make_query_body
log "查询构建任务: $API_TASKLIST"
RESP_TASK=$(curl -sS -m "$TIMEOUT" -b "$COOKIE_JAR" \
    -H "Authorization: $TOKEN" -H 'Content-Type: application/json' \
    --data @"$TMP/query.body" "$API_TASKLIST") \
    || die "查询请求失败"

# 解析任务列表:取目标架构的成功 job → job/info 拿 cacheurl →
# 从产物目录索引页提取 .deb/.ddeb 链接
printf '%s' "$RESP_TASK" > "$TMP/task.resp"
mapfile -t URLS < <(ARCH="$ARCH" TOKEN="$TOKEN" JOBINFO="$API_JOBINFO" TASKRESP="$TMP/task.resp" python3 - \
    <<'PYEOF'
import json, sys, re, os, urllib.request
resp = open(os.environ["TASKRESP"], encoding="utf-8", errors="replace").read()
arch, token, jobinfo = os.environ["ARCH"], os.environ["TOKEN"], os.environ["JOBINFO"]
tasks = (json.loads(resp).get("tasks") or [])
jobs = [j for t in tasks for j in (t.get("jobs") or [])]
ok = [j for j in jobs if str(j.get("status", "")).endswith("_OK")]
pick = [j for j in ok if j.get("arch") == arch]
if not pick:
    print(f"警告: 未找到 {arch} 架构的成功 job,放宽为全部成功 job", file=sys.stderr)
    pick = ok
for j in pick:
    req = urllib.request.Request(jobinfo + "?jobid=" + str(j["id"]),
                                 headers={"Authorization": token})
    cu = ((json.load(urllib.request.urlopen(req, timeout=30)).get("data") or {})
          .get("cacheurl") or "")
    if not cu:
        continue
    print(f"产物目录[{j.get('arch')}]: {cu}", file=sys.stderr)
    try:
        idx = urllib.request.urlopen(cu, timeout=30).read().decode("utf-8", "replace")
    except Exception as e:
        print(f"警告: 索引页获取失败 {cu}: {e}", file=sys.stderr)
        continue
    for name in re.findall(r'href="([^"]+\.(?:deb|ddeb))"', idx):
        if not name.startswith("../"):
            print(cu.rstrip("/") + "/" + name)
PYEOF
)

if [[ ${#URLS[@]} -eq 0 ]]; then
    echo "----- 未在产物目录中提取到 .deb/.ddeb 链接,原始任务响应如下(供排查) -----"
    head -c 2000 <<<"$RESP_TASK"; echo
    die "确认该包名/版本在 shuttle 上有成功的构建任务(pkgname=$PKG pkgver=$VER),或用浏览器 F12 对照"
fi

# --------------------------- 分类:主包 / 符号包 ----------------------------
mkdir -p "$OUT_DIR"
URLS_FILE="$OUT_DIR/download-urls.txt"
{
    echo "# 查询指纹: package=$PKG version=$VER arch=$ARCH md5=$MD5"
    echo "# 生成时间: $(date '+%F %T')"
} > "$URLS_FILE"

MAIN=(); SYM=()
for u in "${URLS[@]}"; do
    base=$(basename "$u")
    if [[ $base =~ (dbgsym|_debug|debug) || $base == *.ddeb ]]; then
        SYM+=("$u"); echo "debug: $u" >> "$URLS_FILE"
    else
        MAIN+=("$u"); echo "main:  $u" >> "$URLS_FILE"
    fi
done
log "识别到 安装包 ${#MAIN[@]} 个 / 符号包 ${#SYM[@]} 个,清单见 $URLS_FILE"

# --------------------------- 下载 ------------------------------------------
fetch() { # $1=url  $2=类别
    local base; base=$(basename "$1")
    log "下载[$2]: $base"
    curl -sS -m "$TIMEOUT" -L -b "$COOKIE_JAR" -H "Authorization: $TOKEN" \
        --fail -o "$OUT_DIR/$base" "$1" \
        || { echo "警告: $2 下载失败: $1" >&2; return 1; }
    echo "  -> $OUT_DIR/$base"
}
FAIL=0
for u in "${MAIN[@]:-}"; do [[ -n $u ]] && fetch "$u" 安装包 || FAIL=1; done
for u in "${SYM[@]:-}";  do [[ -n $u ]] && fetch "$u" 符号包 || FAIL=1; done

echo "=============================================================="
echo " 完成。产物目录: $OUT_DIR"
echo " 下载地址清单:   $URLS_FILE"
[[ $FAIL -eq 0 ]] || echo " (部分下载失败,见上方警告)"
echo "=============================================================="
exit 0
