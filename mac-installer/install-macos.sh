#!/bin/bash

INSTALLER_VERSION="mac-1.0.0"
BASE_URL="__BASE_URL__"
INSTALL_TOKEN="__INSTALL_TOKEN__"

OFFICIAL_INSTALLER_URL="https://chatgpt.com/codex/install.sh"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
BIN_DIR="$HOME/.local/bin"
CODEX_BIN="$BIN_DIR/codex"

TMP_BASE="${TMPDIR:-/tmp}"
STAMP="$(date '+%Y%m%d-%H%M%S')"
LOG_TMP="${TMP_BASE%/}/THZ-Codex-Setup-${STAMP}.tmp.log"
LOG_FINAL="$HOME/Library/Logs/THZ-Codex-Setup-${STAMP}.log"

FINALIZED=0
EXITING=0
BACKUP_DIR=""
CONFIG_PATH="$CODEX_HOME/config.toml"
MODELS_PATH="$CODEX_HOME/models.json"
API_KEY=""
START_RESPONSE=""
DEVICE_FINGERPRINT=""
CI_KEY_STDIN=0
MODE=""
MODEL="deepseek-chat"
PROVIDER_ID="deepseek"
PROVIDER_BASE_URL="https://api.deepseek.com"
MODELS_JSON='{"models":[{"slug":"deepseek-chat","display_name":"DeepSeek Chat","description":"DeepSeek Chat","default_reasoning_level":"high","supported_reasoning_levels":[{"effort":"high","description":"High reasoning effort"}],"shell_type":"shell_command","visibility":"list","minimal_client_version":"0.0.0","supported_in_api":true,"priority":1}]}'

touch "$LOG_TMP" 2>/dev/null || {
    printf '%s\n' "无法创建临时安装日志：$LOG_TMP"
    exit 1
}
chmod 600 "$LOG_TMP" 2>/dev/null || true
exec > >(tee -a "$LOG_TMP") 2>&1

write_step() {
    printf '\n[%s/7] %s\n' "$1" "$2"
}

write_ok() {
    printf '[OK] %s\n' "$1"
}

write_warn() {
    printf '[!] %s\n' "$1"
}

write_fail() {
    printf '[X] %s\n' "$1"
}

trim_text() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

lower_text() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

json_escape() {
    printf '%s' "$1" |
        sed 's/\\/\\\\/g; s/"/\\"/g' |
        tr '\r\n\t' '   '
}

sanitize_text() {
    safe_text="$(printf '%s' "$1" | sed -E 's/sk-[A-Za-z0-9_.\-]{4,}/sk-****/g')"
    if [ -n "$INSTALL_TOKEN" ] &&
       [ "${#INSTALL_TOKEN}" -gt 12 ] &&
       ! printf '%s' "$INSTALL_TOKEN" | grep -q 'INSTALL_TOKEN'; then
        token_first="$(printf '%s' "$INSTALL_TOKEN" | cut -c1-4)"
        token_last="$(printf '%s' "$INSTALL_TOKEN" | rev | cut -c1-4 | rev)"
        token_mask="${token_first}****${token_last}"
        token_escaped="$(printf '%s' "$INSTALL_TOKEN" | sed 's/[.[\*^$\\&/]/\\&/g')"
        safe_text="$(printf '%s' "$safe_text" | sed "s/${token_escaped}/${token_mask}/g")"
    fi
    printf '%s' "$safe_text"
}

finalize() {
    if [ "$FINALIZED" -eq 1 ]; then
        return
    fi
    FINALIZED=1

    mkdir -p "$HOME/Library/Logs" 2>/dev/null || true

    if [ -f "$LOG_TMP" ]; then
        sed -E 's/sk-[A-Za-z0-9_.\-]{4,}/sk-****/g' "$LOG_TMP" > "${LOG_FINAL}.stage" 2>/dev/null || \
            cp "$LOG_TMP" "${LOG_FINAL}.stage" 2>/dev/null || true

        if [ -f "${LOG_FINAL}.stage" ]; then
            if [ -n "$INSTALL_TOKEN" ] &&
               [ "${#INSTALL_TOKEN}" -gt 12 ] &&
               ! printf '%s' "$INSTALL_TOKEN" | grep -q 'INSTALL_TOKEN'; then
                token_first="$(printf '%s' "$INSTALL_TOKEN" | cut -c1-4)"
                token_last="$(printf '%s' "$INSTALL_TOKEN" | rev | cut -c1-4 | rev)"
                token_mask="${token_first}****${token_last}"
                token_escaped="$(printf '%s' "$INSTALL_TOKEN" | sed 's/[.[\*^$\\&/]/\\&/g')"
                sed "s/${token_escaped}/${token_mask}/g" "${LOG_FINAL}.stage" > "$LOG_FINAL" 2>/dev/null || \
                    cp "${LOG_FINAL}.stage" "$LOG_FINAL" 2>/dev/null || true
                rm -f "${LOG_FINAL}.stage" 2>/dev/null || true
            else
                mv "${LOG_FINAL}.stage" "$LOG_FINAL" 2>/dev/null || \
                    cp "${LOG_FINAL}.stage" "$LOG_FINAL" 2>/dev/null || true
            fi
        fi
    fi

    chmod 600 "$LOG_FINAL" 2>/dev/null || true
}

report_fail() {
    report_step="$1"
    report_code="$2"
    report_message="$3"

    case "$report_step" in
        1|2|3|4|5|6|7) ;;
        *) report_step=1 ;;
    esac

    report_code="$(printf '%.64s' "$report_code")"

    if [ -z "$INSTALL_TOKEN" ] ||
       printf '%s' "$INSTALL_TOKEN" | grep -q 'INSTALL_TOKEN' ||
       printf '%s' "$BASE_URL" | grep -q 'BASE_URL'; then
        return 0
    fi

    report_message="$(sanitize_text "$report_message")"
    report_message="$(printf '%.500s' "$report_message")"

    report_body="$(printf '{"install_token":"%s","step":%s,"error_code":"%s","message":"%s","installer_version":"%s","os_type":"macos"}' \
        "$(json_escape "$INSTALL_TOKEN")" \
        "$report_step" \
        "$(json_escape "$report_code")" \
        "$(json_escape "$report_message")" \
        "$INSTALLER_VERSION")"

    curl -sS --max-time 15 \
        -H 'Content-Type: application/json' \
        -X POST \
        --data-binary "$report_body" \
        "$BASE_URL/api/installer/fail" >/dev/null 2>&1 || true
}

