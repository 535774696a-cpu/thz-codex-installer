#!/bin/bash
set +x
umask 077
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CONFIG_PATH="$CODEX_HOME/config.toml"
MODELS_PATH="$CODEX_HOME/models.json"
BACKUP_DIR="$CODEX_HOME/.deepseek-configurator-backup"
API_KEY=""
TMP_BASE="${TMPDIR:-/tmp}"
STAMP="$(date '+%Y%m%d-%H%M%S')"
MODEL="deepseek-chat"
PROVIDER_ID="deepseek"
PROVIDER_BASE_URL="https://api.deepseek.com"
MODELS_JSON='{"models":[{"slug":"deepseek-chat","display_name":"DeepSeek Chat","description":"DeepSeek Chat","default_reasoning_level":"high","supported_reasoning_levels":[{"effort":"high","description":"High reasoning effort"}],"shell_type":"shell_command","visibility":"list","minimal_client_version":"0.0.0","supported_in_api":true,"priority":1}]}'

toml_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

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

backup_config() {
    if [ -d "$BACKUP_DIR" ]; then return 0; fi
    local staged
    staged="$(mktemp -d "$CODEX_HOME/.deepseek-backup.XXXXXX")" || return 1
    for name in config.toml models.json; do
        if [ -f "$CODEX_HOME/$name" ]; then
            cp -p "$CODEX_HOME/$name" "$staged/$name" || { rm -rf "$staged"; return 1; }
        fi
    done
    mv "$staged" "$BACKUP_DIR"
}

restore_backup() {
    for name in config.toml models.json; do
        if [ -f "$BACKUP_DIR/$name" ]; then
            cp -p "$BACKUP_DIR/$name" "$CODEX_HOME/$name" || return 1
        else
            rm -f "$CODEX_HOME/$name" || return 1
        fi
    done
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
        cat "$preserved_tmp"
        printf '\n[model_providers.%s]\n' "$PROVIDER_ID"
        printf 'name = "%s"\n' "$(toml_escape "$PROVIDER_ID")"
        printf 'base_url = "%s"\n' "$(toml_escape "$PROVIDER_BASE_URL")"
        printf '%s\n' 'wire_api = "responses"'
        printf 'experimental_bearer_token = "%s"\n' "$(toml_escape "$API_KEY")"
    } > "$config_tmp" || {
        rm -f "$config_tmp" "$models_tmp" "$preserved_tmp" 2>/dev/null || true
        return 1
    }

    chmod 600 "$config_tmp" "$models_tmp" || return 1
    verify_written_config "$config_tmp" "$models_tmp" || return 1
    mv "$models_tmp" "$MODELS_PATH" &&
        mv "$config_tmp" "$CONFIG_PATH"
    move_status=$?
    rm -f "$preserved_tmp" 2>/dev/null || true
    return "$move_status"
}

verify_written_config() {
    local CONFIG_PATH="${1:-$CONFIG_PATH}" MODELS_PATH="${2:-$MODELS_PATH}"
    [ -s "$CONFIG_PATH" ] || return 1
    [ -s "$MODELS_PATH" ] || return 1
    grep -F "[model_providers.$PROVIDER_ID]" "$CONFIG_PATH" >/dev/null 2>&1 || return 1
    grep -F "base_url = \"$PROVIDER_BASE_URL\"" "$CONFIG_PATH" >/dev/null 2>&1 || return 1
    grep -F "$MODEL" "$MODELS_PATH" >/dev/null 2>&1 || return 1
    return 0
}

cleanup() {
    API_KEY=""
    rm -f "$CONFIG_PATH.deepseek-tmp.$$" "$MODELS_PATH.deepseek-tmp.$$" "${TMP_BASE%/}/thz-config-preserved-${STAMP}-$$.txt"
}
trap cleanup EXIT
trap 'exit 1' INT TERM
clear=0
ci_stdin=0
for arg in "$@"; do
    case "$arg" in
        --clear) clear=1 ;;
        --ci-key-stdin) ci_stdin=1 ;; # Test-only: dummy keys from stdin.
        *) printf '%s\n' '未知参数。' >&2; exit 1 ;;
    esac
done
mkdir -p "$CODEX_HOME" || exit 1
if [ "$clear" -eq 1 ]; then
    if [ -d "$BACKUP_DIR" ]; then
        restore_backup && rm -rf "$BACKUP_DIR" || { printf '%s\n' '清除失败。' >&2; exit 1; }
    elif [ -f "$CONFIG_PATH" ]; then
        # Without a backup, remove only the provider and matching generated root values.
        active_provider="$(awk '/^[[:space:]]*\[/ {exit} /^[[:space:]]*model_provider[[:space:]]*=[[:space:]]*"deepseek"[[:space:]]*$/ {print "1"}' "$CONFIG_PATH")"
        awk -v active="$active_provider" -v catalog="model_catalog_json = \"$(toml_escape "$MODELS_PATH")\"" '
            /^[[:space:]]*\[/ { section=1; line=$0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", line); skip=(line == "[model_providers.deepseek]") }
            skip { next }
            active == "1" && !section && ($0 ~ /^(model = "deepseek-chat"|model_provider = "deepseek"|preferred_auth_method = "apikey"|forced_login_method = "api"|model_reasoning_effort = "high")$/ || $0 == catalog) { next }
            { print }
        ' "$CONFIG_PATH" > "$CONFIG_PATH.deepseek-tmp.$$" &&
        chmod 600 "$CONFIG_PATH.deepseek-tmp.$$" &&
        mv "$CONFIG_PATH.deepseek-tmp.$$" "$CONFIG_PATH" || { printf '%s\n' '清除失败。' >&2; exit 1; }
    fi
    printf '%s\n' 'DeepSeek 配置已清除。'
    exit 0
fi
# Test-only environment input: use dummy keys in CI.
if [ "$ci_stdin" -eq 1 ]; then
    IFS= read -r API_KEY || [ -n "$API_KEY" ] || exit 1
elif [ -n "${THZ_DEEPSEEK_KEY:-}" ]; then
    API_KEY="$THZ_DEEPSEEK_KEY"
else
    API_KEY="$(read_deepseek_key_gui)" || {
        [ -t 0 ] || { printf '%s\n' '无法交互输入。' >&2; exit 1; }
        API_KEY="$(read_deepseek_key_terminal)" || exit 1
    }
fi
unset THZ_DEEPSEEK_KEY
API_KEY="$(printf '%s' "$API_KEY" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
validate_deepseek_key_format || { API_KEY=""; printf '%s\n' 'Key 格式不正确。' >&2; exit 1; }
backup_config || { API_KEY=""; printf '%s\n' '备份失败。' >&2; exit 1; }
# Keep a separate rollback snapshot for repeated configuration attempts.
rollback="$(mktemp -d "$CODEX_HOME/.deepseek-rollback.XXXXXX")" || exit 1
for name in config.toml models.json; do
    if [ -f "$CODEX_HOME/$name" ]; then
        cp -p "$CODEX_HOME/$name" "$rollback/$name" || exit 1
    fi
done
write_deepseek_config
write_status=$?
API_KEY=""
if [ "$write_status" -ne 0 ] || ! verify_written_config; then
    BACKUP_DIR="$rollback"
    restore_backup || { printf '%s\n' '恢复失败，备份已保留。' >&2; exit 1; }
    rm -rf "$rollback"
    printf '%s\n' '配置失败，已恢复原配置。' >&2
    exit 1
fi
rm -rf "$rollback"
printf '%s\n' 'DeepSeek 配置完成（sk-****）。'
