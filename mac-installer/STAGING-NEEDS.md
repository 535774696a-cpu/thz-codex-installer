# Staging 后端需求（STAGING-NEEDS）

> 用途：GitHub Actions macOS runner 回归测试（每版 10 次，发布前 20~50 次）的真链路后端。
> 由我（parent agent）在服务器上搭建。本文件只列需求，不含任何生产修改。

## 1. 部署形态

- **独立进程 + 独立端口**，不碰生产服务。建议端口 `18081`（若占用另选，需同步更新 workflow）。
- **独立数据库**：另建 sqlite 文件（如 `/opt/codex-installer-staging/data/staging.db`），绝不连生产库。
- **独立代码目录**：如 `/opt/codex-installer-staging/`，从生产代码复制后应用补丁。

## 2. 代码版本（按顺序应用）

1. 生产代码完整复制（`/opt/codex-installer` → `/opt/codex-installer-staging`，不含生产 DB）。
2. P0 的 4 个后端补丁（`~/workspace/thz-ops/codex-fix/backend-patch/*.patch`）：`/api/installer/fail` 等。
   - 注：生产尚未部署这 4 个补丁，staging 必须先有，否则 Mac 安装器的失败上报无处可去。
3. 本目录 `BACKEND-PATCH.md` 的 5 处改动 + 模板文件 `Install-Codex-Mac.sh.template`。

## 3. 环境变量（对照生产复制，以下为差异/新增）

| 变量 | staging 值 | 说明 |
|---|---|---|
| `MACOS_AVAILABLE` | `1` | 打开 Mac 路线 |
| 数据目录/DB 路径 | staging 独立路径 | 与生产隔离 |
| 监听端口 | `18081`（建议） | workflow 目标地址 |
| 其余 | 与生产一致 | `public_base_url` 注意：模板里替换的 `__BASE_URL__` 应为 staging 地址，否则安装器会去打生产 |

> ⚠️ `public_base_url` 若指向生产域名，staging 下发的安装器会把 `/start|/fail|/complete`
> 发往生产。staging 测试必须把它设为 staging 自己的地址
> （如 `http://<服务器IP>:18081`；若无公网映射，GHA runner 需经 tailscale/代理访问——见 §5）。

## 4. 测试 token 获取（CI 调用链）

GHA runner 每次全新 VM、IP 不同，匿名通道（无 session_token）可用，
`POST /api/installer/select-route` 按 IP 限流 30 次/15 分钟，10 次回归够用。

workflow 步骤（伪代码）：

```bash
STAGING="http://<staging-host>:18081"
# 1. 选路（匿名）
resp=$(curl -s -X POST "$STAGING/api/installer/select-route" \
  -H 'Content-Type: application/json' \
  -d '{"platform":"macos","network":"openai_ok","mode":"deepseek"}')
token=$(json_get install_token)   # 无 jq，用 sed/grep 提取
# 2. 下载安装器
curl -s -X POST "$STAGING/api/installer/download-mac" \
  -H 'Content-Type: application/json' \
  -d "{\"install_token\":\"$token\"}" -o THZ-Codex-Setup.command
chmod +x THZ-Codex-Setup.command
# 3a. 假 Key 全流程（预期在 step 5 API 验证失败 → 验证 /fail 上报链路）
printf 'sk-fake-key-for-ci-test-0000' | ./THZ-Codex-Setup.command --ci-key-stdin
# 3b. 无 token（预期 step 1 失败）
sed 's/__INSTALL_TOKEN__//' install-macos.sh | bash -s   # 占位符未替换路径
# 3c. 假 token（预期 step 1 失败）
...
```

> 注：`--ci-key-stdin` 开关需要安装器支持（从 stdin 读 Key，跳过 osascript 弹窗，
> runner 无 GUI）。这要求 `install-macos.sh` 实现该 flag——已列入脚本需求。

## 5. 网络可达性（待 parent 确认）

GHA macOS runner 在公网，staging 端口需公网可达，或走已有代理。
选项按推荐排序：

1. 服务器防火墙放行 `18081` 仅 GitHub Actions IP 段（段在变，维护成本高，不推荐长期）。
2. **推荐**：staging 只监听 tailscale 内网 + 给 CI 一个短效 token 的代理通道（复用 thz-ops 通道思路）。
3. 最简（测试期）：`18081` 公网放行 + 强随机管理密码 + 测试结束后关闭。token 是一次性的，匿名限流 30/15min，暴露面有限。

## 6. 断言清单（每次回归）

- [ ] select-route 返回 `route: "D"`、`installable: true`
- [ ] download-mac 返回 200，`__INSTALL_TOKEN__` 无残留
- [ ] 假 Key 运行：退出码非零，`~/Library/Logs/THZ-Codex-Setup-*.log` 生成，
      日志中无完整 Key（只有 `sk-****`），`installer_fail_reports` 表多一行（step=5）
- [ ] 无 token 运行：step=1 失败，日志提示重下安装包
- [ ] staging DB 与生产 DB 无交叉（抽查一行 token 不在生产库）

## 7. 诚实缺口

- **无真 Key 的绿路径**：假 Key 只能测到 step 5 失败。如需完整 7 步成功，
  需一个可用的 DeepSeek 测试 Key，经 GHA Secrets 注入（`DEEPSEEK_TEST_KEY`），
  且该 Key 只能用于 CI（额度风险自负）。v1 先按失败路径回归，绿路径为可选项。
- **国内网络**：runner 在境外，`releases.openai.com`/GitHub 可达；国内用户真实网络
  问题不在 CI 覆盖范围（Windows 版同样策略：分层检测 + 明确报错，不承诺解决）。
