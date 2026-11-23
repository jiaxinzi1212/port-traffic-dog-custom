#!/usr/bin/env bash
# AUTOPYTHON3_V2_20261121: versioned installer entrypoint (bypass stale raw cache).
# Port Traffic Dog custom install: pinned official v1.4.4 plus compact DingTalk/Webhook status layout.
# This package contains the format patch; users do not need to upload a separate Python file.
set -Eeuo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '[port-traffic-dog] %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || fail 'Run with root permissions (sudo bash ...)'
command -v bash >/dev/null 2>&1 || fail 'Bash is required.'

# Minimal Debian/Ubuntu VPS images may omit Python 3. Install it only when absent.
# Python is needed by this installer to apply the built-in message-format patch;
# it is not required for running the final Bash monitoring script.
if ! command -v python3 >/dev/null 2>&1; then
    if [ -x /usr/bin/python3 ]; then
        export PATH="/usr/bin:$PATH"
    else
        info 'Python 3 is missing; checking whether apt-get can install it ...'
        [ -r /etc/os-release ] || fail 'Unable to identify the OS; please install python3 manually.'
        . /etc/os-release
        case "${ID:-}" in
            debian|ubuntu) ;;
            *) fail "Auto-install is limited to Debian/Ubuntu (detected: ${ID:-unknown}). Install python3 manually." ;;
        esac
        command -v apt-get >/dev/null 2>&1 || fail 'apt-get is unavailable; please install python3 manually.'
        export DEBIAN_FRONTEND=noninteractive
        info 'Running apt-get update ...'
        apt-get update -qq || fail 'apt-get update failed; please check DNS/network and apt repositories.'
        info 'Installing python3 ...'
        apt-get install -y --no-install-recommends python3 || fail 'Python 3 installation failed; inspect apt output above.'
    fi
fi
command -v python3 >/dev/null 2>&1 || fail 'Python 3 is still unavailable after installation.'

# Pin the audited upstream revision to avoid breaking changes on main.
UPSTREAM_COMMIT='96ab23e86b2f9ce16257e9e98b915fe8f2cb2d5b'
UPSTREAM_URL="https://raw.githubusercontent.com/zywe03/realm-xwPF/${UPSTREAM_COMMIT}/port-traffic-dog.sh"
# Git blob object SHA-1 for the pinned upstream file (not merely a version string).
UPSTREAM_BLOB_SHA1='eaf95ec972337d8d6c95737b50e27e2070a2875d'
INSTALL_PATH="${PTDOG_INSTALL_PATH:-/usr/local/bin/port-traffic-dog.sh}"
WRAPPER="${PTDOG_WRAPPER_PATH:-/usr/local/bin/dog}"

