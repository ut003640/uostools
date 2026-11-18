#!/usr/bin/env bash
# ============================================================================
# export-pkg-md5.sh —— 机器 A 上运行
# 导出本机已安装 deb 包的 版本 / 架构 / 包内文件MD5 指纹,输出到文本文件。
# 之后把该文本文件拷到机器 B,配合 shuttle-download.sh 下载同一次构建的
# 安装包和符号包。
#
# 用法:
#   ./export-pkg-md5.sh
#       交互模式:先选择"单个包"或"整套包",再输入名称
#   ./export-pkg-md5.sh dde-dock [更多包名...]
#       单个包模式:一次导出一个或多个包(空格分隔),可带 :arch 限定;
#       不管 1 个还是多个包,指纹都写入同一个文件
#       fingerprint-<年月日时分秒>.txt —— 机器 B 上把这一个文件交给
#       shuttle-download.sh 即可下载全部包(统一下载到
#       download-<指纹文件名>/ 目录)
#   ./export-pkg-md5.sh --project dde-network-core [更多项目名...]
#       整套包模式:输入源码项目名(source package),把该项目在本机
#       已安装的全部二进制包的指纹写入同一个文件
#       fingerprint-<年月日时分秒>.txt(-P 为短写)。机器 B 上把这一个
#       文件交给 shuttle-download.sh 即可解析并下载全部包(含符号包)。
#
# 整套包模式说明:
#   Debian 中一个源码包(source package)会产出多个二进制包,例如
#   dde-network-core 对应 libdde-network-core、dock-network-plugin、
#   dcc-network-plugin、dss-network-plugin、deepin-service-plugin-network 等。
#   本模式用 dpkg 数据库的 Source 字段反查:凡"本机已安装且属于该源码
#   项目"的二进制包,指纹按 package: 段依次写入同一个项目指纹文件。
#   注意只能覆盖本机已安装的包;未安装的包拿不到包内文件 MD5。
#
# 无需 root:dpkg 数据库中 info/<pkg>.md5sums 普通用户可读。
# ============================================================================
set -euo pipefail

die() { echo "错误: $*" >&2; exit 1; }
warn() { echo "警告: $*" >&2; }

# ---------- 参数解析 ----------
MODE=single
if [[ ${1:-} == "--project" || ${1:-} == "-P" ]]; then
    MODE=project; shift
fi