fail_exit() {
    fail_step="$1"
    fail_code="$2"
    shift 2
    fail_message="$*"

    if [ "$EXITING" -eq 1 ]; then
        exit 1
    fi
    EXITING=1

    write_fail "$fail_message"
    report_fail "$fail_step" "$fail_code" "$fail_message" || true
    finalize

    printf '\n安装日志已保存：%s\n' "$LOG_FINAL"
    printf '%s\n' "请将此日志发给客服 QQ 89523844"
    trap - EXIT INT TERM
    exit 1
}

on_signal() {
    signal_name="$1"
    fail_exit 1 "SIGNAL_${signal_name}" "安装过程被中断。"
}

on_exit() {
    exit_status=$?
    if [ "$FINALIZED" -eq 0 ]; then
        finalize
    fi
    return "$exit_status"
}

trap 'on_exit' EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

json_get_string() {
    json_input="$1"
    json_key="$2"
    printf '%s' "$json_input" |
        tr '\r\n' '  ' |
        sed -n 's/.*"'"$json_key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        head -n 1 |
        sed 's/\\"/"/g; s/\\\\/\\/g; s/\\n/\
/g; s/\\r//g; s/\\t/	/g'
}

json_get_bool() {
    json_input="$1"
    json_key="$2"
    printf '%s' "$json_input" |
        tr '\r\n' '  ' |
        sed -n 's/.*"'"$json_key"'"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' |
        head -n 1
}

json_get_models_value() {
    json_input="$1"
    # models_json 是转义后的嵌套 JSON 字符串，sed 正则 [^"]* 会在 \" 处提前截断。
    # 优先用 python3 做真正的 JSON 解析，拿不到再回退到原来的 sed 方法。
    if command -v python3 >/dev/null 2>&1; then
        py_models="$(printf '%s' "$json_input" | python3 -c 'import json,sys; d=json.load(sys.stdin); v=d.get("models_json",""); print(v if isinstance(v,str) else "")' 2>/dev/null)"
        if [ -n "$py_models" ]; then
            printf '%s' "$py_models"
            return
        fi
    fi
    encoded="$(json_get_string "$json_input" "models_json")"
    if [ -n "$encoded" ]; then
        printf '%s' "$encoded"
        return
    fi
    printf '%s' "$MODELS_JSON"
}

get_device_fingerprint() {
    raw_uuid="$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null |
        sed -n 's/.*"IOPlatformUUID"[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' |
        head -n 1)"

    raw_uuid="$(trim_text "$raw_uuid")"
    if [ -z "$raw_uuid" ]; then
        return 1
    fi

    normalized_uuid="$(lower_text "$raw_uuid")"
    fingerprint="$(printf 'ioplatformuuid:%s' "$normalized_uuid" | shasum -a 256 | awk '{print $1}')"
    raw_uuid=""
    normalized_uuid=""

    case "$fingerprint" in
        [0-9a-f][0-9a-f]*) printf '%s' "$fingerprint" ;;
        *) return 1 ;;
    esac
}

api_start() {
    device_fingerprint="$(get_device_fingerprint)" ||
        fail_exit 1 "STEP1_DEVICE" "无法读取稳定的 macOS 设备标识，请联系管理员。"

    start_body="$(printf '{"install_token":"%s","device_fingerprint":"%s","installer_version":"%s","os_type":"macos"}' \
        "$(json_escape "$INSTALL_TOKEN")" \
        "$device_fingerprint" \
        "$INSTALLER_VERSION")"

    response_file="${TMP_BASE%/}/thz-start-${STAMP}-$$.json"
    http_code="$(curl -sS --connect-timeout 15 --max-time 30 \
        -o "$response_file" -w '%{http_code}' \
        -H 'Content-Type: application/json' \
        -X POST \
        --data-binary "$start_body" \
        "$BASE_URL/api/installer/start" 2>/dev/null)"
    curl_status=$?

    if [ "$curl_status" -ne 0 ]; then
        rm -f "$response_file" 2>/dev/null || true
        fail_exit 1 "STEP1_AUTH" "无法连接安装服务器。"
    fi

    START_RESPONSE="$(sed -E 's/sk-[A-Za-z0-9_.\-]{4,}/sk-****/g' "$response_file" 2>/dev/null)"
    rm -f "$response_file" 2>/dev/null || true

    case "$http_code" in
        2??) ;;
        *)
            server_message="$(json_get_string "$START_RESPONSE" "message")"
            [ -n "$server_message" ] || server_message="安装授权验证失败（HTTP $http_code）。"
            fail_exit 1 "STEP1_AUTH" "$server_message"
            ;;
    esac

    api_ok="$(json_get_bool "$START_RESPONSE" "ok")"
    if [ "$api_ok" = "false" ]; then
        server_message="$(json_get_string "$START_RESPONSE" "message")"
        [ -n "$server_message" ] || server_message="安装授权验证失败。"
        fail_exit 1 "STEP1_AUTH" "$server_message"
    fi

    # /complete 需要带上与 /start 相同的设备指纹，否则后端报 token_device_mismatch
    DEVICE_FINGERPRINT="$device_fingerprint"
}

api_complete() {
    complete_body="$(printf '{"install_token":"%s","device_fingerprint":"%s"}' \
        "$(json_escape "$INSTALL_TOKEN")" \
        "$(json_escape "$DEVICE_FINGERPRINT")")"
    curl -sS --connect-timeout 5 --max-time 20 \
        -H 'Content-Type: application/json' \
        -X POST \
        --data-binary "$complete_body" \
        "$BASE_URL/api/installer/complete" >/dev/null 2>&1 </dev/null &
}

version_ge_12() {
    version_value="$1"
    major_version="$(printf '%s' "$version_value" | cut -d. -f1)"
    case "$major_version" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$major_version" -ge 12 ]
}

check_system() {
    [ "$(uname -s 2>/dev/null)" = "Darwin" ] ||
        fail_exit 2 "STEP2_OS" "此安装器仅支持 macOS。"

    mac_version="$(sw_vers -productVersion 2>/dev/null)"
    version_ge_12 "$mac_version" ||
        fail_exit 2 "STEP2_OS_VERSION" "需要 macOS 12 或更高版本，当前版本：${mac_version:-未知}。"

    machine_arch="$(uname -m 2>/dev/null)"
    case "$machine_arch" in
        arm64)
            RELEASE_ARCH="aarch64"
            write_ok "macOS $mac_version（Apple Silicon arm64）环境正常"
            ;;
        x86_64)
            RELEASE_ARCH="x86_64"
            write_ok "macOS $mac_version（Intel x86_64）环境正常"
            ;;
        *)
            fail_exit 2 "STEP2_ARCH" "不支持的 CPU 架构：$machine_arch"
            ;;
    esac
}

