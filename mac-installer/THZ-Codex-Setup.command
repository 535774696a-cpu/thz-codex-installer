#!/bin/bash
# 需 chmod +x mac-installer/THZ-Codex-Setup.command

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
cd "$SCRIPT_DIR" || exit 1

if [ ! -f "./install-macos.sh" ]; then
    printf '%s\n' "未找到 install-macos.sh，请确认安装器文件完整。"
    exit 1
fi

exec /bin/bash ./install-macos.sh "$@"