NAMES=()
if [[ $# -ge 1 ]]; then
    NAMES=("$@")                       # 命令行:多个包名/项目名,空格分隔
elif [[ $MODE == project ]]; then
    read -rp "请输入源码项目名(source package): " INPUT
    NAMES=("$INPUT")
else
    echo "请选择导出模式:"
    echo "  1) 单个包  —— 可一次输入多个包名,空格分隔(如: dde-daemon dde-dock)"
    echo "  2) 整套包  —— 输入源码项目名,导出该项目下所有已安装的二进制包"
    read -rp "请输入 1 或 2 [默认 1]: " CH
    if [[ $CH == 2 ]]; then
        MODE=project
        read -rp "请输入源码项目名(source package): " INPUT
        NAMES=("$INPUT")
    else
        read -rp "请输入包名(多个包用空格分隔): " INPUT
        read -ra NAMES <<< "$INPUT"
    fi
fi

[[ ${#NAMES[@]} -ge 1 ]] || die "名称不能为空"
for n in "${NAMES[@]}"; do
    # 包名可带 :arch 限定(如 libfontconfig1:amd64);项目名不带
    [[ $n =~ ^[a-zA-Z0-9][a-zA-Z0-9+._-]*(:[a-zA-Z0-9_-]+)?$ ]] \
        || die "名称含非法字符: $n"
done

# ---------- 输出文件名:fingerprint-<年月日时分秒>.txt ------------------------
# 不管 1 个还是多个包、单包还是整套包模式,指纹统一写入
# fingerprint-<年月日时分秒>.txt;机器 B 上把这一个文件交给
# shuttle-download.sh 即可下载全部包(统一下载到 download-<指纹文件名>/ 目录)。
gen_fp_name() {
    local ts; ts=$(date +%Y%m%d%H%M%S)
    while [[ -e "fingerprint-${ts}.txt" ]]; do ts=$((10#$ts + 1)); done
    printf 'fingerprint-%s.txt' "$ts"
}
OUT_FILE=""
if [[ $MODE == single ]]; then
    OUT_FILE=$(gen_fp_name)
    {
        echo "# ============================================================"
        echo "# 包指纹文件 —— 包: ${NAMES[*]}"
        echo "# 生成: $(date '+%F %T') @ $(hostname)"
        echo "# 说明: 每个 'package:' 段为一个二进制包;未安装/导出失败的包不会出现在文件中。"
        echo "# 机器 B 上执行: ./shuttle-download.sh $OUT_FILE"
        echo "#   即自动解析本文件内全部包并逐个下载(符号包随主包附带下载)。"
        echo "# ============================================================"
    } > "$OUT_FILE"
fi

# ---------- 导出单个包的指纹 ----------
# $1 = 二进制包名(可带 :arch); $2 = 源码项目名(仅整套包模式用于溯源)
# $3 = 追加目标(整套包模式:该项目所有包共用一个指纹文件,逐段追加)
# 成功: 写好指纹并设全局 GEN_FILE=文件名; 失败: return 1
export_one() {
    local pkg=$1 src_name=${2:-} append_to=${3:-}
    local Q VER ARCH STATUS DPKG_SRC SRC_OUT SUMS OUT_FILE PURE
    Q=$(dpkg-query -W -f='${Version}\n${Architecture}\n${Status}\n${Source}\n' "$pkg" 2>/dev/null) \
        || { warn "[$pkg] 未安装或查询失败"; return 1; }
    VER=$(sed -n '1p' <<<"$Q")
    ARCH=$(sed -n '2p' <<<"$Q")
    STATUS=$(sed -n '3p' <<<"$Q")
    DPKG_SRC=$(sed -n '4p' <<<"$Q")
    read -r _ _ WANT_INSTALLED _ <<<"$STATUS"   # Status: want error status
    [[ $WANT_INSTALLED == installed ]] || { warn "[$pkg] 未处于已安装状态($STATUS),跳过"; return 1; }
    [[ -n $VER && -n $ARCH ]] || { warn "[$pkg] 无法解析版本/架构"; return 1; }

    # 定位 md5sums(兼容多架构包的 :arch 后缀文件名)
    local INFO=/var/lib/dpkg/info
    SUMS=""
    for cand in "$INFO/${pkg}.md5sums" "$INFO/${pkg}:${ARCH}.md5sums"; do
        [[ -f $cand ]] && { SUMS=$cand; break; }
    done
    if [[ -z $SUMS ]]; then
        PURE=${pkg%%:*}
        SUMS=$(compgen -G "$INFO/${PURE}:*.md5sums" 2>/dev/null | head -1 || true)
    fi
    [[ -n $SUMS ]] || { warn "[$pkg] 在 $INFO 下无 md5sums 记录(空包?),跳过"; return 1; }

    PURE=${pkg%%:*}          # 剥掉 :arch 限定,给 shuttle 查询用
    # 源码项目名(shuttle 任务按源码包名记录):
    #   整套包模式用传入的项目名;单包模式取 dpkg 的 Source 字段,
    #   为空(二进制名==源码名)时取包自身名。总是写入 source: 行。
    DPKG_SRC=${DPKG_SRC%% (*}; DPKG_SRC=${DPKG_SRC%% *}
    SRC_OUT=${src_name:-$DPKG_SRC}
    [[ -z $SRC_OUT ]] && SRC_OUT=$PURE
    OUT_FILE=$append_to                      # 段统一追加到调用方建好的文件
    echo >> "$OUT_FILE"                      # 段间空行分隔
    {
        echo "package: $PURE"
        echo "version: $VER"
        echo "architecture: $ARCH"
        echo "source: $SRC_OUT"
        echo "host: $(hostname)"
        echo "date: $(date '+%F %T')"
        echo "# 以下每行: <md5>  <包内路径>  (来自 dpkg 数据库,即安装当刻的真实内容)"
        cat "$SUMS"
    } >> "$OUT_FILE"
    GEN_FILE=$OUT_FILE
}

# --------------------------- 逐项导出 ---------------------------------------
# 单个包模式:NAMES 即二进制包名,逐个导出;
# 整套包模式:NAMES 即源码项目名,先反查该项目下已安装的二进制包再逐个导出。
LIST=$(mktemp /tmp/export-pkg-md5.XXXXXX)
trap 'rm -f "$LIST"' EXIT

OK=0; SKIP=0; MADE=(); FAILED=()
for NAME in "${NAMES[@]}"; do
    if [[ $MODE == single ]]; then
        if export_one "$NAME" "" "$OUT_FILE"; then
            echo "  [OK]   $NAME  ->  $GEN_FILE"
            OK=$((OK+1))
        else
            echo "  [跳过] $NAME(未安装/状态异常/无 md5sums,见上方警告)"
            FAILED+=("$NAME")
            SKIP=$((SKIP+1))
        fi
    else
        # 全表扫描已安装包:凡 Source==NAME(或二进制名==NAME 且无 Source 字段)者入选。
        # -dbgsym 符号包不单独导出:shuttle 上符号包不是独立任务,而是随主包
        # 构建产物的附属(shuttle-download.sh 下载主包任务时会一并下载符号包)
        dpkg-query -W -f='${binary:Package}\t${Status}\t${Source}\n' 2>/dev/null \
        | awk -F'\t' -v name="$NAME" -v out="$LIST" -v dbg="$LIST.dbg" '
            $2 ~ /installed$/ {
                pkg=$1; src=$3; sub(/ [^ ]*$/,"",src); sub(/ \(.*$/,"",src)
                base=pkg; sub(/:.*/,"",base)
                if (src == name || (src == "" && base == name)) {
                    if (base ~ /-dbgsym$/) { print pkg > dbg; next }
                    print pkg > out
                }
            }'
        DBGSYM_CNT=$(wc -l < "$LIST.dbg" | tr -d ' ')

        if [[ ! -s $LIST ]]; then
            echo "  [跳过] 项目 [$NAME]: 本机没有已安装的属于该源码项目的二进制包"
            warn "项目模式只能覆盖本机已安装的包。可确认: dpkg-query -W -f='\${Source}\n' | sort -u | grep -w $NAME"
            FAILED+=("项目 $NAME")
            SKIP=$((SKIP+1))
            continue
        fi
        CNT=$(wc -l < "$LIST" | tr -d ' ')
        echo "── 项目 [$NAME]: 本机有 $CNT 个已安装的二进制包 ──"
        [[ $DBGSYM_CNT -gt 0 ]] && echo "   (另有 $DBGSYM_CNT 个 -dbgsym 符号包未导出:符号包随主包构建产物一起下载,无需单独查任务)"
        sort -o "$LIST" "$LIST"

        # 该项目全部包的指纹写入同一个时间戳命名文件;机器 B 上只需把这一个
        # 文件交给 shuttle-download.sh,即可解析并下载全部包(含符号包)
        PROJ_FILE=$(gen_fp_name)
        PROJ_OK=0
        {
            echo "# ============================================================"
            echo "# 整套包指纹文件 —— 源码项目: $NAME"
            echo "# 生成: $(date '+%F %T') @ $(hostname)"
            echo "# 包数: $CNT"
            echo "# 说明: 每个 'package:' 段为一个二进制包。机器 B 上执行:"
            echo "#     ./shuttle-download.sh $PROJ_FILE"
            echo "#   即自动解析本文件内全部包并逐个下载(符号包随主包附带下载)。"
            echo "# ============================================================"
        } > "$PROJ_FILE"
        while IFS= read -r pkg; do
            if export_one "$pkg" "$NAME" "$PROJ_FILE"; then
                echo "  [OK]   $pkg"
                OK=$((OK+1)); PROJ_OK=$((PROJ_OK+1))
            else
                echo "  [跳过] $pkg"
                FAILED+=("$pkg")
                SKIP=$((SKIP+1))
            fi
        done < "$LIST"
        if [[ $PROJ_OK -gt 0 ]]; then
            MADE+=("$PROJ_FILE")
        else
            rm -f "$PROJ_FILE"
            FAILED+=("项目 $NAME(所有包导出失败,已删除空文件)")
        fi
    fi
done

# 单包模式输出文件:有成功则记入产物清单;全部失败则删除空壳文件
if [[ $MODE == single && -n $OUT_FILE ]]; then
    if [[ $OK -gt 0 ]]; then
        MADE+=("$OUT_FILE")
    else
        rm -f "$OUT_FILE"
        warn "所有包导出失败,已删除空文件 $OUT_FILE"
    fi
fi

# --------------------------- 汇总 -------------------------------------------
echo "=============================================================="
if [[ $MODE == project ]]; then
    echo " 整套包模式,源码项目: ${NAMES[*]}"
else
    echo " 单个包模式: ${NAMES[*]}"
fi
echo " 导出成功: $OK 个;失败/跳过: $SKIP 个"
echo " 输出目录: $(pwd)"
if [[ ${#MADE[@]} -gt 0 ]]; then
    echo
    echo " 指纹文件(拷到机器 B 后执行: ./shuttle-download.sh <文件或目录>):"
    for f in "${MADE[@]}"; do echo "   $f"; done
fi
if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo
    echo " 未成功项(可用 dpkg -l | grep <关键词> 确认包名):"
    for f in "${FAILED[@]}"; do echo "   - $f"; done
fi
echo "=============================================================="
[[ $OK -gt 0 ]] || die "没有一个包导出成功"
exit 0
