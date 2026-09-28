# Mac 安装器后端变更说明（BACKEND-PATCH）

> 状态：文档，未应用。生产禁止直接改，先在 staging 验证。
> 本说明基于 2026-09-29 对生产代码的**只读**核查编写，定位精确到行号。
> 前提：P0 的 4 个后端补丁（`~/workspace/thz-ops/codex-fix/backend-patch/*.patch`，即 `/api/installer/fail` 等）需先应用，否则 Mac 安装器的失败上报无处可去。

## 变更总览（5 处代码 + 1 个模板文件 + 1 个环境变量）

| # | 文件 | 改动 | 不改会怎样 |
|---|---|---|---|
| 1 | `app/license_service.py:83` | `os_type` 放行 `macos` | **P0 阻塞**：Mac 安装器调 `/api/installer/start` 直接 400 `OS_TYPE_INVALID` |
| 2 | `app/router.py` | `resolve_route` 加 `macos_available` 参数；macOS 分支实现 Route D | macOS 永远 `installable: False`，拿不到 install_token |
| 3 | `app/install_service.py` | `select_route` 透传开关；新增 `build_installer_mac()` | 同上；且无 Mac 安装包下载函数 |
| 4 | `app/main.py` | 新增 `POST /api/installer/download-mac` 端点 | 无下载入口 |
| 5 | `installer/Install-Codex-Mac.sh.template` | 新增模板文件（内容 = 本仓库 `mac-installer/install-macos.sh`） | 下载 500 `template_missing` |
| 6 | 环境变量 | staging（及以后生产）设置 `MACOS_AVAILABLE=1` | 开关关闭时一切保持现状 |

`/api/installer/complete`、`/api/installer/fail`、匿名限流：**复用，不改**。
`/fail` 的 `InstallFailRequest` 没有 `os_type` 字段——刻意不加，平台通过
`installer_version="mac-1.0.0"` 前缀区分，避免改表结构。

> 2026-09-29 补充（`/complete` 指纹核对结论）：后端 `install_service.complete()`
> 要求 `device_fingerprint` 与 `/start` 时一致，否则 409 `token_device_mismatch`
>（`InstallTokenRequest.device_fingerprint` 64 位 hex，可选字段）。
> Windows 安装器已带指纹调 `/complete`，Mac 脚本同样在 `api_start` 保存指纹、
> `api_complete` 随 body 发送——**后端无需改动**，脚本侧已对齐。

## 命名说明（重要）

用户已批准：D = Mac DeepSeek+CLI，E = Mac 官方 Desktop 引导。

注意既有冲突：`router.py` 的 `_ROUTE_META` 里 **D 已被占用**
（Windows 下 ChatGPT 账号 + OpenAI 被墙 = 仅指引、不可安装）。
本方案采用**平台限域命名**：路由字母的含义由 `(platform, route)` 二元组决定，
`install_tokens` 表本来就同时存 `platform` 和 `route`，无歧义。
macOS 分支**不查 `_ROUTE_META["D"]`**，直接内联构造 macOS 语义的返回，
避免把 Windows 的 D 文案带到 Mac 用户面前。

Route E（Mac Desktop 引导）：v1 不实现。macOS + chatgpt 模式在 v1
返回 `installable: False` + "即将上线"提示（见改动 2），字母 E 预留。

## 改动 1：license_service.py（P0 阻塞）

```python
# 原（第 83-84 行）：
if (os_type or "").strip().lower() != "windows":
    raise LicenseError("OS_TYPE_INVALID", "当前授权安装器仅支持 Windows。")

# 改为：
if (os_type or "").strip().lower() not in ("windows", "macos"):
    raise LicenseError("OS_TYPE_INVALID", "当前授权安装器仅支持 Windows / macOS。")
```

## 改动 2：router.py

```python
# resolve_route 签名加参数：
def resolve_route(platform: str, network: str, mode: str, macos_available: bool = False) -> dict:

# macOS 分支（替换现有整个 `if platform == "macos":` 块）：
    if platform == "macos":
        if macos_available and mode == "deepseek":
            # Route D：Mac DeepSeek + Codex CLI（bash 安装器），v1 唯一可安装路线
            return {
                "route": "D",
                "installable": True,
                "platform": platform,
                "network": network,
                "mode": mode,
                "deepseek": True,
                "desktop_only": False,
                "warnings": [],
                "recommendation": None,
            }
        if macos_available and mode == "chatgpt":
            # Route E 预留：v1 暂不可安装，提示即将上线
            return {
                "route": None,
                "installable": False,
                "platform": platform,
                "network": network,
                "mode": mode,
                "deepseek": False,
                "desktop_only": True,
                "warnings": ["Mac 版 ChatGPT 会员模式（官方 Desktop App 引导）即将上线，当前仅支持 DeepSeek 模式。"],
                "recommendation": None,
            }
        # 开关关闭：保持现状
        route_key = _route_for(platform, network, mode)
        return {
            "route": route_key,
            "installable": False,
            ...（原样保留）...
            "warnings": ["macOS 版本正在准备，当前仅支持 Windows。"],
            "recommendation": None,
        }
```