# Keep any existing dog wrapper pointing to the already-installed script.
# An original installation may be located under /root rather than /usr/local/bin.
if [ -z "${PTDOG_INSTALL_PATH:-}" ] && [ -f "$WRAPPER" ]; then
    existing_target=$(sed -nE 's#^exec bash "([^"]+)" "\$@"$#\1#p' "$WRAPPER" | head -n1)
    if [ -z "$existing_target" ]; then
        fail "Existing $WRAPPER does not match the official wrapper; refusing to overwrite it."
    fi
    case "$existing_target" in
        /*) INSTALL_PATH="$existing_target" ;;
        *) fail 'Existing shortcut points to a non-absolute target.' ;;
    esac
fi

case "$INSTALL_PATH" in
  /*) ;;
  *) fail 'Install path must be absolute.' ;;
esac
if [ "$INSTALL_PATH" = "$WRAPPER" ]; then
    fail 'Install path cannot be /usr/local/bin/dog.'
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
original="$workdir/port-traffic-dog.sh"

info 'Downloading official upstream port-traffic-dog.sh ...'
if [ -n "${PTDOG_SOURCE_FILE:-}" ]; then
    cp -- "$PTDOG_SOURCE_FILE" "$original"
elif command -v curl >/dev/null 2>&1; then
    curl --fail --location --silent --show-error --retry 2 \
      --connect-timeout 10 --max-time 90 "$UPSTREAM_URL" -o "$original"
elif command -v wget >/dev/null 2>&1; then
    wget --quiet --timeout=90 -O "$original" "$UPSTREAM_URL"
else
    fail 'Requires curl or wget to download upstream script.'
fi

[ -s "$original" ] || fail 'Downloaded file is empty.'
command -v sha1sum >/dev/null 2>&1 || fail 'sha1sum (coreutils) is required.'
actual_blob_sha1=$(
    { printf 'blob %s\0' "$(wc -c < "$original")"; cat "$original"; } |
    sha1sum | awk '{print $1}'
)
[ "$actual_blob_sha1" = "$UPSTREAM_BLOB_SHA1" ] || \
    fail 'Pinned upstream file content does not match audited Git object; no installation performed.'
grep -Fqx 'readonly SCRIPT_VERSION="1.4.4"' "$original" ||
    fail 'Pinned upstream is not expected v1.4.4; no installation performed.'

grep -q '^format_text_status_message() {' "$original" || \
    fail 'Missing text status formatter in upstream.'
grep -q '^format_markdown_status_message() {' "$original" || \
    fail 'Missing markdown status formatter in upstream.'

info 'Applying integrated compact status notification template ...'
python3 - "$original" <<'PY_STYLE'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Only replace port-traffic-dog.sh's Webhook text-status formatter."""
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

STYLE = r"""format_text_status_message() {
    # CUSTOM_DINGTALK_STYLE_2026_V1: 只调整 Webhook 文本内容，不改变计数/发送/定时逻辑
    local server_name="${1:-$(hostname)}"
    local timestamp
    timestamp=$(get_beijing_time '+%Y-%m-%d %H:%M:%S')
    local line="──────────────────────────────"

    local active_ports=()
    mapfile -t active_ports < <(get_monitored_ports)
    local port_count=${#active_ports[@]}
    local daily_total
    daily_total=$(get_daily_total_traffic)

    printf '🖥️ 服务器：%s\n🕒 汇报时间：%s\n\n' "$server_name" "$timestamp"
    printf '🌐 整机总流量\n'

    # 沿用原脚本的整机统计口径：双向模式 m_rx/m_tx 均乘 2
    local ifaces=()
    mapfile -t ifaces < <(get_vps_interface_names)
    local vps_billing_mode vps_data
    vps_billing_mode=$(jq -r --arg v "$VPS_PORT_ID" \
        '.ports[$v].billing_mode // "double"' "$CONFIG_FILE")
    vps_data=$(vps_read_data)

    if [ ${#ifaces[@]} -eq 0 ]; then
        printf '暂无可统计网卡\n'
    fi

    local iface rx tx input_bytes output_bytes total_bytes
    for iface in "${ifaces[@]}"; do
        rx=$(printf '%s' "$vps_data" | jq -r --arg i "$iface" \
            '.monthly.ifaces[$i].rx_bytes // 0' 2>/dev/null || echo 0)
        tx=$(printf '%s' "$vps_data" | jq -r --arg i "$iface" \
            '.monthly.ifaces[$i].tx_bytes // 0' 2>/dev/null || echo 0)
        [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
        [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
        input_bytes=0
        output_bytes=0
        if [ "$vps_billing_mode" = "double" ]; then
            input_bytes=$((rx * 2))
            output_bytes=$((tx * 2))
        else
            output_bytes=$tx
        fi
        total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$vps_billing_mode")
        printf '🔹 %s | 总流量：%s\n' "$iface" "$(format_bytes "$total_bytes")"
        printf '⬆️ 入站：%s | ⬇️ 出站：%s\n' \
            "$(format_bytes "$input_bytes")" "$(format_bytes "$output_bytes")"
    done

    printf '%s\n' "$line"
    printf '🟢 状态：监控中 | 监控项：%s个\n' "$port_count"
    printf '📊 端口总流量：%s\n' "$daily_total"
    printf '%s\n' "$line"

    if [ "$port_count" -eq 0 ]; then
        printf '暂无监控端口\n%s\n' "$line"
        return 0
    fi

    local port remark billing_mode quota_enabled quota bandwidth_enabled rate reset_day expiry
    local quota_label quota_display rate_display reset_display status_label
    local traffic_data=() meta=()
    for port in "${active_ports[@]}"; do
        traffic_data=($(get_nftables_counter_data "$port"))
        input_bytes="${traffic_data[0]:-0}"
        output_bytes="${traffic_data[1]:-0}"
        [[ "$input_bytes" =~ ^[0-9]+$ ]] || input_bytes=0
        [[ "$output_bytes" =~ ^[0-9]+$ ]] || output_bytes=0

        # 直接读取原配置字段，空备注与 false 不会被 tab 分隔吞掉
        meta=()
        mapfile -t meta < <(jq -r --arg p "$port" '
            (.ports[$p] // {}) as $c |
            [
                ($c.remark // "" | tostring | gsub("[\r\n\t]"; " ")),
                ($c.billing_mode // "double"),
                (if $c.quota.enabled == false then "false" else "true" end),
                ($c.quota.monthly_limit // "unlimited"),
                ($c.quota.reset_day // ""),
                (if $c.bandwidth_limit.enabled == true then "true" else "false" end),
                ($c.bandwidth_limit.rate // "unlimited"),
                ($c.expiry.expire_date // "")
            ] | .[] | tostring
        ' "$CONFIG_FILE")
        remark="${meta[0]:-无}"
        [ -n "$remark" ] || remark="无"
        billing_mode="${meta[1]:-double}"
        quota_enabled="${meta[2]:-true}"
        quota="${meta[3]:-unlimited}"
        reset_day="${meta[4]:-}"
        bandwidth_enabled="${meta[5]:-false}"
        rate="${meta[6]:-unlimited}"
        expiry="${meta[7]:-}"

        total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")
        if [ "$billing_mode" = "double" ]; then
            quota_label="双向额度"
        else
            quota_label="单向额度"
        fi
        if [ "$quota_enabled" != "true" ]; then
            quota_display="未启用"
        elif [ "$quota" = "unlimited" ]; then
            quota_display="无限制"
        else
            quota_display="$quota"
        fi
        if [ "$bandwidth_enabled" = "true" ] && [ "$rate" != "unlimited" ]; then
            rate_display="$rate"
        else
            rate_display="不限速"
        fi
        reset_display="未设置"
        if [ "$quota_enabled" = "true" ] && [ "$quota" != "unlimited" ] &&
           [[ "$reset_day" =~ ^[0-9]+$ ]] &&
           [ "$reset_day" -ge 1 ] && [ "$reset_day" -le 31 ]; then
            reset_display="每月${reset_day}日"
        fi

        printf '\n🔌 %s\n' "$(get_port_display_name "$port")"
        printf '📊 总流量：%s\n' "$(format_bytes "$total_bytes")"
        printf '⬆️ 入站：%s | ⬇️ 出站：%s\n' \
            "$(format_bytes "$input_bytes")" "$(format_bytes "$output_bytes")"
        printf '📝 备注：%s\n' "$remark"
        printf '📦 %s：%s | ⚡ 限速：%s\n' \
            "$quota_label" "$quota_display" "$rate_display"
        printf '🔄 重置日期：%s\n' "$reset_display"

        # 不移除原来的重要告警（额度耗尽、截止日期）
        status_label=$(get_port_status_label "$port")
        if [[ "$status_label" == *"[已超限]"* ]]; then
            printf '⚠️ 流量已超限\n'
        fi
        if [[ "$status_label" == *"[已截止]"* ]]; then
            printf '⚠️ 已截止：%s\n' "${expiry:-未提供日期}"
        elif [ -n "$expiry" ] && [ "$expiry" != "null" ]; then
            printf '🗓️ 截止日期：%s\n' "$expiry"
        fi
        printf '%s\n' "$line"
    done
}
"""

def locate_script():
    candidates = []
    wrapper = shutil.which("dog")
    if wrapper:
        p = Path(wrapper)
        try:
            data = p.read_text(encoding="utf-8", errors="replace")
            m = re.search(r'(?m)^\s*exec\s+bash\s+"([^"]+)"\s+"\$@"', data)
            if m:
                candidates.append(Path(m.group(1)))
        except OSError:
            pass
        candidates.append(p)
    candidates += [
        Path("/usr/local/bin/port-traffic-dog.sh"),
        Path("/root/port-traffic-dog.sh"),
        Path.cwd() / "port-traffic-dog.sh",
    ]
    for p in candidates:
        try:
            data = p.read_text(encoding="utf-8")
            if "format_text_status_message() {" in data and \
               "format_markdown_status_message() {" in data and \
               "端口流量狗" in data:
                return p.resolve()
        except (OSError, UnicodeError):
            pass
    raise RuntimeError("找不到端口流量狗主脚本。请执行 command -v dog 并查看其中的脚本路径。")

def main():
    if os.geteuid() != 0:
        sys.exit("请使用 root 权限运行：sudo python3 ...")
    script = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else locate_script()
    original = script.read_text(encoding="utf-8")
    pattern = re.compile(r'(?ms)^format_text_status_message\(\) \{\n.*?(?=^format_markdown_status_message\(\) \{)')
    matches = list(pattern.finditer(original))
    if len(matches) != 1:
        sys.exit("找不到唯一的原版文本通知函数，未修改任何文件。")
    if "CUSTOM_DINGTALK_STYLE_2026_V1" in matches[0].group():
        print(f"已应用过此格式，无需重复操作：{script}")
        return

    patched = original[:matches[0].start()] + STYLE + "\n" + original[matches[0].end():]
    backup = Path(str(script) + ".bak-style-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(script, backup)

    fd, tmp_name = tempfile.mkstemp(prefix=".port-dog-style-", dir=str(script.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(patched)
        os.chmod(tmp_name, stat.S_IMODE(script.stat().st_mode))
        completed = subprocess.run(["bash", "-n", tmp_name], capture_output=True, text=True)
        if completed.returncode != 0:
            raise RuntimeError("Bash 语法检查不通过：\n" + completed.stderr)
        os.replace(tmp_name, script)
    except Exception:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)
        raise

    print(f"成功：仅调整 Webhook 状态通知样式")
    print(f"主脚本：{script}")
    print(f"备份文件：{backup}")
    print("Bash 语法检查：通过")
    print("监控数据、nftables、限速、Webhook 密钥、定时任务均未修改。")
    print("可以执行：dog --send-webhook-status 测试钉钉通知。")
    print("注意：原脚本使用安装/更新功能后可能被上游版本覆盖，需要重打补丁。")

if __name__ == "__main__":
    main()

PY_STYLE

# The patch already verifies bash syntax; re-check the final file before installation.
bash -n "$original" || fail 'Bash syntax validation failed.'
grep -q 'CUSTOM_DINGTALK_STYLE_2026_V1' "$original" || \
    fail 'Template verification failed.'

mkdir -p "$(dirname "$INSTALL_PATH")" "$(dirname "$WRAPPER")"
if [ -e "$INSTALL_PATH" ]; then
    grep -q '端口流量狗' "$INSTALL_PATH" || \
        fail "Existing $INSTALL_PATH is not an official Port Traffic Dog script."
    backup="${INSTALL_PATH}.bak-custom-$(date +%Y%m%d-%H%M%S)"
    cp -a "$INSTALL_PATH" "$backup"
    info "Original executable backed up to: $backup"
fi

# Stage in destination directory and rename atomically (cron never sees a half-written script).
staged=$(mktemp "$(dirname "$INSTALL_PATH")/.port-dog-installed-XXXXXX")
trap 'rm -f "$staged"; rm -rf "$workdir"' EXIT
install -m 0755 "$original" "$staged"
mv -f "$staged" "$INSTALL_PATH"

# Preserve existing shortcut; create one only on fresh installations.
if [ ! -e "$WRAPPER" ]; then
    printf '#!/bin/bash\nexec bash "%s" "$@"\n' "$INSTALL_PATH" > "$WRAPPER"
    chmod 0755 "$WRAPPER"
fi

info "Installed customized script: $INSTALL_PATH"
info 'All future Webhook status reports use the compact template.'
info 'You still need to configure monitored ports and DingTalk Webhook in the dog menu.'
info 'Running upstream update from within the menu may overwrite this customization.'

if [ "${PTDOG_NO_START:-0}" = 1 ]; then
    info 'Validation mode: did not launch interactive menu.'
else
    exec bash "$INSTALL_PATH"
fi "$original" || \
    fail 'Pinned upstream is not expected v1.4.4; no installation performed.'

grep -q '^format_text_status_message() {' "$original" || \
    fail 'Missing text status formatter in upstream.'
grep -q '^format_markdown_status_message() {' "$original" || \
    fail 'Missing markdown status formatter in upstream.'

info 'Applying integrated compact status notification template ...'
python3 - "$original" <<'PY_STYLE'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Only replace port-traffic-dog.sh's Webhook text-status formatter."""
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

STYLE = r"""format_text_status_message() {
    # CUSTOM_DINGTALK_STYLE_2026_V1: 只调整 Webhook 文本内容，不改变计数/发送/定时逻辑
    local server_name="${1:-$(hostname)}"
    local timestamp
    timestamp=$(get_beijing_time '+%Y-%m-%d %H:%M:%S')
    local line="──────────────────────────────"

    local active_ports=()
    mapfile -t active_ports < <(get_monitored_ports)
    local port_count=${#active_ports[@]}
    local daily_total
    daily_total=$(get_daily_total_traffic)

    printf '🖥️ 服务器：%s\n🕒 汇报时间：%s\n\n' "$server_name" "$timestamp"
    printf '🌐 整机总流量\n'

    # 沿用原脚本的整机统计口径：双向模式 m_rx/m_tx 均乘 2
    local ifaces=()
    mapfile -t ifaces < <(get_vps_interface_names)
    local vps_billing_mode vps_data
    vps_billing_mode=$(jq -r --arg v "$VPS_PORT_ID" \
        '.ports[$v].billing_mode // "double"' "$CONFIG_FILE")
    vps_data=$(vps_read_data)

    if [ ${#ifaces[@]} -eq 0 ]; then
        printf '暂无可统计网卡\n'
    fi

    local iface rx tx input_bytes output_bytes total_bytes
    for iface in "${ifaces[@]}"; do
        rx=$(printf '%s' "$vps_data" | jq -r --arg i "$iface" \
            '.monthly.ifaces[$i].rx_bytes // 0' 2>/dev/null || echo 0)
        tx=$(printf '%s' "$vps_data" | jq -r --arg i "$iface" \
            '.monthly.ifaces[$i].tx_bytes // 0' 2>/dev/null || echo 0)
        [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
        [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
        input_bytes=0
        output_bytes=0
        if [ "$vps_billing_mode" = "double" ]; then
            input_bytes=$((rx * 2))
            output_bytes=$((tx * 2))
        else
            output_bytes=$tx
        fi
        total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$vps_billing_mode")
        printf '🔹 %s | 总流量：%s\n' "$iface" "$(format_bytes "$total_bytes")"
        printf '⬆️ 入站：%s | ⬇️ 出站：%s\n' \
            "$(format_bytes "$input_bytes")" "$(format_bytes "$output_bytes")"
    done

    printf '%s\n' "$line"
    printf '🟢 状态：监控中 | 监控项：%s个\n' "$port_count"
    printf '📊 端口总流量：%s\n' "$daily_total"
    printf '%s\n' "$line"

    if [ "$port_count" -eq 0 ]; then
        printf '暂无监控端口\n%s\n' "$line"
        return 0
    fi

    local port remark billing_mode quota_enabled quota bandwidth_enabled rate reset_day expiry
    local quota_label quota_display rate_display reset_display status_label
    local traffic_data=() meta=()
    for port in "${active_ports[@]}"; do
        traffic_data=($(get_nftables_counter_data "$port"))
        input_bytes="${traffic_data[0]:-0}"
        output_bytes="${traffic_data[1]:-0}"
        [[ "$input_bytes" =~ ^[0-9]+$ ]] || input_bytes=0
        [[ "$output_bytes" =~ ^[0-9]+$ ]] || output_bytes=0

        # 直接读取原配置字段，空备注与 false 不会被 tab 分隔吞掉
        meta=()
        mapfile -t meta < <(jq -r --arg p "$port" '
            (.ports[$p] // {}) as $c |
            [
                ($c.remark // "" | tostring | gsub("[\r\n\t]"; " ")),
                ($c.billing_mode // "double"),
                (if $c.quota.enabled == false then "false" else "true" end),
                ($c.quota.monthly_limit // "unlimited"),
                ($c.quota.reset_day // ""),
                (if $c.bandwidth_limit.enabled == true then "true" else "false" end),
                ($c.bandwidth_limit.rate // "unlimited"),
                ($c.expiry.expire_date // "")
            ] | .[] | tostring
        ' "$CONFIG_FILE")
        remark="${meta[0]:-无}"
        [ -n "$remark" ] || remark="无"
        billing_mode="${meta[1]:-double}"
        quota_enabled="${meta[2]:-true}"
        quota="${meta[3]:-unlimited}"
        reset_day="${meta[4]:-}"
        bandwidth_enabled="${meta[5]:-false}"
        rate="${meta[6]:-unlimited}"
        expiry="${meta[7]:-}"

        total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")
        if [ "$billing_mode" = "double" ]; then
            quota_label="双向额度"
        else
            quota_label="单向额度"
        fi
        if [ "$quota_enabled" != "true" ]; then
            quota_display="未启用"
        elif [ "$quota" = "unlimited" ]; then
            quota_display="无限制"
        else
            quota_display="$quota"
        fi
        if [ "$bandwidth_enabled" = "true" ] && [ "$rate" != "unlimited" ]; then
            rate_display="$rate"
        else
            rate_display="不限速"
        fi
        reset_display="未设置"
        if [ "$quota_enabled" = "true" ] && [ "$quota" != "unlimited" ] &&
           [[ "$reset_day" =~ ^[0-9]+$ ]] &&
           [ "$reset_day" -ge 1 ] && [ "$reset_day" -le 31 ]; then
            reset_display="每月${reset_day}日"
        fi

        printf '\n🔌 %s\n' "$(get_port_display_name "$port")"
        printf '📊 总流量：%s\n' "$(format_bytes "$total_bytes")"
        printf '⬆️ 入站：%s | ⬇️ 出站：%s\n' \
            "$(format_bytes "$input_bytes")" "$(format_bytes "$output_bytes")"
        printf '📝 备注：%s\n' "$remark"
        printf '📦 %s：%s | ⚡ 限速：%s\n' \
            "$quota_label" "$quota_display" "$rate_display"
        printf '🔄 重置日期：%s\n' "$reset_display"

        # 不移除原来的重要告警（额度耗尽、截止日期）
        status_label=$(get_port_status_label "$port")
        if [[ "$status_label" == *"[已超限]"* ]]; then
            printf '⚠️ 流量已超限\n'
        fi
        if [[ "$status_label" == *"[已截止]"* ]]; then
            printf '⚠️ 已截止：%s\n' "${expiry:-未提供日期}"
        elif [ -n "$expiry" ] && [ "$expiry" != "null" ]; then
            printf '🗓️ 截止日期：%s\n' "$expiry"
        fi
        printf '%s\n' "$line"
    done
}
"""

def locate_script():
    candidates = []
    wrapper = shutil.which("dog")
    if wrapper:
        p = Path(wrapper)
        try:
            data = p.read_text(encoding="utf-8", errors="replace")
            m = re.search(r'(?m)^\s*exec\s+bash\s+"([^"]+)"\s+"\$@"', data)
            if m:
                candidates.append(Path(m.group(1)))
        except OSError:
            pass
        candidates.append(p)
    candidates += [
        Path("/usr/local/bin/port-traffic-dog.sh"),
        Path("/root/port-traffic-dog.sh"),
        Path.cwd() / "port-traffic-dog.sh",
    ]
    for p in candidates:
        try:
            data = p.read_text(encoding="utf-8")
            if "format_text_status_message() {" in data and \
               "format_markdown_status_message() {" in data and \
               "端口流量狗" in data:
                return p.resolve()
        except (OSError, UnicodeError):
            pass
    raise RuntimeError("找不到端口流量狗主脚本。请执行 command -v dog 并查看其中的脚本路径。")

def main():
    if os.geteuid() != 0:
        sys.exit("请使用 root 权限运行：sudo python3 ...")
    script = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else locate_script()
    original = script.read_text(encoding="utf-8")
    pattern = re.compile(r'(?ms)^format_text_status_message\(\) \{\n.*?(?=^format_markdown_status_message\(\) \{)')
    matches = list(pattern.finditer(original))
    if len(matches) != 1:
        sys.exit("找不到唯一的原版文本通知函数，未修改任何文件。")
    if "CUSTOM_DINGTALK_STYLE_2026_V1" in matches[0].group():
        print(f"已应用过此格式，无需重复操作：{script}")
        return

    patched = original[:matches[0].start()] + STYLE + "\n" + original[matches[0].end():]
    backup = Path(str(script) + ".bak-style-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(script, backup)

    fd, tmp_name = tempfile.mkstemp(prefix=".port-dog-style-", dir=str(script.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(patched)
        os.chmod(tmp_name, stat.S_IMODE(script.stat().st_mode))
        completed = subprocess.run(["bash", "-n", tmp_name], capture_output=True, text=True)
        if completed.returncode != 0:
            raise RuntimeError("Bash 语法检查不通过：\n" + completed.stderr)
        os.replace(tmp_name, script)
    except Exception:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)
        raise

    print(f"成功：仅调整 Webhook 状态通知样式")
    print(f"主脚本：{script}")
    print(f"备份文件：{backup}")
    print("Bash 语法检查：通过")
    print("监控数据、nftables、限速、Webhook 密钥、定时任务均未修改。")
    print("可以执行：dog --send-webhook-status 测试钉钉通知。")
    print("注意：原脚本使用安装/更新功能后可能被上游版本覆盖，需要重打补丁。")

if __name__ == "__main__":
    main()

PY_STYLE

# The patch already verifies bash syntax; re-check the final file before installation.
bash -n "$original" || fail 'Bash syntax validation failed.'
grep -q 'CUSTOM_DINGTALK_STYLE_2026_V1' "$original" || \
    fail 'Template verification failed.'

mkdir -p "$(dirname "$INSTALL_PATH")" "$(dirname "$WRAPPER")"
if [ -e "$INSTALL_PATH" ]; then
    grep -q '端口流量狗' "$INSTALL_PATH" || \
        fail "Existing $INSTALL_PATH is not an official Port Traffic Dog script."
    backup="${INSTALL_PATH}.bak-custom-$(date +%Y%m%d-%H%M%S)"
    cp -a "$INSTALL_PATH" "$backup"
    info "Original executable backed up to: $backup"
fi

# Stage in destination directory and rename atomically (cron never sees a half-written script).
staged=$(mktemp "$(dirname "$INSTALL_PATH")/.port-dog-installed-XXXXXX")
trap 'rm -f "$staged"; rm -rf "$workdir"' EXIT
install -m 0755 "$original" "$staged"
mv -f "$staged" "$INSTALL_PATH"

# Preserve existing shortcut; create one only on fresh installations.
if [ ! -e "$WRAPPER" ]; then
    printf '#!/bin/bash\nexec bash "%s" "$@"\n' "$INSTALL_PATH" > "$WRAPPER"
    chmod 0755 "$WRAPPER"
fi

info "Installed customized script: $INSTALL_PATH"
info 'All future Webhook status reports use the compact template.'
info 'You still need to configure monitored ports and DingTalk Webhook in the dog menu.'
info 'Running upstream update from within the menu may overwrite this customization.'

if [ "${PTDOG_NO_START:-0}" = 1 ]; then
    info 'Validation mode: did not launch interactive menu.'
else
    exec bash "$INSTALL_PATH"
fi "$original" ||
    fail 'Pinned upstream is not expected v1.4.4; no installation performed.'
grep -q '^format_text_status_message() {' "$original" || \
    fail 'Missing text status formatter in upstream.'
grep -q '^format_markdown_status_message() {' "$original" || \
    fail 'Missing markdown status formatter in upstream.'

info 'Applying integrated compact status notification template ...'
python3 - "$original" <<'PY_STYLE'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Only replace port-traffic-dog.sh's Webhook text-status formatter."""
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

STYLE = r"""format_text_status_message() {
    # CUSTOM_DINGTALK_STYLE_2026_V1: 只调整 Webhook 文本内容，不改变计数/发送/定时逻辑
    local server_name="${1:-$(hostname)}"
    local timestamp
    timestamp=$(get_beijing_time '+%Y-%m-%d %H:%M:%S')
    local line="──────────────────────────────"

    local active_ports=()
    mapfile -t active_ports < <(get_monitored_ports)
    local port_count=${#active_ports[@]}
    local daily_total
    daily_total=$(get_daily_total_traffic)

    printf '🖥️ 服务器：%s\n🕒 汇报时间：%s\n\n' "$server_name" "$timestamp"
    printf '🌐 整机总流量\n'

    # 沿用原脚本的整机统计口径：双向模式 m_rx/m_tx 均乘 2
    local ifaces=()
    mapfile -t ifaces < <(get_vps_interface_names)
    local vps_billing_mode vps_data
    vps_billing_mode=$(jq -r --arg v "$VPS_PORT_ID" \
        '.ports[$v].billing_mode // "double"' "$CONFIG_FILE")
    vps_data=$(vps_read_data)

    if [ ${#ifaces[@]} -eq 0 ]; then
        printf '暂无可统计网卡\n'
    fi

    local iface rx tx input_bytes output_bytes total_bytes
    for iface in "${ifaces[@]}"; do
        rx=$(printf '%s' "$vps_data" | jq -r --arg i "$iface" \
            '.monthly.ifaces[$i].rx_bytes // 0' 2>/dev/null || echo 0)
        tx=$(printf '%s' "$vps_data" | jq -r --arg i "$iface" \
            '.monthly.ifaces[$i].tx_bytes // 0' 2>/dev/null || echo 0)
        [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
        [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
        input_bytes=0
        output_bytes=0
        if [ "$vps_billing_mode" = "double" ]; then
            input_bytes=$((rx * 2))
            output_bytes=$((tx * 2))
        else
            output_bytes=$tx
        fi
        total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$vps_billing_mode")
        printf '🔹 %s | 总流量：%s\n' "$iface" "$(format_bytes "$total_bytes")"
        printf '⬆️ 入站：%s | ⬇️ 出站：%s\n' \
            "$(format_bytes "$input_bytes")" "$(format_bytes "$output_bytes")"
    done

    printf '%s\n' "$line"
    printf '🟢 状态：监控中 | 监控项：%s个\n' "$port_count"
    printf '📊 端口总流量：%s\n' "$daily_total"
    printf '%s\n' "$line"

    if [ "$port_count" -eq 0 ]; then
        printf '暂无监控端口\n%s\n' "$line"
        return 0
    fi

    local port remark billing_mode quota_enabled quota bandwidth_enabled rate reset_day expiry
    local quota_label quota_display rate_display reset_display status_label
    local traffic_data=() meta=()
    for port in "${active_ports[@]}"; do
        traffic_data=($(get_nftables_counter_data "$port"))
        input_bytes="${traffic_data[0]:-0}"
        output_bytes="${traffic_data[1]:-0}"
        [[ "$input_bytes" =~ ^[0-9]+$ ]] || input_bytes=0
        [[ "$output_bytes" =~ ^[0-9]+$ ]] || output_bytes=0

        # 直接读取原配置字段，空备注与 false 不会被 tab 分隔吞掉
        meta=()
        mapfile -t meta < <(jq -r --arg p "$port" '
            (.ports[$p] // {}) as $c |
            [
                ($c.remark // "" | tostring | gsub("[\r\n\t]"; " ")),
                ($c.billing_mode // "double"),
                (if $c.quota.enabled == false then "false" else "true" end),
                ($c.quota.monthly_limit // "unlimited"),
                ($c.quota.reset_day // ""),
                (if $c.bandwidth_limit.enabled == true then "true" else "false" end),
                ($c.bandwidth_limit.rate // "unlimited"),
                ($c.expiry.expire_date // "")
            ] | .[] | tostring
        ' "$CONFIG_FILE")
        remark="${meta[0]:-无}"
        [ -n "$remark" ] || remark="无"
        billing_mode="${meta[1]:-double}"
        quota_enabled="${meta[2]:-true}"
        quota="${meta[3]:-unlimited}"
        reset_day="${meta[4]:-}"
        bandwidth_enabled="${meta[5]:-false}"
        rate="${meta[6]:-unlimited}"
        expiry="${meta[7]:-}"

        total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")
        if [ "$billing_mode" = "double" ]; then
            quota_label="双向额度"
        else
            quota_label="单向额度"
        fi
        if [ "$quota_enabled" != "true" ]; then
            quota_display="未启用"
        elif [ "$quota" = "unlimited" ]; then
            quota_display="无限制"
        else
            quota_display="$quota"
        fi
        if [ "$bandwidth_enabled" = "true" ] && [ "$rate" != "unlimited" ]; then
            rate_display="$rate"
        else
            rate_display="不限速"
        fi
        reset_display="未设置"
        if [ "$quota_enabled" = "true" ] && [ "$quota" != "unlimited" ] &&
           [[ "$reset_day" =~ ^[0-9]+$ ]] &&
           [ "$reset_day" -ge 1 ] && [ "$reset_day" -le 31 ]; then
            reset_display="每月${reset_day}日"
        fi

        printf '\n🔌 %s\n' "$(get_port_display_name "$port")"
        printf '📊 总流量：%s\n' "$(format_bytes "$total_bytes")"
        printf '⬆️ 入站：%s | ⬇️ 出站：%s\n' \
            "$(format_bytes "$input_bytes")" "$(format_bytes "$output_bytes")"
        printf '📝 备注：%s\n' "$remark"
        printf '📦 %s：%s | ⚡ 限速：%s\n' \
            "$quota_label" "$quota_display" "$rate_display"
        printf '🔄 重置日期：%s\n' "$reset_display"

        # 不移除原来的重要告警（额度耗尽、截止日期）
        status_label=$(get_port_status_label "$port")
        if [[ "$status_label" == *"[已超限]"* ]]; then
            printf '⚠️ 流量已超限\n'
        fi
        if [[ "$status_label" == *"[已截止]"* ]]; then
            printf '⚠️ 已截止：%s\n' "${expiry:-未提供日期}"
        elif [ -n "$expiry" ] && [ "$expiry" != "null" ]; then
            printf '🗓️ 截止日期：%s\n' "$expiry"
        fi
        printf '%s\n' "$line"
    done
}
"""

def locate_script():
    candidates = []
    wrapper = shutil.which("dog")
    if wrapper:
        p = Path(wrapper)
        try:
            data = p.read_text(encoding="utf-8", errors="replace")
            m = re.search(r'(?m)^\s*exec\s+bash\s+"([^"]+)"\s+"\$@"', data)
            if m:
                candidates.append(Path(m.group(1)))
        except OSError:
            pass
        candidates.append(p)
    candidates += [
        Path("/usr/local/bin/port-traffic-dog.sh"),
        Path("/root/port-traffic-dog.sh"),
        Path.cwd() / "port-traffic-dog.sh",
    ]
    for p in candidates:
        try:
            data = p.read_text(encoding="utf-8")
            if "format_text_status_message() {" in data and \
               "format_markdown_status_message() {" in data and \
               "端口流量狗" in data:
                return p.resolve()
        except (OSError, UnicodeError):
            pass
    raise RuntimeError("找不到端口流量狗主脚本。请执行 command -v dog 并查看其中的脚本路径。")

def main():
    if os.geteuid() != 0:
        sys.exit("请使用 root 权限运行：sudo python3 ...")
    script = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else locate_script()
    original = script.read_text(encoding="utf-8")
    pattern = re.compile(r'(?ms)^format_text_status_message\(\) \{\n.*?(?=^format_markdown_status_message\(\) \{)')
    matches = list(pattern.finditer(original))
    if len(matches) != 1:
        sys.exit("找不到唯一的原版文本通知函数，未修改任何文件。")
    if "CUSTOM_DINGTALK_STYLE_2026_V1" in matches[0].group():
        print(f"已应用过此格式，无需重复操作：{script}")
        return

    patched = original[:matches[0].start()] + STYLE + "\n" + original[matches[0].end():]
    backup = Path(str(script) + ".bak-style-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(script, backup)

    fd, tmp_name = tempfile.mkstemp(prefix=".port-dog-style-", dir=str(script.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(patched)
        os.chmod(tmp_name, stat.S_IMODE(script.stat().st_mode))
        completed = subprocess.run(["bash", "-n", tmp_name], capture_output=True, text=True)
        if completed.returncode != 0:
            raise RuntimeError("Bash 语法检查不通过：\n" + completed.stderr)
        os.replace(tmp_name, script)
    except Exception:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)
        raise

    print(f"成功：仅调整 Webhook 状态通知样式")
    print(f"主脚本：{script}")
    print(f"备份文件：{backup}")
    print("Bash 语法检查：通过")
    print("监控数据、nftables、限速、Webhook 密钥、定时任务均未修改。")
    print("可以执行：dog --send-webhook-status 测试钉钉通知。")
    print("注意：原脚本使用安装/更新功能后可能被上游版本覆盖，需要重打补丁。")

if __name__ == "__main__":
    main()

PY_STYLE

# The patch already verifies bash syntax; re-check the final file before installation.
bash -n "$original" || fail 'Bash syntax validation failed.'
grep -q 'CUSTOM_DINGTALK_STYLE_2026_V1' "$original" || \
    fail 'Template verification failed.'

mkdir -p "$(dirname "$INSTALL_PATH")" "$(dirname "$WRAPPER")"
if [ -e "$INSTALL_PATH" ]; then
    grep -q '端口流量狗' "$INSTALL_PATH" || \
        fail "Existing $INSTALL_PATH is not an official Port Traffic Dog script."
    backup="${INSTALL_PATH}.bak-custom-$(date +%Y%m%d-%H%M%S)"
    cp -a "$INSTALL_PATH" "$backup"
    info "Original executable backed up to: $backup"
fi

# Stage in destination directory and rename atomically (cron never sees a half-written script).
staged=$(mktemp "$(dirname "$INSTALL_PATH")/.port-dog-installed-XXXXXX")
trap 'rm -f "$staged"; rm -rf "$workdir"' EXIT
install -m 0755 "$original" "$staged"
mv -f "$staged" "$INSTALL_PATH"

# Preserve existing shortcut; create one only on fresh installations.
if [ ! -e "$WRAPPER" ]; then
    printf '#!/bin/bash\nexec bash "%s" "$@"\n' "$INSTALL_PATH" > "$WRAPPER"
    chmod 0755 "$WRAPPER"
fi

info "Installed customized script: $INSTALL_PATH"
info 'All future Webhook status reports use the compact template.'
info 'You still need to configure monitored ports and DingTalk Webhook in the dog menu.'
info 'Running upstream update from within the menu may overwrite this customization.'

if [ "${PTDOG_NO_START:-0}" = 1 ]; then
    info 'Validation mode: did not launch interactive menu.'
else
    exec bash "$INSTALL_PATH"
fi "$original" || \
    fail 'Pinned upstream is not expected v1.4.4; no installation performed.'

grep -q '^format_text_status_message() {' "$original" || \
    fail 'Missing text status formatter in upstream.'
grep -q '^format_markdown_status_message() {' "$original" || \
    fail 'Missing markdown status formatter in upstream.'

info 'Applying integrated compact status notification template ...'
python3 - "$original" <<'PY_STYLE'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Only replace port-traffic-dog.sh's Webhook text-status formatter."""
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

STYLE = r"""format_text_status_message() {
    # CUSTOM_DINGTALK_STYLE_2026_V1: 只调整 Webhook 文本内容，不改变计数/发送/定时逻辑
    local server_name="${1:-$(hostname)}"
    local timestamp
    timestamp=$(get_beijing_time '+%Y-%m-%d %H:%M:%S')
    local line="──────────────────────────────"

    local active_ports=()
    mapfile -t active_ports < <(get_monitored_ports)
    local port_count=${#active_ports[@]}
    local daily_total
    daily_total=$(get_daily_total_traffic)

    printf '🖥️ 服务器：%s\n🕒 汇报时间：%s\n\n' "$server_name" "$timestamp"
    printf '🌐 整机总流量\n'

    # 沿用原脚本的整机统计口径：双向模式 m_rx/m_tx 均乘 2
    local ifaces=()
    mapfile -t ifaces < <(get_vps_interface_names)
    local vps_billing_mode vps_data
    vps_billing_mode=$(jq -r --arg v "$VPS_PORT_ID" \
        '.ports[$v].billing_mode // "double"' "$CONFIG_FILE")
    vps_data=$(vps_read_data)

    if [ ${#ifaces[@]} -eq 0 ]; then
        printf '暂无可统计网卡\n'
    fi

    local iface rx tx input_bytes output_bytes total_bytes
    for iface in "${ifaces[@]}"; do
        rx=$(printf '%s' "$vps_data" | jq -r --arg i "$iface" \
            '.monthly.ifaces[$i].rx_bytes // 0' 2>/dev/null || echo 0)
        tx=$(printf '%s' "$vps_data" | jq -r --arg i "$iface" \
            '.monthly.ifaces[$i].tx_bytes // 0' 2>/dev/null || echo 0)
        [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
        [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
        input_bytes=0
        output_bytes=0
        if [ "$vps_billing_mode" = "double" ]; then
            input_bytes=$((rx * 2))
            output_bytes=$((tx * 2))
        else
            output_bytes=$tx
        fi
        total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$vps_billing_mode")
        printf '🔹 %s | 总流量：%s\n' "$iface" "$(format_bytes "$total_bytes")"
        printf '⬆️ 入站：%s | ⬇️ 出站：%s\n' \
            "$(format_bytes "$input_bytes")" "$(format_bytes "$output_bytes")"
    done

    printf '%s\n' "$line"
    printf '🟢 状态：监控中 | 监控项：%s个\n' "$port_count"
    printf '📊 端口总流量：%s\n' "$daily_total"
    printf '%s\n' "$line"

    if [ "$port_count" -eq 0 ]; then
        printf '暂无监控端口\n%s\n' "$line"
        return 0
    fi

    local port remark billing_mode quota_enabled quota bandwidth_enabled rate reset_day expiry
    local quota_label quota_display rate_display reset_display status_label
    local traffic_data=() meta=()
    for port in "${active_ports[@]}"; do
        traffic_data=($(get_nftables_counter_data "$port"))
        input_bytes="${traffic_data[0]:-0}"
        output_bytes="${traffic_data[1]:-0}"
        [[ "$input_bytes" =~ ^[0-9]+$ ]] || input_bytes=0
        [[ "$output_bytes" =~ ^[0-9]+$ ]] || output_bytes=0

        # 直接读取原配置字段，空备注与 false 不会被 tab 分隔吞掉
        meta=()
        mapfile -t meta < <(jq -r --arg p "$port" '
            (.ports[$p] // {}) as $c |
            [
                ($c.remark // "" | tostring | gsub("[\r\n\t]"; " ")),
                ($c.billing_mode // "double"),
                (if $c.quota.enabled == false then "false" else "true" end),
                ($c.quota.monthly_limit // "unlimited"),
                ($c.quota.reset_day // ""),
                (if $c.bandwidth_limit.enabled == true then "true" else "false" end),
                ($c.bandwidth_limit.rate // "unlimited"),
                ($c.expiry.expire_date // "")
            ] | .[] | tostring
        ' "$CONFIG_FILE")
        remark="${meta[0]:-无}"
        [ -n "$remark" ] || remark="无"
        billing_mode="${meta[1]:-double}"
        quota_enabled="${meta[2]:-true}"
        quota="${meta[3]:-unlimited}"
        reset_day="${meta[4]:-}"
        bandwidth_enabled="${meta[5]:-false}"
        rate="${meta[6]:-unlimited}"
        expiry="${meta[7]:-}"

        total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")
        if [ "$billing_mode" = "double" ]; then
            quota_label="双向额度"
        else
            quota_label="单向额度"
        fi
        if [ "$quota_enabled" != "true" ]; then
            quota_display="未启用"
        elif [ "$quota" = "unlimited" ]; then
            quota_display="无限制"
        else
            quota_display="$quota"
        fi
        if [ "$bandwidth_enabled" = "true" ] && [ "$rate" != "unlimited" ]; then
            rate_display="$rate"
        else
            rate_display="不限速"
        fi
        reset_display="未设置"
        if [ "$quota_enabled" = "true" ] && [ "$quota" != "unlimited" ] &&
           [[ "$reset_day" =~ ^[0-9]+$ ]] &&
           [ "$reset_day" -ge 1 ] && [ "$reset_day" -le 31 ]; then
            reset_display="每月${reset_day}日"
        fi

        printf '\n🔌 %s\n' "$(get_port_display_name "$port")"
        printf '📊 总流量：%s\n' "$(format_bytes "$total_bytes")"
        printf '⬆️ 入站：%s | ⬇️ 出站：%s\n' \
            "$(format_bytes "$input_bytes")" "$(format_bytes "$output_bytes")"
        printf '📝 备注：%s\n' "$remark"
        printf '📦 %s：%s | ⚡ 限速：%s\n' \
            "$quota_label" "$quota_display" "$rate_display"
        printf '🔄 重置日期：%s\n' "$reset_display"

        # 不移除原来的重要告警（额度耗尽、截止日期）
        status_label=$(get_port_status_label "$port")
        if [[ "$status_label" == *"[已超限]"* ]]; then
            printf '⚠️ 流量已超限\n'
        fi
        if [[ "$status_label" == *"[已截止]"* ]]; then
            printf '⚠️ 已截止：%s\n' "${expiry:-未提供日期}"
        elif [ -n "$expiry" ] && [ "$expiry" != "null" ]; then
            printf '🗓️ 截止日期：%s\n' "$expiry"
        fi
        printf '%s\n' "$line"
    done
}
"""

def locate_script():
    candidates = []
    wrapper = shutil.which("dog")
    if wrapper:
        p = Path(wrapper)
        try:
            data = p.read_text(encoding="utf-8", errors="replace")
            m = re.search(r'(?m)^\s*exec\s+bash\s+"([^"]+)"\s+"\$@"', data)
            if m:
                candidates.append(Path(m.group(1)))
        except OSError:
            pass
        candidates.append(p)
    candidates += [
        Path("/usr/local/bin/port-traffic-dog.sh"),
        Path("/root/port-traffic-dog.sh"),
        Path.cwd() / "port-traffic-dog.sh",
    ]
    for p in candidates:
        try:
            data = p.read_text(encoding="utf-8")
            if "format_text_status_message() {" in data and \
               "format_markdown_status_message() {" in data and \
               "端口流量狗" in data:
                return p.resolve()
        except (OSError, UnicodeError):
            pass
    raise RuntimeError("找不到端口流量狗主脚本。请执行 command -v dog 并查看其中的脚本路径。")

def main():
    if os.geteuid() != 0:
        sys.exit("请使用 root 权限运行：sudo python3 ...")
    script = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else locate_script()
    original = script.read_text(encoding="utf-8")
    pattern = re.compile(r'(?ms)^format_text_status_message\(\) \{\n.*?(?=^format_markdown_status_message\(\) \{)')
    matches = list(pattern.finditer(original))
    if len(matches) != 1:
        sys.exit("找不到唯一的原版文本通知函数，未修改任何文件。")
    if "CUSTOM_DINGTALK_STYLE_2026_V1" in matches[0].group():
        print(f"已应用过此格式，无需重复操作：{script}")
        return

    patched = original[:matches[0].start()] + STYLE + "\n" + original[matches[0].end():]
    backup = Path(str(script) + ".bak-style-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(script, backup)

    fd, tmp_name = tempfile.mkstemp(prefix=".port-dog-style-", dir=str(script.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(patched)
        os.chmod(tmp_name, stat.S_IMODE(script.stat().st_mode))
        completed = subprocess.run(["bash", "-n", tmp_name], capture_output=True, text=True)
        if completed.returncode != 0:
            raise RuntimeError("Bash 语法检查不通过：\n" + completed.stderr)
        os.replace(tmp_name, script)
    except Exception:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)
        raise

    print(f"成功：仅调整 Webhook 状态通知样式")
    print(f"主脚本：{script}")
    print(f"备份文件：{backup}")
    print("Bash 语法检查：通过")
    print("监控数据、nftables、限速、Webhook 密钥、定时任务均未修改。")
    print("可以执行：dog --send-webhook-status 测试钉钉通知。")
    print("注意：原脚本使用安装/更新功能后可能被上游版本覆盖，需要重打补丁。")

if __name__ == "__main__":
    main()

PY_STYLE

# The patch already verifies bash syntax; re-check the final file before installation.
bash -n "$original" || fail 'Bash syntax validation failed.'
grep -q 'CUSTOM_DINGTALK_STYLE_2026_V1' "$original" || \
    fail 'Template verification failed.'

mkdir -p "$(dirname "$INSTALL_PATH")" "$(dirname "$WRAPPER")"
if [ -e "$INSTALL_PATH" ]; then
    grep -q '端口流量狗' "$INSTALL_PATH" || \
        fail "Existing $INSTALL_PATH is not an official Port Traffic Dog script."
    backup="${INSTALL_PATH}.bak-custom-$(date +%Y%m%d-%H%M%S)"
    cp -a "$INSTALL_PATH" "$backup"
    info "Original executable backed up to: $backup"
fi

# Stage in destination directory and rename atomically (cron never sees a half-written script).
staged=$(mktemp "$(dirname "$INSTALL_PATH")/.port-dog-installed-XXXXXX")
trap 'rm -f "$staged"; rm -rf "$workdir"' EXIT
install -m 0755 "$original" "$staged"
mv -f "$staged" "$INSTALL_PATH"

# Preserve existing shortcut; create one only on fresh installations.
if [ ! -e "$WRAPPER" ]; then
    printf '#!/bin/bash\nexec bash "%s" "$@"\n' "$INSTALL_PATH" > "$WRAPPER"
    chmod 0755 "$WRAPPER"
fi

info "Installed customized script: $INSTALL_PATH"
info 'All future Webhook status reports use the compact template.'
info 'You still need to configure monitored ports and DingTalk Webhook in the dog menu.'
info 'Running upstream update from within the menu may overwrite this customization.'

if [ "${PTDOG_NO_START:-0}" = 1 ]; then
    info 'Validation mode: did not launch interactive menu.'
else
    exec bash "$INSTALL_PATH"
fi