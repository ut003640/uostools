#!/usr/bin/env bash
# ============================================================================
# collect-crash.sh —— 收集 coredump 崩溃堆栈
# 基于 systemd-coredump:逐条导出 coredumpctl 记录的崩溃堆栈,
# 一个堆栈一个文件,统一放到 脚本目录/<机器名>-crash/ 下。
#
# 用法:
#   ./collect-crash.sh
#       不带进程名:导出系统上所有的崩溃堆栈
#   ./collect-crash.sh <进程名> [更多进程名...]
#       只收集指定进程的崩溃堆栈(匹配规则同 coredumpctl:
#       进程名或可执行文件路径均可,如 dde-dock 或 /usr/bin/dde-dock)
#
# 输出(全部位于脚本所在目录的 <机器名>-crash/ 下):
#   coredump-list.txt                          # 总预览,即 coredumpctl list 的内容
#   <进程名>-<崩溃时间>-<崩溃PID>.log          # 每条崩溃记录一个堆栈文件
#       崩溃时间格式: YYYY-MM-DD_HH-MM-SS
#
# 堆栈来源(按优先级):
#   1. 本机装有 gdb 且 core 文件可用:导出 core 后用 gdb
#      "thread apply all bt" 生成全线程堆栈(最完整);
#   2. 否则保存 coredumpctl info 的完整输出
#      (systemd-coredump 崩溃时若记录过 backtrace,其中会包含堆栈)。
#
# 注意:
#   - 普通用户只能看到/导出自己权限范围内的 coredump;
#     需要收集其他用户或系统服务的崩溃时,请用 sudo 运行本脚本。
#   - 同一 PID 数字被复用且有多条崩溃记录时,coredumpctl 只能定位
#     最新一条,较旧条目会在文件头部注明"内容实际来自的记录时间"。
#
# 依赖: bash、coredumpctl(systemd-coredump);可选 gdb(堆栈更完整)。
# ============================================================================
set -uo pipefail

export LC_ALL=C

die() { echo "[$PROG_NAME] 错误: $*" >&2; exit 1; }
warn() { echo "[$PROG_NAME] 警告: $*" >&2; }
info() { echo "[$PROG_NAME] $*"; }

PROG_NAME="$(basename -- "$0")"

usage() {
    cat <<'EOF'
用法: ./collect-crash.sh [进程名 ...]

  不带参数        导出系统上所有的崩溃堆栈
  带进程名参数    只收集指定进程的崩溃堆栈(可传多个,
                  匹配规则同 coredumpctl:进程名或可执行文件路径)

输出(位于脚本所在目录 <机器名>-crash/ 下):
  coredump-list.txt                              总预览(coredumpctl list 内容)
  <进程名>-<崩溃时间>-<崩溃PID>.log              每条崩溃记录一个堆栈文件

提示: 需要收集其他用户或系统服务的崩溃时,请用 sudo 运行。
EOF
}

# ---------- 参数解析 ----------
if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

MATCHES=()
for arg in "$@"; do
    [[ -n "$arg" ]] && MATCHES+=("$arg")
done

# ---------- 环境检查 ----------
command -v coredumpctl >/dev/null 2>&1 \
    || die "未找到 coredumpctl,本脚本依赖 systemd-coredump(请确认系统启用并安装 systemd-coredump)"

if command -v gdb >/dev/null 2>&1; then
    HAVE_GDB=1
else
    HAVE_GDB=0
fi

# 脚本自身所在目录(解析符号链接与相对路径)
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)" \
    || die "无法确定脚本所在目录"

HOST_NAME="$(hostname 2>/dev/null || echo unknown-host)"
HOST_NAME="${HOST_NAME//[^A-Za-z0-9._-]/_}"
OUT_DIR="$SCRIPT_DIR/${HOST_NAME}-crash"
mkdir -p -- "$OUT_DIR" || die "无法创建输出目录: $OUT_DIR"

TMP_WORK="$(mktemp -d /tmp/collect-crash.XXXXXX)" || die "无法创建临时目录"
trap 'rm -rf -- "$TMP_WORK"' EXIT

