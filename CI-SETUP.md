# Windows 安装程序 CI 设置

## GitHub Secrets

仓库需要以下 GitHub Actions Secrets：

- `STAGING_API_BASE_URL`：已有的 staging API 地址。
- `STAGING_DEEPSEEK_KEY`：需要新建。填写一个真实、可用的 DeepSeek Key，仅供 staging 安装回归使用。

仓库管理员进入：

`Settings` → `Secrets and variables` → `Actions` → `New repository secret`

创建 `STAGING_DEEPSEEK_KEY`。Key 的明文只在创建 Secret 时出现一次，不要写入仓库文件、Issue、Actions 日志或构建产物。

## 手动触发回归

进入仓库的 `Actions` 页面，选择 `Installer Regression`，点击 `Run workflow`。

`iterations` 是回归批数，只允许填写 `1` 到 `50` 的整数，默认值为 `20`。工作流最多同时运行 4 批。

## 查看结果

在对应的 workflow run 页面查看各 job 的执行结果和 `$GITHUB_STEP_SUMMARY` 汇总。

每一批安装都会在页面底部的 `Artifacts` 区域生成一个诊断包：

`install-logs-1`、`install-logs-2`，依此类推。

诊断包包含可用的工作区内容、诊断日志以及安装程序的 stdout/stderr。即使该批执行失败，也会尝试上传已经产生的诊断材料。

## `THZ_CI_TEST=1` 契约

回归工作流运行 EXE 前设置：

```text
THZ_CI_TEST=1
```

该模式为无人值守测试模式，不显示通知、重试、清理选择或完成窗口。成功后选择“暂时保留”，以保留 transcript 和 workspace 供 artifact 上传。

stdout 标记：

```text
THZ_CI_DIAGLOG=<诊断日志绝对路径>
THZ_CI_WORKSPACE=<工作区绝对路径>
THZ_CI_RESULT=PASS
```

失败时 stderr 包含：

```text
THZ_CI_RESULT=FAIL stage=<阶段> code=<错误代码>
```

通知文本改写到 stderr，格式为：

```text
THZ_CI_NOTICE: <通知文本>
```

退出码含义：

- `0`：安装和全部验证断言通过，包括内部执行的 `codex --version`。
- `1`：主流程发生未处理失败。
- `2`：安装后验证或检测阶段失败。

## `-TestHook`

CI 编译命令使用：

```powershell
.\exe-src\build.ps1 -BaseUrl 'http://64.83.26.242:18081' -TestHook -OutDir (Join-Path $PWD 'dist')
```

`-TestHook` 只修改构建 stage 中的副本，用于注入 CI 测试所需行为；仓库源码不包含该钩子产生的修改。