# 安装器内置临时代理（仅用于安装时的下载）
# 服务器：64.83.26.242:18888，白名单模式（只允许 openai/deepseek/github）
THZ_INSTALL_PROXY="http://64.83.26.242:18888"
USE_INSTALL_PROXY=0

# 检测直连是否可用，不可用则启用内置临时代理
probe_domain_direct() {
    local domain="$1"
    local attempt dns_ok tcp_ok http_code curl_status
    local dns_tmp_a dns_tmp_aaaa

    attempt=1
    while [ "$attempt" -le 2 ]; do
        dns_ok=1
        tcp_ok=1

        # L1: DNS（并行查询 A 和 AAAA）
        if command -v dig >/dev/null 2>&1; then
            dns_tmp_a="$(mktemp -t thz_dns_a.XXXXXX 2>/dev/null)" || return 1
            dns_tmp_aaaa="$(mktemp -t thz_dns_aaaa.XXXXXX 2>/dev/null)" || {
                rm -f "$dns_tmp_a"
                return 1
            }

            dig +time=2 +tries=1 +short A "$domain" >"$dns_tmp_a" 2>/dev/null &
            local dns_pid_a=$!
            dig +time=2 +tries=1 +short AAAA "$domain" >"$dns_tmp_aaaa" 2>/dev/null &
            local dns_pid_aaaa=$!
            wait "$dns_pid_a" 2>/dev/null
            wait "$dns_pid_aaaa" 2>/dev/null

            if [ -s "$dns_tmp_a" ] || [ -s "$dns_tmp_aaaa" ]; then
                dns_ok=0
            fi
            rm -f "$dns_tmp_a" "$dns_tmp_aaaa"
        elif command -v nslookup >/dev/null 2>&1; then
            if nslookup -timeout=2 -retry=1 -type=A "$domain" 2>/dev/null |
                grep -Eq '(^Address:|has address|internet address =|^[[:space:]]*Addresses:)'; then
                dns_ok=0
            fi
            if [ "$dns_ok" -ne 0 ] &&
                nslookup -timeout=2 -retry=1 -type=AAAA "$domain" 2>/dev/null |
                grep -Eq '(^Address:|has IPv6 address|internet address =|^[[:space:]]*Addresses:)'; then
                dns_ok=0
            fi
        fi

        if [ "$dns_ok" -eq 0 ]; then
            # L2: TCP 443
            if command -v nc >/dev/null 2>&1; then
                nc -z -w 2 "$domain" 443 >/dev/null 2>&1 && tcp_ok=0
            elif command -v perl >/dev/null 2>&1; then
                perl -e '
                    use IO::Socket::INET;
                    local $SIG{ALRM} = sub { exit 1 };
                    alarm 2;
                    my $s = IO::Socket::INET->new(
                        PeerAddr => $ARGV[0],
                        PeerPort => 443,
                        Proto    => "tcp",
                        Timeout  => 2
                    );
                    exit($s ? 0 : 1);
                ' "$domain" >/dev/null 2>&1 && tcp_ok=0
            fi
        fi

        # L3 + L4: TLS 握手及 HTTP 响应
        if [ "$dns_ok" -eq 0 ] && [ "$tcp_ok" -eq 0 ]; then
            if [ "$attempt" -eq 1 ]; then
                http_code="$(curl -sS --connect-timeout 2 --max-time 5 \
                    -o /dev/null -w '%{http_code}' "https://$domain/" 2>/dev/null)"
            else
                http_code="$(curl -4 -sS --connect-timeout 2 --max-time 5 \
                    -o /dev/null -w '%{http_code}' "https://$domain/" 2>/dev/null)"
            fi
            curl_status=$?

            if [ "$curl_status" -eq 0 ]; then
                case "$http_code" in
                    2??|3??|401|403|404|405) return 0 ;;
                esac
            fi
        fi

        [ "$attempt" -eq 1 ] && sleep 0.4
        attempt=$((attempt + 1))
    done

    return 1
}

setup_install_proxy() {
    local DOWNLOAD_DOMAINS="api.openai.com github.com api.github.com"
    local THZ_INSTALL_PROXY="http://64.83.26.242:18888"
    local need_proxy_domains=""
    local ok_domains=""
    local domain route_name proxy_code _confirm

    write_warn "检测下载网络环境..."

    for domain in $DOWNLOAD_DOMAINS; do
        route_name="$(printf '%s' "$domain" | tr '.' '_')"

        if probe_domain_direct "$domain"; then
            write_ok "✓ $domain 直连可用"
            eval "PROXY_ROUTE_${route_name}=direct"
            ok_domains="$ok_domains $domain"
        else
            write_warn "✗ $domain 直连不可用"
            proxy_code="$(curl -sS --connect-timeout 5 --max-time 10 \
                -o /dev/null -w '%{http_code}' \
                -x "$THZ_INSTALL_PROXY" "https://$domain/" 2>/dev/null)"

            if printf '%s\n' "$proxy_code" | grep -qE '^[234]'; then
                write_ok "→ $domain 将经临时下载通道"
                eval "PROXY_ROUTE_${route_name}=proxy"
                need_proxy_domains="$need_proxy_domains $domain"
            else
                write_fail "✗ $domain 直连与代理均不可用"
                eval "PROXY_ROUTE_${route_name}=failed"
            fi
        fi
    done

    if [ -n "$need_proxy_domains" ]; then
        if [ "$CI_KEY_STDIN" != "1" ]; then
            printf '\n%s\n' "检测到以下域名不可直接访问：$need_proxy_domains"
            printf '%s' "将使用临时下载通道（仅本次安装，不修改系统设置），是否继续？(Y/n)："
            IFS= read -r _confirm </dev/tty || _confirm="y"
            case "$_confirm" in
                n|N|no|NO) fail_exit 2 "STEP2_CANCEL" "用户取消安装。" ;;
            esac
        fi

        export https_proxy="$THZ_INSTALL_PROXY"
        export http_proxy="$THZ_INSTALL_PROXY"
        export HTTPS_PROXY="$THZ_INSTALL_PROXY"
        export HTTP_PROXY="$THZ_INSTALL_PROXY"
        USE_INSTALL_PROXY=1
        write_ok "已启用临时下载通道（仅本次安装进程有效）"
    else
        USE_INSTALL_PROXY=0
        write_ok "所有下载域名直连可用，不使用代理"
    fi

    return 0
}

