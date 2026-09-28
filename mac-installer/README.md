# Mac 版 Codex 一键安装器（Route D）

macOS 专用：在本机配置你自己的 DeepSeek API Key，让 Codex CLI 走 DeepSeek。

## 文件

| 文件 | 说明 |
|---|---|
| `install-macos.sh` | 安装器本体（bash 3.2，macOS 12+，Intel/ARM 通用） |
| `THZ-Codex-Setup.command` | 双击启动器（需 `chmod +x`） |
| `BACKEND-PATCH.md` | 服务端需要配合的改动（staging 先行，生产需批准） |
| `STAGING-NEEDS.md` | staging 联调需要的资源清单 |
| `../.github/workflows/mac-build.yml` | GitHub Actions：lint + macos-14/15 真机测试 |

## 用户安装步骤

1. 从安装网站下载 `THZ-Codex-Setup.command`（内含 install-macos.sh）。
2. 双击 `THZ-Codex-Setup.command`。
3. **如果是首次运行，macOS 可能会拦截**，二选一：
   - **推荐**：在文件上**右键 → 打开** → 点击"打开"。只需做一次。
   - 或：系统设置 → 隐私与安全性 → 安全性 → 仍要打开。
   
   > 原因：当前版本未做 Apple 公证（省 $99/年开发者年费），Gatekeeper 会提示"身份不明的开发者"。脚本本身开源可查，不联网上传任何个人信息（只上报安装成功/失败状态和脱敏日志）。
4. 按提示输入你的 DeepSeek API Key（输入时不显示，验证通过后才写入配置）。
5. 看到 `Codex AI 安装完成` 即成功。日志在 `~/Library/Logs/THZ-Codex-Setup-*.log`，出问题发给客服 QQ **89523844**。

## 路线说明

- **Route D（本版本）**：Mac DeepSeek + Codex CLI ✅ 已实现
- **Route E（未开放）**：Mac 官方 Desktop 引导——ChatGPT 会员模式暂不支持，选了会提示"即将上线"并安全退出，不会装一半。

## 开发者

```bash
# 静态检查
~/workspace/bin/shellcheck --shell=bash mac-installer/install-macos.sh
bash -n mac-installer/install-macos.sh

# CI 无头测试（无 GUI 时用 stdin 传 Key）
printf 'sk-...\n' | bash mac-installer/install-macos.sh --ci-key-stdin
```

staging 联调需求见 `STAGING-NEEDS.md`，后端改动见 `BACKEND-PATCH.md`。
