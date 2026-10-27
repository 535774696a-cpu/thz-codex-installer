# 4.6.5.0 LICENSE_START 可诊断性修复（部分交付，禁止视为已部署）

分支：`fix/license-start-diagnostics-465`。客户端构建提交：`810864f`。

## 文件差异

- `exe-src/Runner.ps1`：版本及日志版本改为 4.6.5.0；从 start 的非 OK JSON 和 HTTP 错误响应收集 error/message；解开 PowerShell 的 MethodInvocationException 找到 WebException，在读完响应后才 Abort；detail 写入 server_error 和脱敏 message；删除完整 URL、ticket、长 token、Key 和控制字符；单独写入已脱敏提示文件，供启动器读取；诊断码白名单补齐六类 start 错误。
- `exe-src/InstallerLibrary.ps1`：ScriptVersion 改为 4.6.5.0；Invoke-ApiStart 失败时保留已脱敏的服务端提示。
- `exe-src/Bootstrap.cs`：AssemblyVersion 和日志版本改为 4.6.5.0；仅 LICENSE_START_FAILED 优先显示子进程的提示文件；文件缺失或不可读时保留通用提示；使用 Safety.NoLinks 并限制文件大小。新增代码符合 C# 5。
- `.github/workflows/build.yml`：沿用已有构建，增加隔离回归及编译后 EXE 提示文案检查。
- `tests/license-start-diagnostics.ps1`：六类错误码、中文提示、脱敏、成功 start 响应、编译后 Failure 文案及缺文件回退测试。没有运行安装主流程或访问生产端点。
- `backend-patches/20261027-installer-fail-message.py.patch`：候选后端补丁，message 去 CR/LF 并替换请求 token 后追加 journal 日志，日志 token 固定为 <redacted>。**未应用到 app/main.py，未验证锚定上下文。**

所有改动的 ps1 均为 UTF-8 WITH BOM；exe-src 内无残留 4.6.4.0。

## 构建与证据

测试包 run：https://github.com/535774696a-cpu/thz-codex-installer/actions/runs/40444185899 ，结果 SUCCESS。

通过：Windows PowerShell 5.1 syntax、PSScriptAnalyzer、隔离回归、.NET Framework C# 5 编译、编译后对话框文案回归、ticket stamping smoke test、artifact 上传。

GHA 日志原文：

- `PASS: six server errors, Chinese message, redaction, successful start response (isolated tests; no staging claims).`
- `PASS: built EXE dialog text preserves server message and falls back when absent.`

已下载 windows-build 至 `/tmp/thz-465-artifacts`，测试 EXE SHA256 与 SHA256SUMS 一致：
`94cf62ff0d32ee3e79246cd94c79709168ded161587931193b62d1e2731e6344`

此 run 为 workflow_dispatch mode=test，使用 staging 地址及 TestHook。push 自动构建 production 模式仅生成 artifact，不部署。

## 阻塞与未完成项

当前仓库 git ls-files 没有 app/main.py，仅有 backend-patches；本机 /opt/codex-installer 不存在，因此不能确认此仓库是后端生产代码来源，不能凭空复制或编写整个 main.py。

通过既有 thz-ops HTTP 运维通道的只读查询返回空响应；第二种 SSH 只读连接被重置。两次访问失败后停止继续尝试。

所以未完成：实际后端源码修改及 journal 检查；staging 真链路 start→fail 及完整正常安装；生产模板哈希只读复核。CI 的隔离成功响应检查不等于完整正常安装通过，编译后文案检查不等于实际桌面对话框截图。

生产模板预期哈希为 `e5867238e3178c2d8371b49cd0b3d44054720bbdce222f41b398fe2c623dbff7`，本次**没有取得远端实测值**。

未修改生产文件、环境变量/TTL，未重启生产服务，未替换模板，未推 main。后续需恢复服务端只读及 staging 访问入口，并确认后端源码仓库后完成余下验证。