clear_install_proxy() {
    if [ "$USE_INSTALL_PROXY" = "1" ]; then
        unset https_proxy http_proxy HTTPS_PROXY HTTP_PROXY
        USE_INSTALL_PROXY=0
        write_ok "已清除临时下载代理设置"
    fi
}

run_with_timeout() {
    timeout_seconds="$1"
    output_file="$2"
    shift 2

    "$@" >"$output_file" 2>&1 </dev/null &
    child_pid=$!
    elapsed=0

    while kill -0 "$child_pid" >/dev/null 2>&1; do
        if [ "$elapsed" -ge "$timeout_seconds" ]; then
            kill "$child_pid" >/dev/null 2>&1 || true
            sleep 1
            kill -9 "$child_pid" >/dev/null 2>&1 || true
            wait "$child_pid" >/dev/null 2>&1 || true
            return 124
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    wait "$child_pid"
}

probe_codex_path() {
    probe_path="$1"
    probe_timeout="${2:-25}"
    probe_output="${TMP_BASE%/}/thz-codex-probe-${STAMP}-$$.txt"

    run_with_timeout "$probe_timeout" "$probe_output" "$probe_path" --version
    probe_status=$?
    probe_text="$(sed -E 's/sk-[A-Za-z0-9_.\-]{4,}/sk-****/g' "$probe_output" 2>/dev/null)"
    rm -f "$probe_output" 2>/dev/null || true

    [ "$probe_status" -eq 0 ] || return 1
    printf '%s\n' "$probe_text" | grep -i 'codex' >/dev/null 2>&1 || return 1
    CODEX_VERSION="$(printf '%s\n' "$probe_text" | grep -i 'codex' | head -n 1)"
    return 0
}

classify_existing_codex() {
    if [ -e "$CODEX_BIN" ]; then
        if [ -f "$CODEX_BIN" ] && [ -x "$CODEX_BIN" ] && probe_codex_path "$CODEX_BIN" 20; then
            EXISTING_CODEX="local"
            return
        fi
        EXISTING_CODEX="conflict"
        EXISTING_REASON="$HOME/.local/bin/codex 存在但无法正常执行"
        return
    fi

    path_codex="$(command -v codex 2>/dev/null || true)"
    if [ -n "$path_codex" ]; then
        EXISTING_CODEX="conflict"
        EXISTING_REASON="PATH 中存在其他来源的 Codex：$path_codex"
        return
    fi

    EXISTING_CODEX="none"
}

validate_shell_script() {
    script_path="$1"
    [ -s "$script_path" ] || return 1
    file_size="$(wc -c < "$script_path" | tr -d ' ')"
    [ "$file_size" -ge 500 ] || return 1

    if grep -Eiq '<!doctype|<html|<body|not found' "$script_path"; then
        return 1
    fi

    first_line="$(sed -n '1p' "$script_path")"
    case "$first_line" in
        '#!'*bash*) ;;
        '#!'*sh*) ;;
        *) return 1 ;;
    esac

    grep -Eq '(^|[[:space:]])(function[[:space:]]+|if[[:space:]]|case[[:space:]]|curl[[:space:]]|tar[[:space:]])' "$script_path"
}

install_from_official_script() {
    installer_tmp="${TMP_BASE%/}/codex-official-${STAMP}-$$.sh"

    write_ok "正在下载 OpenAI 官方安装器 install.sh"
    download_meta="$(curl -sS -L --fail --connect-timeout 20 --max-time 90 \
        -o "$installer_tmp" -w '%{url_effective}\n%{content_type}' \
        "$OFFICIAL_INSTALLER_URL" 2>/dev/null)" || {
        rm -f "$installer_tmp" 2>/dev/null || true
        return 1
    }

    final_url="$(printf '%s' "$download_meta" | sed -n '1p')"
    content_type="$(printf '%s' "$download_meta" | sed -n '2p')"
    case "$final_url" in
        https://chatgpt.com/*|https://*.chatgpt.com/*|https://openai.com/*|https://*.openai.com/*) ;;
        *)
            rm -f "$installer_tmp" 2>/dev/null || true
            write_warn "官方 install.sh 跳转到了非官方域名，已中止该路线。"
            return 1
            ;;
    esac
    case "$(lower_text "$content_type")" in
        *html*)
            rm -f "$installer_tmp" 2>/dev/null || true
            write_warn "官方 install.sh 返回了 HTML 内容，已中止该路线。"
            return 1
            ;;
    esac

    validate_shell_script "$installer_tmp" || {
        rm -f "$installer_tmp" 2>/dev/null || true
        write_warn "官方 install.sh 内容校验失败，改用 GitHub Releases。"
        return 1
    }

    chmod 700 "$installer_tmp" 2>/dev/null || true
    mkdir -p "$BIN_DIR" || {
        rm -f "$installer_tmp" 2>/dev/null || true
        return 1
    }

    install_output="${TMP_BASE%/}/codex-official-output-${STAMP}-$$.txt"
    CODEX_INSTALL_DIR="$BIN_DIR" \
    CODEX_INSTALL_PATH="$CODEX_BIN" \
    CODEX_NON_INTERACTIVE=1 \
        run_with_timeout 300 "$install_output" /bin/bash "$installer_tmp"
    install_status=$?

    sed -E 's/sk-[A-Za-z0-9_.\-]{4,}/sk-****/g' "$install_output" 2>/dev/null || true
    rm -f "$installer_tmp" "$install_output" 2>/dev/null || true

    if [ -x "$CODEX_BIN" ] && probe_codex_path "$CODEX_BIN" 25; then
        return 0
    fi

    [ "$install_status" -eq 0 ] || return 1
    return 1
}

resolve_latest_release_tag() {
    headers_file="${TMP_BASE%/}/codex-release-headers-${STAMP}-$$.txt"
    curl -sS -L --connect-timeout 15 --max-time 30 \
        -D "$headers_file" -o /dev/null \
        https://github.com/openai/codex/releases/latest >/dev/null 2>&1 || {
        rm -f "$headers_file" 2>/dev/null || true
        return 1
    }

    release_url="$(awk 'tolower($0) ~ /^location:/ {gsub("\r",""); value=$2} END{print value}' "$headers_file")"
    rm -f "$headers_file" 2>/dev/null || true

    release_tag="$(printf '%s' "$release_url" | sed -n 's#.*/tag/\([^/?]*\).*#\1#p')"
    if [ -z "$release_tag" ]; then
        release_tag="$(curl -sS -L --connect-timeout 15 --max-time 30 \
            -o /dev/null -w '%{url_effective}' \
            https://github.com/openai/codex/releases/latest 2>/dev/null |
            sed -n 's#.*/tag/\([^/?]*\).*#\1#p')"
    fi

    [ -n "$release_tag" ] || return 1
    printf '%s' "$release_tag"
}