# ---------- 1. 总预览: coredumpctl list ----------
LIST_FILE="$OUT_DIR/coredump-list.txt"
if ((${#MATCHES[@]})); then
    coredumpctl list --no-pager "${MATCHES[@]}" >"$LIST_FILE" 2>"$TMP_WORK/list.err"
else
    coredumpctl list --no-pager >"$LIST_FILE" 2>"$TMP_WORK/list.err"
fi
LIST_RC=$?

# 判断预览里有没有真实记录行(含 "YYYY-MM-DD HH:MM:SS")
if ! grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}[ ]+[0-9]{2}:[0-9]{2}:[0-9]{2}' "$LIST_FILE"; then
    rm -f -- "$LIST_FILE"
    rmdir -- "$OUT_DIR" 2>/dev/null
    if [[ -s "$TMP_WORK/list.err" ]]; then
        warn "$(cat "$TMP_WORK/list.err")"
    fi
    if (( LIST_RC != 0 )) && (( EUID != 0 )); then
        die "没有匹配的 coredump 记录(退出码 $LIST_RC)。若需要收集其他用户/系统服务的崩溃,请用 sudo 重试;当前用户权限下可能看不到全部记录"
    fi
    die "没有匹配的 coredump 记录(退出码 $LIST_RC),未生成任何文件"
fi

# ---------- 2. 逐条导出堆栈 ----------
declare -A SEEN_PID=()     # pid -> 首次出现的行时间,用于识别 PID 复用
TOTAL=0 OK_GDB=0 OK_INFO=0 SKIPPED=0

# 从 coredumpctl info 输出中提取 "字段名: 值"
info_field() {   # $1=info文件  $2=字段名(如 Executable) -> stdout: 值
    sed -n -E "s/^[[:space:]]*$2:[[:space:]]*(.*)$/\1/p" "$1" | head -n 1
}

# 由可执行文件路径得到用于文件名的进程名(剥离 (deleted),替换非法字符)
exe_to_name() {  # $1=exe -> stdout: sanitized 名字
    local n="${1% (deleted)}"
    n="$(basename -- "$n" 2>/dev/null || echo "$n")"
    [[ -n "$n" && "$n" != "." && "$n" != "/" ]] || n="unknown"
    n="${n//[^A-Za-z0-9._-]/_}"
    echo "$n"
}

# 时间 "2026-11-19 10:23:45" -> 文件名用 "2026-11-19_10-23-45"
stamp_for_name() {
    echo "${1// /_}" | tr ':' '-'
}

while IFS= read -r line; do
    # 提取 "YYYY-MM-DD HH:MM:SS"(coredumpctl list 每条记录的时间列)
    stamp="$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}[ ]+[0-9]{2}:[0-9]{2}:[0-9]{2}' <<<"$line" | head -n 1)"
    [[ -n "$stamp" ]] || continue   # 跳过表头/空行/提示行
    TOTAL=$((TOTAL + 1))

    # 截掉时间及之前的部分,剩下的依次是: [时区] PID UID GID SIG COREFILE EXE...
    rest="${line#*"$stamp"}"
    read -r -a toks <<<"$rest"

    # 第一个纯数字字段即 PID(时区缺失/存在两种情况都兼容)
    idx=-1
    for i in "${!toks[@]}"; do
        if [[ "${toks[i]}" =~ ^[0-9]+$ ]]; then idx=$i; break; fi
    done
    if (( idx < 0 || ${#toks[@]} < idx + 5 )); then
        warn "跳过无法解析的记录行: $line"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    pid="${toks[idx]}"
    sig="${toks[idx+3]}"
    coreflag="${toks[idx+4]}"
    exe_list="${toks[*]:$((idx+5))}"    # EXE 列(可能含空格,取剩余全部)

    # coredumpctl info: 拿准确的 Executable / Command Line / Timestamp
    INFO_FILE="$TMP_WORK/info.$pid.txt"
    coredumpctl info --no-pager "$pid" >"$INFO_FILE" 2>/dev/null

    exe="$(info_field "$INFO_FILE" 'Executable')"
    [[ -n "$exe" ]] || exe="$exe_list"
    exe="${exe% (deleted)}"
    cmdline="$(info_field "$INFO_FILE" 'Command Line')"
    stamp_info="$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}[ ]+[0-9]{2}:[0-9]{2}:[0-9]{2}' "$INFO_FILE" 2>/dev/null | head -n 1)"

    proc_name="$(exe_to_name "$exe")"
    crash_time="$(stamp_for_name "$stamp")"

    # PID 复用检测: info 对应记录的时间与列表行时间不一致,或该 PID 已处理过
    PID_REUSED=0
    if [[ -n "$stamp_info" && "$stamp_info" != "$stamp" ]]; then
        PID_REUSED=1
    elif [[ -n "${SEEN_PID[$pid]:-}" ]]; then
        PID_REUSED=1
    fi
    SEEN_PID[$pid]="$stamp"

    # 目标文件名: 进程名-崩溃时间-崩溃PID.log
    LOG_FILE="$OUT_DIR/${proc_name}-${crash_time}-${pid}.log"
    if [[ -e "$LOG_FILE" ]]; then
        n=1
        while [[ -e "$OUT_DIR/${proc_name}-${crash_time}-${pid}-dup${n}.log" ]]; do n=$((n+1)); done
        LOG_FILE="$OUT_DIR/${proc_name}-${crash_time}-${pid}-dup${n}.log"
    fi

    # 文件头(元数据)
    header() {
        cat <<EOF
============================================================
进程名     : $proc_name
崩溃 PID   : $pid
崩溃时间   : $stamp
信号       : $sig
可执行文件 : $exe
命令行     : $cmdline
Core 状态  : $coreflag
生成方式   : $1
============================================================
EOF
        if (( PID_REUSED )); then
            cat <<EOF
注意: PID $pid 在 coredumpctl 中存在多条记录,只能定位最新一条;
      本文件内容实际来自记录时间: ${stamp_info:-未知}。
------------------------------------------------------------
EOF
        fi
    }

    # 路径 A: gdb 解析 core,生成全线程堆栈
    done_gdb=0
    GDB_FAIL_OUT=""
    if (( HAVE_GDB )) && [[ "$coreflag" == "present" && -n "$exe" && "$exe" != "unknown" ]]; then
        CORE_FILE="$TMP_WORK/core.$pid.bin"
        if coredumpctl dump "$pid" >"$CORE_FILE" 2>/dev/null \
           && [[ -s "$CORE_FILE" ]] \
           && [[ "$(head -c 4 "$CORE_FILE" 2>/dev/null)" == $'\x7fELF' ]]; then
            # gdb 退出码为 0 不代表分析成功(如 exe/core 不匹配时可能只输出错误信息),
            # 还需确认输出里确实有 backtrace 帧(^#N)
            if timeout 180 gdb -q -batch \
                   -ex "set pagination off" \
                   -ex "set confirm off" \
                   -ex "set print thread-events off" \
                   -ex "thread apply all bt" \
                   -- "$exe" "$CORE_FILE" >"$TMP_WORK/gdb.$pid.out" 2>&1 \
               && grep -qE '^#[0-9]+[[:space:]]' "$TMP_WORK/gdb.$pid.out"; then
                header "coredumpctl dump + gdb (thread apply all bt)" >"$LOG_FILE"
                cat "$TMP_WORK/gdb.$pid.out" >>"$LOG_FILE"
                OK_GDB=$((OK_GDB + 1))
                done_gdb=1
            else
                GDB_FAIL_OUT="$TMP_WORK/gdb.$pid.out"   # 回退时附加诊断
            fi
        fi
    fi

    # 路径 B: 回退保存 coredumpctl info 完整输出
    if (( ! done_gdb )); then
        if [[ -s "$INFO_FILE" ]]; then
            if (( HAVE_GDB )); then
                reason="coredumpctl info(core 不可用或 gdb 未能解析出堆栈,可能无符号堆栈)"
            else
                reason="coredumpctl info(未安装 gdb,可能无符号堆栈;安装 gdb 后重跑可获得完整堆栈)"
            fi
            header "$reason" >"$LOG_FILE"
            cat "$INFO_FILE" >>"$LOG_FILE"
            if [[ -n "$GDB_FAIL_OUT" && -s "$GDB_FAIL_OUT" ]]; then
                {
                    echo
                    echo "------------------------------------------------------------"
                    echo "gdb 分析输出(无效/失败,仅作诊断参考):"
                    cat "$GDB_FAIL_OUT"
                } >>"$LOG_FILE"
            fi
            OK_INFO=$((OK_INFO + 1))
        else
            warn "PID $pid 的 coredumpctl info 获取失败,仅记录列表信息"
            header "coredumpctl list 列表行(info 获取失败)" >"$LOG_FILE"
            echo "$line" >>"$LOG_FILE"
            OK_INFO=$((OK_INFO + 1))
        fi
    fi

    info "已导出: $(basename -- "$LOG_FILE")"
done <"$LIST_FILE"

# ---------- 3. 汇总 ----------
echo
info "完成: 共 $TOTAL 条记录 -> gdb 堆栈 $OK_GDB 个, info 回退 $OK_INFO 个, 解析跳过 $SKIPPED 条"
info "输出目录: $OUT_DIR"
if (( ! HAVE_GDB )); then
    warn "本机未安装 gdb: 已回退为 coredumpctl info 输出,可能不含符号堆栈;安装 gdb(apt install gdb)后重新运行可获得全线程 backtrace"
fi
if (( EUID != 0 )); then
    info "提示: 当前为普通用户,只能看到自己权限范围内的 coredump;如需收集其他用户/系统服务的崩溃,请用 sudo 重跑"
fi
