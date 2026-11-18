#!/usr/bin/env bash
# ============================================================================
# shuttle-download.sh —— 机器 B 上运行
# 读取机器 A 导出的指纹文件(export-pkg-md5.sh 的输出:单个包一个文件,
# 或 --project 模式导出的一个项目下多个包的指纹文件),
# 登录 https://shuttle.uniontech.com/(LDAP 账号),
# 按 包名/版本 查询对应构建,下载安装包(.deb)与符号包(debug/dbgsym),
# 保存到当前脚本目录:不管指纹文件里是 1 个还是多个包,所有包统一下载到
# download-<指纹文件基础名>/ 目录(如 fingerprint-20261118145810.txt →
# download-fingerprint-20261118145810/),下载地址清单 download-urls.txt
# 也写在该目录里。
#
# 用法:
#   ./shuttle-download.sh <指纹文件> [--dry-run]
#   ./shuttle-download.sh <目录>            # 处理目录下全部 *.fingerprint.txt
#   ./shuttle-download.sh <文件或目录> ...   # 可混合多个
#   ./shuttle-download.sh --project <项目名> [--dry-run]
#       # 兼容旧命名:等价于传 <项目名>.project.fingerprint.txt
#       # (在脚本目录或当前目录查找)
#   --sym-only: 只下载符号包(dbgsym),不询问;--all: 下载所有相关的包(安装包+符号包),不询问。
#       默认(不加选项)在下载前交互询问一次;管道输入时 EOF 按默认(所有包)。
#   --dry-run: 只演示流程(凭据输入、请求构造),不发起任何网络请求。
#
#   所有包的下载地址统一写入 download-<指纹文件名>/download-urls.txt;
#   每次运行重新生成。
#
#   指纹文件有三种,自动识别:
#   - 单包指纹(export-pkg-md5.sh 单包模式单包):一个文件一个包;
#   - 整套包指纹(*.project.fingerprint.txt,export-pkg-md5.sh --project
#     模式)与多包合并指纹(export-pkg-md5.sh 多包模式导出):
#     一个文件多个 "package:" 段 —— 自动拆分成单包段逐个处理。
#
#   批量模式下登录一次,逐包"查询→提取→下载";
#   单个包失败不影响其余包,最后统一汇总,存在失败时退出码非 0。
#
# 依赖: bash、curl、python3、openssl(机器 B 默认具备)。
# 注意: 机器 B 必须能访问 shuttle.uniontech.com(内网/VPN)。
#
# ------- 已实测确认的接口(2026-11 逆向前端并用真实账号登录验证) -------
#   POST /api/shuttle/user/login   body {"username","password"}
#       password 必须用下面的 RSA 公钥加密(PKCS#1 v1.5,base64 密文),
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