另建议把文件头 docstring 的 Route matrix 补一行：
`Route D (macOS): DeepSeek API Key -> bash installer (platform-scoped, distinct from Windows D)`。

## 改动 3：install_service.py

a) `select_route` 内调用处加透传（约第 160 行）：

```python
# 原：
decision = resolve_route(platform, network, mode)
# 改为：
decision = resolve_route(platform, network, mode, macos_available=self._settings.macos_available)
```

（`settings.macos_available` 已存在，`config.py:93`，读 `MACOS_AVAILABLE` 环境变量。）

b) 新增 `build_installer_mac`（放在 `build_installer_zip` 旁边）：

```python
INSTALLER_MAC_SH = Path(__file__).resolve().parent.parent / "installer" / "Install-Codex-Mac.sh.template"

def build_installer_mac(self, install_token: str) -> bytes:
    row = self._require_token(install_token, allowed_statuses=("issued",))
    if row["platform"] != "macos" or row["route"] != "D" or (row["client_type"], row["provider_type"]) != ("cli", "deepseek"):
        raise InstallError("install_plan_invalid", "该安装方案不可下载。", 409)
    token_row = self._db.get_install_token(install_token)
    try:
        # 注意：shell 脚本不能带 BOM（会破坏 #! 行），用 utf-8 读取并剥掉可能存在的 BOM
        sh = INSTALLER_MAC_SH.read_text(encoding="utf-8-sig")
    except OSError as exc:
        raise InstallError("template_missing", "安装器模板缺失。", 500) from exc
    if sh.startswith("\ufeff"):
        sh = sh.lstrip("\ufeff")
    sh = sh.replace("__BASE_URL__", self._settings.public_base_url).replace("__INSTALL_TOKEN__", token_row["token"])
    return sh.encode("utf-8")
```

## 改动 4：main.py

在 `download_exe` 端点后新增：

```python
@app.post("/api/installer/download-mac", include_in_schema=False)
def download_mac(req: InstallTokenRequest):
    try:
        data = installs.build_installer_mac(req.install_token)
    except InstallError as exc:
        return JSONResponse(
            {"ok": False, "error": exc.code, "message": exc.message},
            status_code=exc.status,
        )
    return Response(
        content=data,
        media_type="text/x-shellscript",
        headers={
            "Content-Disposition": 'attachment; filename="THZ-Codex-Setup.command"',
            "Cache-Control": "no-store, private",
            "X-Content-Type-Options": "nosniff",
        },
    )
```

## 改动 5：模板文件

把本仓库 `mac-installer/install-macos.sh` 原样复制为
`/opt/codex-installer/installer/Install-Codex-Mac.sh.template`
（占位符 `__BASE_URL__` / `__INSTALL_TOKEN__` 保持原样，由服务端替换）。

## 验证清单（staging 上）

1. `MACOS_AVAILABLE=0` 时：`POST /api/installer/select-route`（platform=macos）→ `installable: False`，行为与今天一致。
2. `MACOS_AVAILABLE=1` 时：同样请求（mode=deepseek）→ `route: "D"`，`installable: True`，`download_url: "/api/installer/download"`…注意：v1 的 mac 下载走新端点 `/api/installer/download-mac`（网站前端需据此拼接，或后端在 select-route 返回里对 macOS 改写 download_url——建议后者，见下）。
3. `POST /api/installer/download-mac` → 200，内容含已替换的 token，无 `__INSTALL_TOKEN__` 残留，首行 `#!/bin/bash` 无 BOM。
4. `POST /api/installer/start`（os_type=macos）→ 不再 400，通过。
5. 全流程：select-route → download-mac → start →（假 Key）fail → 查 `installer_fail_reports` 落库。

> 建议（可选）：`select_route` 返回的 `download_url` 对 macOS 改写为
> `/api/installer/download-mac`，网站前端无需分支判断。改动位置：
> `install_service.py` select_route 末尾 return 处，按 `platform == "macos"`
> 选择 URL。