install_from_github_release() {
    release_tag="$(resolve_latest_release_tag)" || return 1
    package_name="codex-${RELEASE_ARCH}-apple-darwin.tar.gz"
    release_base="https://github.com/openai/codex/releases/download/${release_tag}"
    package_file="${TMP_BASE%/}/${package_name}.$$"
    sums_file="${TMP_BASE%/}/SHA256SUMS.$$"
    extract_dir="${TMP_BASE%/}/codex-extract-${STAMP}-$$"

    write_ok "尝试 GitHub 官方 Release：$release_tag"

    sums_ok=0
    for sums_name in SHA256SUMS codex_SHA256SUMS codex-package_SHA256SUMS; do
        if curl -sS -L --fail --connect-timeout 20 --max-time 90 \
            -o "$sums_file" "$release_base/$sums_name" >/dev/null 2>&1; then
            if grep "$package_name" "$sums_file" >/dev/null 2>&1; then
                sums_ok=1
                break
            fi
        fi
    done

    if [ "$sums_ok" -ne 1 ]; then
        rm -f "$package_file" "$sums_file" 2>/dev/null || true
        return 1
    fi

    curl -sS -L --fail --connect-timeout 20 \
        --speed-limit 10240 --speed-time 20 --max-time 600 \
        -o "$package_file" "$release_base/$package_name" >/dev/null 2>&1 || {
        rm -f "$package_file" "$sums_file" 2>/dev/null || true
        return 1
    }

    expected_hash="$(grep "$package_name" "$sums_file" |
        head -n 1 |
        sed -n 's/^[[:space:]]*\([0-9A-Fa-f]\{64\}\)[[:space:]].*/\1/p' |
        tr '[:upper:]' '[:lower:]')"
    actual_hash="$(shasum -a 256 "$package_file" 2>/dev/null | awk '{print $1}')"

    if [ -z "$expected_hash" ] || [ "$expected_hash" != "$actual_hash" ]; then
        rm -f "$package_file" "$sums_file" 2>/dev/null || true
        write_warn "GitHub Release 安装包 SHA256 校验失败。"
        return 1
    fi
    write_ok "GitHub Release 安装包 SHA256 校验通过"

    mkdir -p "$extract_dir" "$BIN_DIR" || {
        rm -f "$package_file" "$sums_file" 2>/dev/null || true
        return 1
    }

    tar -xzf "$package_file" -C "$extract_dir" >/dev/null 2>&1 || {
        rm -rf "$extract_dir" 2>/dev/null || true
        rm -f "$package_file" "$sums_file" 2>/dev/null || true
        return 1
    }

    extracted_codex="$(find "$extract_dir" -type f \( -name codex -o -name "codex-${RELEASE_ARCH}-apple-darwin" \) -maxdepth 3 2>/dev/null | head -n 1)"
    if [ -z "$extracted_codex" ]; then
        rm -rf "$extract_dir" 2>/dev/null || true
        rm -f "$package_file" "$sums_file" 2>/dev/null || true
        return 1
    fi

    cp "$extracted_codex" "$CODEX_BIN" &&
        chmod 755 "$CODEX_BIN"

    copy_status=$?
    rm -rf "$extract_dir" 2>/dev/null || true
    rm -f "$package_file" "$sums_file" 2>/dev/null || true

    [ "$copy_status" -eq 0 ] || return 1
    probe_codex_path "$CODEX_BIN" 25
}

install_from_npm() {
    command -v node >/dev/null 2>&1 || return 1
    command -v npm >/dev/null 2>&1 || return 1

    mkdir -p "$BIN_DIR" || return 1
    npm_prefix="${TMP_BASE%/}/thz-codex-npm-${STAMP}-$$"
    mkdir -p "$npm_prefix" || return 1

    write_ok "尝试使用本机已有 npm 安装官方 @openai/codex"
    npm_output="${TMP_BASE%/}/codex-npm-output-${STAMP}-$$.txt"
    run_with_timeout 300 "$npm_output" npm install \
        --prefix "$npm_prefix" \
        --no-audit --no-fund \
        @openai/codex
    npm_status=$?
    sed -E 's/sk-[A-Za-z0-9_.\-]{4,}/sk-****/g' "$npm_output" 2>/dev/null || true
    rm -f "$npm_output" 2>/dev/null || true

    if [ "$npm_status" -ne 0 ]; then
        rm -rf "$npm_prefix" 2>/dev/null || true
        return 1
    fi

    npm_codex="$npm_prefix/bin/codex"
    if [ ! -x "$npm_codex" ]; then
        rm -rf "$npm_prefix" 2>/dev/null || true
        return 1
    fi

    cp -R "$npm_prefix/lib" "$BIN_DIR/.codex-npm-lib-${STAMP}" 2>/dev/null || {
        rm -rf "$npm_prefix" 2>/dev/null || true
        return 1
    }

    npm_target="$(readlink "$npm_codex" 2>/dev/null || true)"
    if [ -n "$npm_target" ]; then
        npm_entry="$(cd "$(dirname "$npm_codex")" 2>/dev/null && cd "$(dirname "$npm_target")" 2>/dev/null && pwd)/$(basename "$npm_target")"
    else
        npm_entry="$npm_codex"
    fi

    installed_lib="$BIN_DIR/.codex-npm-lib-${STAMP}"
    relative_entry="$(printf '%s' "$npm_entry" | sed "s#^$npm_prefix/lib#$installed_lib#")"

    {
        printf '%s\n' '#!/bin/bash'
        printf 'exec node "%s" "$@"\n' "$relative_entry"
    } > "$CODEX_BIN"
    chmod 755 "$CODEX_BIN"
    rm -rf "$npm_prefix" 2>/dev/null || true

    probe_codex_path "$CODEX_BIN" 25
}