# --------------------------- 参数解析 ----------------------------------------
# 收集指纹文件到 FPS(目录会展开为其中的 *.fingerprint.txt)
# --project <项目名>:兼容旧命名,等价于传 <项目名>.project.fingerprint.txt
#   (指纹文件从脚本目录或当前目录查找)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FPS=(); DRY_RUN=0; PROJ_NAME=""; DOWNLOAD_MODE="all"; MODE_SET=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --sym-only) DOWNLOAD_MODE="sym"; MODE_SET=1; shift ;;
        --all) DOWNLOAD_MODE="all"; MODE_SET=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --project|-p)
            [[ $# -ge 2 && -n ${2:-} ]] || die "选项 $1 需要项目名参数,如: $0 --project dde-network-core"
            PROJ_NAME=$2; shift 2
            _pf="$SCRIPT_DIR/${PROJ_NAME}.project.fingerprint.txt"
            [[ -f $_pf ]] || _pf="${PROJ_NAME}.project.fingerprint.txt"   # 退回当前目录
            [[ -f $_pf ]] || die "项目指纹文件不存在: ${PROJ_NAME}.project.fingerprint.txt(已查找脚本目录与当前目录)"
            FPS+=("$_pf") ;;
        -*) die "未知选项: $1" ;;
        *)
            if [[ -d $1 ]]; then
                mapfile -t _fs < <(find "$1" -maxdepth 1 -type f -name '*.fingerprint.txt' | sort)
                [[ ${#_fs[@]} -gt 0 ]] || die "目录 [$1] 中没有 *.fingerprint.txt"
                FPS+=("${_fs[@]}")
            elif [[ -f $1 ]]; then
                FPS+=("$1")
            else
                die "指纹文件/目录不存在: $1"
            fi
            shift ;;
    esac
done
[[ ${#FPS[@]} -gt 0 ]] || die "用法: $0 <指纹文件|目录> [更多文件/目录] [--dry-run];或: $0 --project <项目名> [--dry-run]"

# --------------------------- 下载目录(按指纹文件) ---------------------------
# 不管指纹文件里含 1 个还是多个包,所有包统一下载到
# download-<指纹文件基础名>/ 目录(基础名先剥 .fingerprint.txt 再剥 .txt,
# 如 fingerprint-20261118145810.txt → download-fingerprint-20261118145810/);
# 下载地址清单 download-urls.txt 也写在该目录里;每个输入文件各自一个目录。
declare -A OUT_DIR_OF=()
_fp_dirname() {
    local b=${1##*/}
    b=${b%.fingerprint.txt}
    b=${b%.txt}
    b=${b%.project}      # 旧命名 <项目名>.project.fingerprint.txt → download-<项目名>/
    printf '%s' "$b"
}
for fp in "${FPS[@]}"; do
    OUT_DIR_OF["$fp"]="$SCRIPT_DIR/download-$(_fp_dirname "$fp")"
done

# --------------------------- 解析指纹文件 ------------------------------------
# $1 = 指纹文件;成功时设置全局 PKG/VER/ARCH/MD5/FILE_COUNT,失败 return 1
parse_fp() {
    local f=$1
    PKG=$(awk -F': ' '/^package:/{print $2; exit}' "$f")
    VER=$(awk -F': ' '/^version:/{print $2; exit}' "$f")
    ARCH=$(awk -F': ' '/^architecture:/{print $2; exit}' "$f")
    SRC=$(awk -F': ' '/^source:/{print $2; exit}' "$f")   # 源码项目名(查询用)
    # 指纹中 md5 行为 md5sums 原生格式:"<md5>  <路径>"(32位哈希开头)
    MD5=$(awk '/^[0-9a-f]{32}[[:space:]]/{print $1; exit}' "$f")
    FILE_COUNT=$(grep -cE '^[0-9a-f]{32}[[:space:]]' "$f" || true)
    [[ -n $PKG && -n $VER && -n $ARCH && -n $MD5 ]]
}

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
    # $1 = 查询名:shuttle 任务按【源码包名】记录(实测:按二进制包名
    #      查不到正常构建任务,只能查到零星 APPLY_FAILED 记录),
    #      所以这里必须传指纹里的 source 名
    python3 - "$1" "$VER" "$PAGE_SIZE" \
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

# --------------------------- 展开:多包指纹文件拆分 -----------------------
# 单包指纹:一个文件一个包;整套包指纹(*.project.fingerprint.txt)与
# 多包合并指纹(export-pkg-md5.sh 多包模式导出):
# 一个文件多个 "package:" 段 —— 拆成单包段文件再逐个处理,
# 这样机器 B 只需拿这一个文件就能下载所有包。
PROC_FPS=()
for fp in "${FPS[@]}"; do
    NPC=$(grep -c '^package:' "$fp" 2>/dev/null || true)
    if [[ $NPC -le 1 ]]; then
        PROC_FPS+=("$fp")
    else
        SD="$TMP/split.$(basename "$fp" .fingerprint.txt)"
        mkdir -p "$SD"
        awk -v d="$SD" '/^package:/{n++; f=sprintf("%s/%03d.fingerprint.txt",d,n)} n>0{print > f}' "$fp"
        log "[$(basename "$fp")] 是多包指纹文件,含 $NPC 个包,已拆分逐个处理"
        while IFS= read -r s; do
            OUT_DIR_OF["$s"]=${OUT_DIR_OF["$fp"]}   # 拆出的段沿用原文件的下载目录
            PROC_FPS+=("$s")
        done < <(find "$SD" -maxdepth 1 -type f -name '*.fingerprint.txt' | sort)
    fi
done
[[ ${#PROC_FPS[@]} -gt 0 ]] || die "没有可处理的指纹内容"

# --------------------------- 凭据输入 ---------------------------------------
echo "需要登录 shuttle.uniontech.com,请输入 LDAP 账号:"
IFS= read -rp "  用户名: " LDAP_USER    # IFS= 保留首尾空白,防止密码尾空格被吞
IFS= read -rsp "  密码:   " LDAP_PASS; echo
[[ -n $LDAP_USER && -n $LDAP_PASS ]] || die "用户名/密码不能为空"

# --------------------------- 下载范围选择 -----------------------------------
# 1=只下载符号包(dbgsym);2=下载所有相关的包(安装包+符号包,默认)。
# 命令行 --sym-only/--all 已指定时不再询问;管道输入 EOF/空输入按默认。
if [[ $MODE_SET -eq 0 ]]; then
    echo
    read -rp "下载范围 [1=只下载符号包(dbgsym) / 2=下载所有相关的包(默认)]: " _scope || _scope=""
    [[ ${_scope:-2} == 1 ]] && { DOWNLOAD_MODE="sym"; MODE_SET=1; }
fi
log "下载范围: $( [[ $DOWNLOAD_MODE == sym ]] && echo '仅符号包(dbgsym)' || echo '所有相关的包(安装包+符号包)' )"

# --------------------------- DRY-RUN ----------------------------------------
if [[ $DRY_RUN -eq 1 ]]; then
    echo "----- DRY-RUN 演示(不发起网络请求),共 ${#PROC_FPS[@]} 个待处理包/指纹 -----"
    make_login_body
    echo "1) POST $API_LOGIN"
    echo "   body: $(mask_body "$TMP/login.body")"
    for fp in "${PROC_FPS[@]}"; do
        parse_fp "$fp" || { echo "   [$fp] 指纹文件解析不完整(跳过)" >&2; continue; }
        echo "── 包[$PKG] 版本[$VER] (查询源码项目: ${SRC:-$PKG}) ──"
        make_query_body "${SRC:-$PKG}"
        echo "2) POST $API_TASKLIST  (Authorization: <token>)"
        echo "   body: $(cat "$TMP/query.body")"
        echo "3) 对每个成功 job: GET $API_JOBINFO?jobid=N → cacheurl → 目录索引提取 .deb/.ddeb →"
        _d=${OUT_DIR_OF[$fp]:-$SCRIPT_DIR}
        echo "   mkdir -p $_d && curl -L 下载 → 写 $_d/download-urls.txt"
    done
    log "DRY-RUN 结束,未做任何下载。"
    exit 0
fi

# --------------------------- 登录(一次,所有包共用) --------------------------
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
log "登录成功(token: ${TOKEN:0:8}...),共 ${#PROC_FPS[@]} 个待处理包/指纹"

# --------------------------- 各指纹文件的下载清单 ---------------------------
# 每个输入指纹文件的下载目录里各一份 download-urls.txt(先建目录并写头);
# 每次运行重新生成,逐包追加各自的段。
for fp in "${FPS[@]}"; do
    _d=${OUT_DIR_OF[$fp]}
    mkdir -p "$_d"
    {
        echo "# shuttle 下载地址清单 —— 由 shuttle-download.sh 生成"
        echo "# 生成时间: $(date '+%F %T')"
        echo "# 下载范围: $( [[ $DOWNLOAD_MODE == sym ]] && echo '仅符号包(dbgsym)' || echo '所有相关的包' )"
    } > "$_d/download-urls.txt"
done

# --------------------------- 下载单个文件 -----------------------------------
fetch() { # $1=url  $2=类别  $3=输出目录
    local base; base=$(basename "$1")
    log "下载[$2]: $base"
    curl -sS -m "$TIMEOUT" -L -b "$COOKIE_JAR" -H "Authorization: $TOKEN" \
        --fail -o "$3/$base" "$1" \
        || { echo "警告: $2 下载失败: $1" >&2; return 1; }
    echo "  -> $3/$base"
}

# --------------------------- 处理一个指纹文件 --------------------------------
process_one() { # $1=指纹文件;成功 return 0,失败 return 1(不中断整体)
    local fp=$1
    if ! parse_fp "$fp"; then
        echo "错误: [$(basename "$fp")] 指纹文件解析不完整,跳过" >&2
        return 1
    fi
    LAST_PKG=$PKG                     # 回传给主循环:失败汇总显示包名而非临时段文件名
    local QNAME=${SRC:-$PKG}
    local out_dir=${OUT_DIR_OF[$fp]:-$SCRIPT_DIR/$PKG}
    local urls_out="$out_dir/download-urls.txt"
    log "── 包[$PKG] 版本[$VER] 架构[$ARCH] (含 $FILE_COUNT 个文件 MD5) ──"
    log "下载目录: $out_dir"

    # 任务查询按源码项目名;同项目多包共用同一查询结果,轻量缓存避免重复请求
    local TKEY="${QNAME}_${VER}"; TKEY=${TKEY//\//_}
    local TCACHE="$TMP/task_${TKEY}.json"
    if [[ -s $TCACHE ]]; then
        log "任务查询[$QNAME $VER] 命中缓存,跳过重复请求"
        cp "$TCACHE" "$TMP/task.resp"
    else
        log "按源码项目[$QNAME] 查询构建任务..."
        make_query_body "$QNAME"
        local http_code
        http_code=$(curl -sS -m "$TIMEOUT" -b "$COOKIE_JAR" \
            -H "Authorization: $TOKEN" -H 'Content-Type: application/json' \
            -o "$TMP/task.resp" -w '%{http_code}' \
            --data @"$TMP/query.body" "$API_TASKLIST") \
            || { echo "错误: [$PKG] 查询请求失败(网络)" >&2; return 1; }
        if [[ $http_code != 200 ]]; then
            echo "错误: [$PKG] task/list HTTP $http_code: $(head -c 200 "$TMP/task.resp")" >&2
            return 1
        fi
        [[ -s $TMP/task.resp ]] && cp "$TMP/task.resp" "$TCACHE"
    fi

    # 解析任务列表:取目标架构的成功 job → job/info 拿 cacheurl →
    # 从产物目录索引页提取 .deb/.ddeb 链接
    # 先判断是否有任务:没有则给出明确原因(而不是笼统的"未提取到 .deb")
    if ! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if (d.get("tasks") or d.get("total")) else 1)' "$TMP/task.resp" 2>/dev/null; then
        echo "----- [$PKG] shuttle 上未找到构建任务(查询: 源码项目=$QNAME 版本=$VER) -----" >&2
        echo "      注意: shuttle 任务按【源码包名】记录,本次查询名: $QNAME" >&2
        echo "      可能原因: 该版本未在 shuttle 构建过(版本号需精确匹配);或任务已过期清理。" >&2
        echo "      可到网页端搜【$QNAME】确认有哪些版本。" >&2
        return 1
    fi
    local -a URLS MAIN SYM
    mapfile -t URLS < <(ARCH="$ARCH" TOKEN="$TOKEN" JOBINFO="$API_JOBINFO" TASKRESP="$TMP/task.resp" \
        PKGNAME="$PKG" PKGVER="$VER" TMPD="$TMP" python3 - \
        <<'PYEOF'
import json, sys, re, os, urllib.request, hashlib
resp = open(os.environ["TASKRESP"], encoding="utf-8", errors="replace").read()
arch, token, jobinfo = os.environ["ARCH"], os.environ["TOKEN"], os.environ["JOBINFO"]
pkg, ver, tmpd = os.environ["PKGNAME"], os.environ["PKGVER"], os.environ["TMPD"]
tasks = (json.loads(resp).get("tasks") or [])
jobs = [j for t in tasks for j in (t.get("jobs") or [])]
ok = [j for j in jobs if str(j.get("status", "")).endswith("_OK")]
if not ok:
    print(f"[{pkg} {ver}] 有 {len(jobs)} 个 job 但没有构建成功(_OK)的,无法下载", file=sys.stderr)
pick = [j for j in ok if j.get("arch") == arch]
if not pick and ok:
    print(f"[{pkg} {ver}] 未找到 {arch} 架构的成功 job,放宽为全部 {len(ok)} 个成功 job", file=sys.stderr)
    pick = ok
# 产物目录里有整个源码项目的所有包,只挑本包自己的文件:
#   主包  <pkg>_<ver>_<arch>.deb
#   符号包 <pkg>-dbgsym_<ver>_<arch>.deb / .ddeb
want = {f"{pkg}_{ver}_{arch}.deb",
        f"{pkg}-dbgsym_{ver}_{arch}.deb",
        f"{pkg}-dbgsym_{ver}_{arch}.ddeb"}
for j in pick:
    req = urllib.request.Request(jobinfo + "?jobid=" + str(j["id"]),
                                 headers={"Authorization": token})
    cu = ((json.load(urllib.request.urlopen(req, timeout=30)).get("data") or {})
          .get("cacheurl") or "")
    if not cu:
        continue
    print(f"产物目录[{j.get('arch')}]: {cu}", file=sys.stderr)
    # 索引页缓存:同项目多个包共用同一个产物目录,避免重复下载索引
    idxf = os.path.join(tmpd, "idx_" + hashlib.md5(cu.encode()).hexdigest() + ".html")
    if os.path.exists(idxf):
        idx = open(idxf, encoding="utf-8", errors="replace").read()
    else:
        try:
            idx = urllib.request.urlopen(cu, timeout=30).read().decode("utf-8", "replace")
            with open(idxf, "w", encoding="utf-8") as fh:
                fh.write(idx)
        except Exception as e:
            print(f"警告: 索引页获取失败 {cu}: {e}", file=sys.stderr)
            continue
    names = re.findall(r'href="([^"]+\.(?:deb|ddeb))"', idx)
    hit = False
    for name in names:
        if not name.startswith("../") and name in want:
            print(cu.rstrip("/") + "/" + name)
            hit = True
    if not hit:
        cands = sorted(n for n in names if not n.startswith("../") and n.startswith(pkg + "_"))[:5]
        if cands:
            print(f"提示: 产物目录里有 {pkg} 的文件但版本不匹配(期望 {ver}): " + ", ".join(cands), file=sys.stderr)
PYEOF
)
    if [[ ${#URLS[@]} -eq 0 ]]; then
        echo "----- [$PKG] 产物目录中未找到本包的安装包 -----" >&2
        echo "      期望: ${PKG}_${VER}_${ARCH}.deb 或 ${PKG}-dbgsym_${VER}_${ARCH}.deb/.ddeb" >&2
        echo "      (若有"版本不匹配"提示,说明任务存在但构建的不是本机安装的版本)" >&2
        head -c 500 "$TMP/task.resp" >&2; echo >&2
        return 1
    fi

    # 分类:主包 / 符号包;下载地址追加到本指纹文件的 download-urls.txt
    mkdir -p "$out_dir"
    {
        echo ""
        echo "# ── $PKG $VER ($ARCH) md5=$MD5 ──"
    } >> "$urls_out"
    MAIN=(); SYM=()
    local u base
    for u in "${URLS[@]}"; do
        base=$(basename "$u")
        if [[ $base =~ (dbgsym|_debug|debug) || $base == *.ddeb ]]; then
            SYM+=("$u"); echo "debug: $u" >> "$urls_out"
        else
            MAIN+=("$u")
            # 仅符号包模式下,安装包地址只记为注释(清单与实际下载保持一致)
            if [[ $DOWNLOAD_MODE == sym ]]; then
                echo "# skip(仅符号包模式): $u" >> "$urls_out"
            else
                echo "main:  $u" >> "$urls_out"
            fi
        fi
    done
    log "识别到 安装包 ${#MAIN[@]} 个 / 符号包 ${#SYM[@]} 个,清单见 $urls_out"

    local fail=0 u
    if [[ $DOWNLOAD_MODE == sym && ${#SYM[@]} -eq 0 ]]; then
        log "[$PKG] 该包没有符号包(dbgsym),按当前下载范围跳过"
        return 0
    fi
    if [[ $DOWNLOAD_MODE != sym ]]; then
        for u in "${MAIN[@]:-}"; do
            [[ -n $u ]] || continue
            fetch "$u" 安装包 "$out_dir" || fail=1
        done
    fi
    for u in "${SYM[@]:-}"; do
        [[ -n $u ]] || continue
        fetch "$u" 符号包 "$out_dir" || fail=1
    done

    echo "  [$PKG] 完成。产物目录: $out_dir"
    [[ $fail -eq 0 ]] || { echo "  [$PKG] 部分下载失败,见上方警告" >&2; return 1; }
}

# --------------------------- 主循环 ------------------------------------------
DONE=0; FAILED=(); LAST_PKG=""
for fp in "${PROC_FPS[@]}"; do
    if process_one "$fp"; then
        DONE=$((DONE+1))
    else
        FAILED+=("${LAST_PKG:-$(basename "$fp")}")
    fi
done

echo "=============================================================="
echo " 批量完成: 成功 $DONE / 共 ${#PROC_FPS[@]}"
if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo " 以下 ${#FAILED[@]} 个失败(见上方错误):"
    for f in "${FAILED[@]}"; do echo "   - $f"; done
fi
echo "=============================================================="
[[ ${#FAILED[@]} -eq 0 ]] || exit 1
exit 0
