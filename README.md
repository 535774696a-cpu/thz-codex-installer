# thz-codex-installer

Codex 一键安装器的构建与持续测试仓库。

- Windows 安装器：EXE 构建 + 安装回归（`.github/workflows/`）
- Mac 安装器：`mac-installer/`（bash 脚本 + `.command` 双击启动器 + `mac-build.yml` 真机测试）

Mac 版当前只实现 **Route D**（DeepSeek + Codex CLI）；Route E（官方 Desktop 引导）待定。