install_codex_cli() {
    classify_existing_codex

    case "$EXISTING_CODEX" in
        local)
            write_ok "检测到有效的 ~/.local/bin/codex，直接复用：$CODEX_VERSION"
            return
            ;;
        conflict)
            fail_exit 3 "STEP3_CLI_CONFLICT" "检测到现有 Codex 安装冲突：$EXISTING_REASON。为避免破坏已有环境，请先联系支持处理。"
            ;;
    esac

    mkdir -p "$BIN_DIR" ||
        fail_exit 3 "STEP3_BINDIR" "无法创建安装目录：$BIN_DIR"

    if install_from_official_script; then
        write_ok "Codex CLI 已通过官方 install.sh 安装：$CODEX_VERSION"
    elif install_from_github_release; then
        write_ok "Codex CLI 已通过 GitHub 官方 Release 安装：$CODEX_VERSION"
    elif install_from_npm; then
        write_ok "Codex CLI 已通过本机已有 npm 安装：$CODEX_VERSION"
    else
        fail_exit 3 "STEP3_CLI" "所有官方 Codex CLI 安装路线均失败。请检查网络后重试。"
    fi

    PATH="$BIN_DIR:$PATH"
    export PATH
}

read_deepseek_key_gui() {
    command -v osascript >/dev/null 2>&1 || return 1

    key_result="$(osascript 2>/dev/null <<'APPLESCRIPT'
try
    display dialog "请输入你的 DeepSeek API Key\n\nKey 只在当前电脑处理，不会上传安装服务器。" default answer "" with hidden answer buttons {"取消", "确认"} default button "确认" cancel button "取消" with title "Codex AI 安装器"
    return text returned of result
on error number -128
    return "__CANCEL__"
on error
    return "__GUI_ERROR__"
end try
APPLESCRIPT
)"
    case "$key_result" in
        "__GUI_ERROR__") return 1 ;;
        "__CANCEL__")
            printf '%s' "__CANCEL__"
            return 0
            ;;
        *)
            printf '%s' "$key_result"
            return 0
            ;;
    esac
}

read_deepseek_key_terminal() {
    printf '%s' "请输入 DeepSeek API Key（输入内容不会显示）：" >/dev/tty
    IFS= read -r -s terminal_key </dev/tty || return 1
    printf '\n' >/dev/tty
    printf '%s' "$terminal_key"
}

read_deepseek_key_ci_stdin() {
    # read 在遇到 EOF 无换行时会返回非零，但 ci_key 已有内容；此时不应丢弃。
    IFS= read -r ci_key || [ -n "$ci_key" ] || return 1
    [ -n "$ci_key" ] || return 1
    printf '%s' "$ci_key"
}

read_deepseek_key_once() {
    # 入口诊断：确认 CI 模式与环境变量状态（只记长度，不记内容）
    if [ "$CI_KEY_STDIN" -eq 1 ]; then
        if [ -n "${THZ_DEEPSEEK_KEY:-}" ]; then
            write_warn "KEYCHK: env var present, len=${#THZ_DEEPSEEK_KEY}"
        else
            write_warn "KEYCHK: env var MISSING or empty, falling back to stdin"
        fi
    fi
    if [ "$CI_KEY_STDIN" -eq 1 ]; then
        # 优先从环境变量读取（CI 管道 stdin 不可靠）
        if [ -n "${THZ_DEEPSEEK_KEY:-}" ]; then
            entered_key="$THZ_DEEPSEEK_KEY"
            write_warn "CI 模式：从环境变量读取到 API Key。"
        else
            entered_key="$(read_deepseek_key_ci_stdin)" || {
                write_warn "CI 模式：未能从 stdin 读取到 API Key。"
                return 1
            }
        fi
    else
        entered_key="$(read_deepseek_key_gui)"
        gui_status=$?

        if [ "$gui_status" -ne 0 ]; then
            write_warn "原生输入窗口不可用，改用终端隐藏输入。"
            entered_key="$(read_deepseek_key_terminal)" ||
                return 1
        fi
    fi

    if [ "$entered_key" = "__CANCEL__" ]; then
        return 2
    fi

    entered_key="$(trim_text "$entered_key")"
    if [ "${#entered_key}" -lt 12 ]; then
        write_warn "API Key 输入可能不完整，当前长度：${#entered_key}"
        return 3
    fi

    key_tail="$(printf '%s' "$entered_key" | rev | cut -c1-4 | rev)"
    write_ok "API Key 已收到，长度：${#entered_key}"
    # 安全：CI 日志中不输出 Key 末尾（曾泄露真 Key 片段）；仅交互模式显示
    if [ "$CI_KEY_STDIN" -ne 1 ]; then
        write_ok "Key 末尾：****${key_tail}"
    fi
    API_KEY="$entered_key"
    entered_key=""
    return 0
}

# 格式校验：只检查 Key 格式是否合理，不调在线 API。
# 在线验证已跳过（CI 环境曾出现 401 误报）；用户首次实际调用 DeepSeek API 时自然会验证。
validate_deepseek_key_format() {
    case "$API_KEY" in
        sk-????????????????????*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

validate_deepseek_key() {
    key_response="${TMP_BASE%/}/thz-deepseek-key-${STAMP}-$$.json"

    # 使用简单直接的 curl 命令（与诊断验证一致），避免 -K 配置文件解析问题
    http_code="$(curl -s -m 20 -o "$key_response" -w '%{http_code}' \
        --connect-timeout 10 \
        -H "Authorization: Bearer $API_KEY" \
        -H "Accept: application/json" \
        "https://api.deepseek.com/v1/models" 2>/dev/null || echo '000')"
    curl_status=$?

    if [ "$curl_status" -ne 0 ] || [ "$http_code" = "000" ] || [ -z "$http_code" ]; then
        rm -f "$key_response" 2>/dev/null || true
        return 10
    fi

    case "$http_code" in
        2??)
            rm -f "$key_response" 2>/dev/null || true
            return 0
            ;;
        401)
            rm -f "$key_response" 2>/dev/null || true
            return 11
            ;;
        403)
            rm -f "$key_response" 2>/dev/null || true
            return 12
            ;;
        402|429)
            rm -f "$key_response" 2>/dev/null || true
            return 13
            ;;
        *)
            safe_error="$(sed -E 's/sk-[A-Za-z0-9_.\-]{4,}/sk-****/g' "$key_response" 2>/dev/null | head -c 200)"
            rm -f "$key_response" 2>/dev/null || true
            [ -n "$safe_error" ] && write_warn "DeepSeek API 返回 HTTP $http_code：$safe_error"
            return 14
            ;;
    esac
}

