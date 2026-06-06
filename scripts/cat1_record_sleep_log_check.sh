#!/usr/bin/env bash
# 录像 + 休眠（HOSTEVT）联调日志自动检查
# 用法见 --help；典型：
#   ./tests/cat1_record_sleep_log_check.sh /tmp/cat1_uart.log /var/log/messages
#   adb shell cat /tmp/cat1_uart.log | ssh host ./cat1_record_sleep_log_check.sh -

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
STRICT=0
VERBOSE=0
LOG_FILES=()

usage() {
    cat <<'EOF'
Usage: cat1_record_sleep_log_check.sh [options] LOG [LOG ...]

在「一次录像会话」时间窗内检查 IPC(T31) + 4G 日志，验证 v1.4 行为：
  - 录像中空闲轮询不误停录（无异常 PIR retrigger/stop）
  - 录像中 HOSTIDLE 应 BUSY / record block sleep，不应 accept 断电
  - 可选：出现 record session active / HOSTIDLE busy 保护日志

时间窗：从首次「开录」标记到首次「AT+RECORD=0 / 停录」标记。
若无开录标记，则对全文做弱检查（仅统计，不判 FAIL）。

Options:
  --strict     无「block sleep」保护日志时也 WARN（默认仅提示）
  -v, --verbose  打印命中行
  -h, --help   显示帮助

日志来源示例（T31）:
  syscfg cat1 uart_log_path=/tmp/cat1_uart.log
  串口抓取、/var/log/messages、dmesg 重定向

日志来源示例（4G）:
  Luat 串口日志、host_uart AT  trace

开录标记（任一命中即开窗）:
  record_start | AT+RECORD=1 | RECORD notify sent: AT+RECORD=1
  录像会话开始 | t3x_active | publishPirRecordActive

关窗标记:
  AT+RECORD=0 | record_stop | publishPirRecordStop | 录像.*停

窗内 FAIL（任一条即失败）:
  PIR retrigger/stop path        （无真实二次 PIR 时误停录）
  HOSTIDLE accepted            （录像中 T31 请求休眠被 4G 接受断电）
  +HOSTIDLE:OK                 （紧跟 AT+HOSTIDLE=1 且窗内无 BUSY — 见脚本逻辑）

窗内 PASS 信号（至少一条建议出现，hostevt_sleep 开启时）:
  record session active, block sleep only
  HOSTIDLE busy | +HOSTIDLE:BUSY

Exit code: 0=通过  1=失败  2=用法/无输入
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --strict) STRICT=1; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -) LOG_FILES+=("/dev/stdin"); shift ;;
        --) shift; break ;;
        -*) echo "$SCRIPT_NAME: 未知选项: $1" >&2; usage >&2; exit 2 ;;
        *) LOG_FILES+=("$1"); shift ;;
    esac
done

