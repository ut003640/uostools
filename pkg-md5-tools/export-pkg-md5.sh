#!/usr/bin/env bash
# ============================================================================
# export-pkg-md5.sh —— 机器 A 上运行
# 导出本机已安装 deb 包的 版本 / 架构 / 包内文件MD5 指纹,输出到文本文件。
# 之后把该文本文件拷到机器 B,配合 shuttle-download.sh 下载同一次构建的
# 安装包和符号包。
#
# 用法:
#   ./export-pkg-md5.sh                # 交互输入包名
#   ./export-pkg-md5.sh dde-dock       # 命令行指定包名(可带 :arch 限定)
#
# 无需 root:dpkg 数据库中 info/<pkg>.md5sums 普通用户可读。
# ============================================================================
set -euo pipefail

die() { echo "错误: $*" >&2; exit 1; }

# ---------- 输入包名 ----------
if [[ $# -ge 1 ]]; then
    PKG=$1
else
    read -rp "请输入要导出指纹的包名: " PKG
fi
[[ -n ${PKG// /} ]] || die "包名不能为空"

# ---------- 查询已安装的版本与架构 ----------
Q=$(dpkg-query -W -f='${Version}\n${Architecture}\n' "$PKG" 2>/dev/null) \
    || die "包 [$PKG] 未安装或查询失败(可用 dpkg -l | grep <关键词> 确认包名)"
VER=$(sed -n '1p' <<<"$Q")
ARCH=$(sed -n '2p' <<<"$Q")
[[ -n $VER && -n $ARCH ]] || die "无法解析版本/架构,dpkg-query 返回: $Q"

# ---------- 定位 md5sums(兼容多架构包的 :arch 后缀文件名) ----------
INFO=/var/lib/dpkg/info
SUMS=""
for cand in "$INFO/${PKG}.md5sums" "$INFO/${PKG}:${ARCH}.md5sums"; do
    [[ -f $cand ]] && { SUMS=$cand; break; }
done
if [[ -z $SUMS ]]; then
    # 最后按 "<pkg>:*.md5sums" 模糊匹配(仅在 :arch 变体存在时)
    SUMS=$(compgen -G "$INFO/${PKG%%:*}:*.md5sums" 2>/dev/null | head -1 || true)
fi
[[ -n $SUMS ]] || die "在 $INFO 下找不到 [$PKG] 的 md5sums 记录(包内可能没有普通文件)"

# ---------- 输出指纹文件 ----------
PURE_NAME=${PKG%%:*}          # 剥掉 :arch 限定,给 shuttle 查询用
OUT="${PURE_NAME}_${VER}_${ARCH}.fingerprint.txt"

{
    echo "package: $PURE_NAME"
    echo "version: $VER"
    echo "architecture: $ARCH"
    echo "host: $(hostname)"
    echo "date: $(date '+%F %T')"
    echo "# 以下每行: <md5>  <包内路径>  (来自 dpkg 数据库,即安装当刻的真实内容)"
    cat "$SUMS"
} > "$OUT"

echo "=============================================================="
echo " 包名:    $PURE_NAME"
echo " 版本:    $VER"
echo " 架构:    $ARCH"
echo " 文件数:  $(grep -c '^' "$SUMS")"
echo " 输出:    $(realpath -e "$OUT" || echo "$OUT")"
echo "=============================================================="
echo "请将该文件发给开发人员