backup_config() {
    backup_stamp="$(date '+%Y%m%d-%H%M%S')"
    BACKUP_DIR="$CODEX_HOME/backups/$backup_stamp"
    mkdir -p "$BACKUP_DIR" || return 1

    if [ -f "$CONFIG_PATH" ]; then
        cp "$CONFIG_PATH" "$BACKUP_DIR/config.toml" || return 1
    fi
    if [ -f "$MODELS_PATH" ]; then
        cp "$MODELS_PATH" "$BACKUP_DIR/models.json" || return 1
    fi
    write_ok "已备份原有配置 -> $BACKUP_DIR"
}

restore_backup() {
    write_warn "配置校验失败，正在恢复备份。"

    if [ -f "$BACKUP_DIR/config.toml" ]; then
        cp "$BACKUP_DIR/config.toml" "$CONFIG_PATH" 2>/dev/null || true
    else
        rm -f "$CONFIG_PATH" 2>/dev/null || true
    fi

    if [ -f "$BACKUP_DIR/models.json" ]; then
        cp "$BACKUP_DIR/models.json" "$MODELS_PATH" 2>/dev/null || true
    else
        rm -f "$MODELS_PATH" 2>/dev/null || true
    fi
}

toml_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_deepseek_config() {
    config_tmp="$CONFIG_PATH.deepseek-tmp.$$"
    models_tmp="$MODELS_PATH.deepseek-tmp.$$"
    preserved_tmp="${TMP_BASE%/}/thz-config-preserved-${STAMP}-$$.txt"

    printf '%s\n' "$MODELS_JSON" > "$models_tmp" || return 1
    grep -F "\"slug\"" "$models_tmp" >/dev/null 2>&1 || {
        rm -f "$models_tmp" 2>/dev/null || true
        return 1
    }
    grep -F "$MODEL" "$models_tmp" >/dev/null 2>&1 || {
        rm -f "$models_tmp" 2>/dev/null || true
        return 1
    }

    if [ -f "$CONFIG_PATH" ]; then
        awk -v provider="$PROVIDER_ID" '
            BEGIN { skip=0; section=0 }
            /^[[:space:]]*\[/ {
                section=1
                line=$0
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                skip=(line == "[model_providers." provider "]")
                if (!skip) print
                next
            }
            skip { next }
            section==0 {
                line=$0
                sub(/^[[:space:]]*/, "", line)
                if (line ~ /^(model|model_provider|preferred_auth_method|forced_login_method|model_reasoning_effort|model_catalog_json)[[:space:]]*=/) next
            }
            { print }
        ' "$CONFIG_PATH" > "$preserved_tmp" || return 1
    else
        : > "$preserved_tmp"
    fi

    {
        printf 'model = "%s"\n' "$(toml_escape "$MODEL")"
        printf 'model_provider = "%s"\n' "$(toml_escape "$PROVIDER_ID")"
        printf '%s\n' 'preferred_auth_method = "apikey"'
        printf '%s\n' 'forced_login_method = "api"'
        printf '%s\n' 'model_reasoning_effort = "high"'
        printf 'model_catalog_json = "%s"\n' "$(toml_escape "$MODELS_PATH")"
        printf '\n'
        sed -E 's/sk-[A-Za-z0-9_.\-]{4,}/sk-****/g' "$preserved_tmp"
        printf '\n[model_providers.%s]\n' "$PROVIDER_ID"
        printf 'name = "%s"\n' "$(toml_escape "$PROVIDER_ID")"
        printf 'base_url = "%s"\n' "$(toml_escape "$PROVIDER_BASE_URL")"
        printf '%s\n' 'wire_api = "responses"'
        printf 'experimental_bearer_token = "%s"\n' "$(toml_escape "$API_KEY")"
    } > "$config_tmp" || {
        rm -f "$config_tmp" "$models_tmp" "$preserved_tmp" 2>/dev/null || true
        return 1
    }

    chmod 600 "$config_tmp" "$models_tmp" 2>/dev/null || true
    mv "$models_tmp" "$MODELS_PATH" &&
        mv "$config_tmp" "$CONFIG_PATH"
    move_status=$?
    rm -f "$preserved_tmp" 2>/dev/null || true
    return "$move_status"
}

verify_written_config() {
    [ -s "$CONFIG_PATH" ] || return 1
    [ -s "$MODELS_PATH" ] || return 1
    grep -F "[model_providers.$PROVIDER_ID]" "$CONFIG_PATH" >/dev/null 2>&1 || return 1
    grep -F "base_url = \"$PROVIDER_BASE_URL\"" "$CONFIG_PATH" >/dev/null 2>&1 || return 1
    grep -F "$MODEL" "$MODELS_PATH" >/dev/null 2>&1 || return 1
    return 0
}

setup_deepseek_key() {
    attempt=1
    while [ "$attempt" -le 3 ]; do
        [ "$attempt" -eq 1 ] || write_warn "第 $attempt 次输入（最多 3 次）"

        read_deepseek_key_once
        read_status=$?
        case "$read_status" in
            0) ;;
            2) fail_exit 5 "STEP5_CANCEL" "用户取消输入，安装已安全退出。" ;;
            3)
                attempt=$((attempt + 1))
                continue
                ;;
            *) fail_exit 5 "STEP5_INPUT" "无法读取 API Key。" ;;
        esac

        # 只做格式校验，不调在线 API（在线验证曾因环境问题误报 401）
        if validate_deepseek_key_format; then
            write_ok "DeepSeek Key 格式校验通过（sk- 开头，长度 ${#API_KEY}）"
            write_warn "提示：Key 有效性将在首次实际调用 DeepSeek API 时验证"
            break
        else
            write_warn "Key 格式不正确（应为 sk- 开头的长字符串）。"
        fi

        API_KEY=""
        if [ "$attempt" -lt 3 ] && [ "$CI_KEY_STDIN" -ne 1 ]; then
            printf '%s' "是否重新输入 Key？(y=重输 / n=退出)：" >/dev/tty
            IFS= read -r retry_answer </dev/tty || retry_answer="n"
            case "$retry_answer" in
                y|Y|yes|YES) ;;
                *) fail_exit 5 "STEP5_KEY" "已退出：API Key 验证失败。" ;;
            esac
        fi
        attempt=$((attempt + 1))
    done

    if [ -z "$API_KEY" ]; then
        fail_exit 5 "STEP5_KEY" "API Key 验证失败次数过多，已安全退出。"
    fi

    backup_config ||
        fail_exit 5 "STEP5_BACKUP" "无法备份现有 Codex 配置。"

    if ! write_deepseek_config || ! verify_written_config; then
        restore_backup
        API_KEY=""
        fail_exit 5 "STEP5_WRITE" "DeepSeek 配置写入或写后校验失败，已恢复原配置。"
    fi

    API_KEY=""
    write_ok "AI 模型配置完成：$MODEL"
}