while [[ $# -gt 0 ]]; do
    LOG_FILES+=("$1")
    shift
done

if [[ ${#LOG_FILES[@]} -eq 0 ]]; then
    echo "$SCRIPT_NAME: 请至少指定一个日志文件，或使用 - 读 stdin" >&2
    usage >&2
    exit 2
fi

TMP_MERGED=""
cleanup() {
    [[ -n "$TMP_MERGED" && -f "$TMP_MERGED" ]] && rm -f "$TMP_MERGED"
}
trap cleanup EXIT

TMP_MERGED="$(mktemp /tmp/cat1_rec_sleep_check.XXXXXX)"
: >"$TMP_MERGED"

for f in "${LOG_FILES[@]}"; do
    if [[ "$f" == "/dev/stdin" ]]; then
        cat >>"$TMP_MERGED"
    elif [[ -r "$f" ]]; then
        {
            echo "===== FILE: $f ====="
            cat "$f"
        } >>"$TMP_MERGED"
    else
        echo "$SCRIPT_NAME: 无法读取: $f" >&2
        exit 2
    fi
done

if [[ ! -s "$TMP_MERGED" ]]; then
    echo "$SCRIPT_NAME: 日志为空" >&2
    exit 2
fi

# Awk 分析：返回 KEY=value 行供 bash 解析
AWK_REPORT="$(mktemp /tmp/cat1_rec_sleep_awk.XXXXXX)"
awk '
BEGIN {
    in_rec = 0
    rec_start_line = 0
    rec_windows = 0
    bad_retrigger = 0
    bad_idle_ok = 0
    bad_hostidle_ok_at = 0
    good_block_sleep = 0
    good_hostidle_busy = 0
    hostidle_req = 0
    hostidle_busy_after_req = 0
    last_hostidle_req_line = 0
}

function is_record_start(line) {
    return (line ~ /record_start/ \
        || line ~ /AT\+RECORD=1/ \
        || line ~ /RECORD notify sent: AT\+RECORD=1/ \
        || line ~ /录像会话开始/ \
        || line ~ /t3x_active/ \
        || line ~ /publishPirRecordActive/ \
        || line ~ /\[CAT1\].*record_start/)
}

function is_record_end(line) {
    return (line ~ /AT\+RECORD=0/ \
        || line ~ /RECORD notify sent: AT\+RECORD=0/ \
        || line ~ /record_stop/ \
        || line ~ /publishPirRecordStop/ \
        || line ~ /录像.*停录/)
}

function is_legit_retrigger_context(line) {
    return (line ~ /pir_retrigger/ \
        || line ~ /二次 PIR/ \
        || line ~ /PIR停录/ \
        || line ~ /requestT3xStopRecord/ \
        || line ~ /PIR_REQUEST_T3X_STOP/)
}

{
    line = $0
    if (!in_rec && is_record_start(line)) {
        in_rec = 1
        rec_windows++
        rec_start_line = NR
    }
    if (in_rec && is_record_end(line)) {
        in_rec = 0
    }

    if (in_rec) {
        if (line ~ /PIR retrigger\/stop path/) {
            if (!is_legit_retrigger_context(line)) {
                bad_retrigger++
                if (verbose) print "BAD_RETRIGGER_LINE:" NR ":" line > "/dev/stderr"
            }
        }
        if (line ~ /record session active, block sleep only/) {
            good_block_sleep++
        }
        if (line ~ /HOSTIDLE busy/ || line ~ /\+HOSTIDLE:BUSY/) {
            good_hostidle_busy++
        }
        if (line ~ /HOSTIDLE accepted/ || (line ~ /\+HOSTIDLE:OK/ && line !~ /HOSTIDLE=0/)) {
            bad_idle_ok++
        }
        if (line ~ /AT\+HOSTIDLE=1/) {
            hostidle_req++
            last_hostidle_req_line = NR
            hostidle_busy_after_req = 0
        }
        if (hostidle_req > 0 && NR <= last_hostidle_req_line + 3 \
            && (line ~ /\+HOSTIDLE:BUSY/ || line ~ /HOSTIDLE busy/)) {
            hostidle_busy_after_req = 1
        }
        if (hostidle_req > 0 && NR <= last_hostidle_req_line + 3 && line ~ /\+HOSTIDLE:OK/) {
            bad_hostidle_ok_at++
        }
    }
}

END {
    print "rec_windows=" rec_windows
    print "bad_retrigger=" bad_retrigger
    print "bad_idle_ok=" bad_idle_ok
    print "bad_hostidle_ok_at=" bad_hostidle_ok_at
    print "good_block_sleep=" good_block_sleep
    print "good_hostidle_busy=" good_hostidle_busy
    print "hostidle_req_in_rec=" hostidle_req
}
' verbose="$VERBOSE" "$TMP_MERGED" >"$AWK_REPORT"

declare -A M=()
while IFS='=' read -r k v; do
    [[ -n "$k" ]] && M["$k"]="$v"
done <"$AWK_REPORT"
rm -f "$AWK_REPORT"

FAIL=0
WARN=0

echo "========================================"
echo " 录像 + 休眠 日志检查  ($SCRIPT_NAME)"
echo "========================================"
echo "日志文件: ${LOG_FILES[*]}"
echo "合并行数: $(wc -l <"$TMP_MERGED" | tr -d ' ')"
echo ""

if [[ "${M[rec_windows]:-0}" -eq 0 ]]; then
    echo "[WARN] 未检测到录像时间窗（无开录标记），仅做全文弱统计："
    echo "  PIR retrigger/stop path 次数: $(grep -c 'PIR retrigger/stop path' "$TMP_MERGED" 2>/dev/null || echo 0)"
    echo "  record session active 次数: $(grep -c 'record session active, block sleep only' "$TMP_MERGED" 2>/dev/null || echo 0)"
    echo "  HOSTIDLE BUSY 次数: $(grep -Ec 'HOSTIDLE busy|\+HOSTIDLE:BUSY' "$TMP_MERGED" 2>/dev/null || echo 0)"
    echo ""
    echo "建议：抓取含 PIR 触发录像的完整日志后重跑。"
    exit 0
fi

echo "检测到录像时间窗: ${M[rec_windows]} 段"
echo ""
echo "--- 窗内指标 ---"
echo "  [应=0] 误停录 (PIR retrigger/stop path):     ${M[bad_retrigger]:-0}"
echo "  [应=0] 录像中 HOSTIDLE 被接受 (accepted/OK): ${M[bad_idle_ok]:-0}"
echo "  [应=0] AT+HOSTIDLE=1 后直连 OK(无 BUSY):     ${M[bad_hostidle_ok_at]:-0}"
echo "  [宜≥1] record block sleep 保护:              ${M[good_block_sleep]:-0}"
echo "  [宜≥1] HOSTIDLE BUSY 保护:                  ${M[good_hostidle_busy]:-0}"
echo "  [参考] 窗内 AT+HOSTIDLE=1 次数:              ${M[hostidle_req_in_rec]:-0}"
echo ""

if [[ "${M[bad_retrigger]:-0}" -gt 0 ]]; then
    echo "[FAIL] 录像窗内出现误停录路径（v1.4 应跳过 record dispatch）"
    FAIL=1
    if [[ "$VERBOSE" -eq 0 ]]; then
        echo "  提示: 加 -v 查看行号，或: grep -n 'PIR retrigger/stop path' ${LOG_FILES[*]}"
    fi
fi

if [[ "${M[bad_idle_ok]:-0}" -gt 0 || "${M[bad_hostidle_ok_at]:-0}" -gt 0 ]]; then
    echo "[FAIL] 录像进行中 T3x/4G 接受了 HOSTIDLE 断电请求"
    FAIL=1
fi

if [[ "${M[good_block_sleep]:-0}" -eq 0 && "${M[good_hostidle_busy]:-0}" -eq 0 ]]; then
    if [[ "${M[hostidle_req_in_rec]:-0}" -gt 0 ]]; then
        echo "[WARN] 窗内有 HOSTIDLE 请求但未见到 BUSY/block 保护日志"
        WARN=1
    else
        echo "[INFO] 窗内未触发 HOSTIDLE（可能 hostevt_sleep 未开或未空闲到 1s）"
    fi
    if [[ "$STRICT" -eq 1 ]]; then
        echo "[FAIL] --strict: 要求出现 block sleep 或 HOSTIDLE BUSY 保护日志"
        FAIL=1
    fi
fi

if [[ "$VERBOSE" -eq 1 ]]; then
    echo ""
    echo "--- 相关原文摘录 ---"
    grep -n -E 'record_start|AT\+RECORD|PIR retrigger|record session active|HOSTIDLE|录像会话' "$TMP_MERGED" | head -80 || true
fi

echo ""
if [[ "$FAIL" -ne 0 ]]; then
    echo "结果: 未通过"
    exit 1
fi
if [[ "$WARN" -ne 0 ]]; then
    echo "结果: 通过（有警告）"
    exit 0
fi
echo "结果: 通过"
exit 0