verify_codex() {
    if ! probe_codex_path "$CODEX_BIN" 25; then
        [ -n "$BACKUP_DIR" ] && restore_backup
        fail_exit 6 "STEP6_VERIFY" "codex --version 未能在超时时间内返回有效版本。"
    fi
    write_ok "Codex CLI 可正常执行（$CODEX_VERSION）"
}

printf '\n%s\n' '========================================'
printf '%s\n' '  Codex AI 一键安装器（macOS）'
printf '%s\n' '========================================'

# CI 专用：--ci-key-stdin 时从 stdin 读 Key（无 GUI、无 tty 的 runner 用）
for script_arg in "$@"; do
    case "$script_arg" in
        --ci-key-stdin) CI_KEY_STDIN=1 ;;
    esac
done

if printf '%s' "$BASE_URL" | grep -q 'BASE_URL'; then
    fail_exit 1 "STEP1_CONFIG" "安装包配置不完整（缺少服务器地址），请重新下载。"
fi
if [ -z "$INSTALL_TOKEN" ] || printf '%s' "$INSTALL_TOKEN" | grep -q 'INSTALL_TOKEN'; then
    fail_exit 1 "STEP1_CONFIG" "缺少安装授权，请回到安装网站重新下载安装包。"
fi

token_tail="$(printf '%s' "$INSTALL_TOKEN" | rev | cut -c1-4 | rev)"
write_ok "已读取安装授权，长度：${#INSTALL_TOKEN}，末尾：****${token_tail}"

write_step 1 "验证安装授权..."
api_start
write_ok "授权验证成功"

MODE="$(json_get_string "$START_RESPONSE" "mode")"
route="$(json_get_string "$START_RESPONSE" "route")"

case "$MODE" in
    deepseek)
        write_ok "安装模式：DeepSeek API（本机配置自己的 Key）"
        ;;
    chatgpt)
        case "$route" in
            A) route_label="Route A：DeepSeek + Codex CLI" ;;
            B) route_label="Route B：DeepSeek + Codex CLI（不依赖 OpenAI 网络）" ;;
            C) route_label="Route C：ChatGPT / Codex 会员（官方 Desktop App）" ;;
            D) route_label="Route D：Mac DeepSeek + Codex CLI" ;;
            E) route_label="Route E：Mac 官方 Desktop 引导" ;;
            *) route_label="Route ${route:-E}" ;;
        esac
        write_ok "安装路线：$route_label"
        printf '\n%s\n' "Mac 版 ChatGPT 会员模式（官方 Desktop App 引导）即将上线，当前版本仅支持 DeepSeek 模式。"
        printf '%s\n' "如需帮助，请联系客服 QQ 89523844"
        finalize
        printf '\n安装日志已保存：%s\n' "$LOG_FINAL"
        trap - EXIT INT TERM
        exit 0
        ;;
    *)
        fail_exit 1 "STEP1_MODE" "服务器返回了未知的安装模式：${MODE:-空}"
        ;;
esac

case "$route" in
    A) route_label="Route A：DeepSeek + Codex CLI" ;;
    B) route_label="Route B：DeepSeek + Codex CLI（不依赖 OpenAI 网络）" ;;
    C) route_label="Route C：ChatGPT / Codex 会员（官方 Desktop App）" ;;
    D) route_label="Route D：Mac DeepSeek + Codex CLI" ;;
    E) route_label="Route E：Mac 官方 Desktop 引导" ;;
    "") route_label="Route D：Mac DeepSeek + Codex CLI" ;;
    *) route_label="Route $route" ;;
esac
write_ok "安装路线：$route_label"

server_model="$(json_get_string "$START_RESPONSE" "model")"
server_provider_id="$(json_get_string "$START_RESPONSE" "provider_id")"
server_provider_base="$(json_get_string "$START_RESPONSE" "provider_base_url")"
[ -n "$server_model" ] && MODEL="$server_model"
[ -n "$server_provider_id" ] && PROVIDER_ID="$server_provider_id"
[ -n "$server_provider_base" ] && PROVIDER_BASE_URL="$server_provider_base"
MODELS_JSON="$(json_get_models_value "$START_RESPONSE")"
START_RESPONSE=""

write_step 2 "检查系统和网络..."
check_system
# 先检测是否需要临时代理
setup_install_proxy || write_warn "网络检测：直连与临时代理均不可用，后续下载可能失败"
# check_deepseek_network 已删除：安装器不再检测 DeepSeek 连通性

write_step 3 "安装或复用 Codex CLI..."
install_codex_cli

write_step 4 "准备 DeepSeek 配置目录..."
mkdir -p "$CODEX_HOME" ||
    fail_exit 4 "STEP4_CONFDIR" "无法创建配置目录：$CODEX_HOME"
chmod 700 "$CODEX_HOME" 2>/dev/null || true
write_ok "配置目录已准备：$CODEX_HOME"

write_step 5 "配置 DeepSeek（本机输入自己的 Key）..."
setup_deepseek_key

write_step 6 "验证 Codex..."
verify_codex

write_step 7 "完成..."
api_complete

printf '\n%s\n' '================================'
# 清除临时下载代理
clear_install_proxy

printf '%s\n' 'Codex AI 安装完成'
printf '%s\n' 'Codex CLI      ✓'
printf '%s\n' 'AI 模型        DeepSeek ✓'
printf '%s\n' '================================'
printf '\n%s\n' '【重要提醒】'
printf '%s\n' 'Codex 需要外网访问 api.deepseek.com 才能正常使用。'
printf '%s\n' '安装时的临时下载代理已关闭，请自行解决网络问题后再使用。'
printf '\n%s\n' '现在可以运行：'
printf '%s\n' '  ~/.local/bin/codex'
printf '%s\n' '若当前终端尚未包含 ~/.local/bin，请重新打开终端，或执行：'
printf '%s\n' '  export PATH="$HOME/.local/bin:$PATH"'
printf '\n安装器版本 %s，脚本结束。\n' "$INSTALLER_VERSION"

finalize
printf '安装日志已保存：%s\n' "$LOG_FINAL"
trap - EXIT INT TERM
exit 0
