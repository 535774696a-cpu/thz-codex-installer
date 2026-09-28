# 构建说明

- `build.py`：遗产脚本。依赖已丢失的 Mono 工具链（`/tmp/thz-v44-build/toolchain`），
  仅保留作参考，不要再用它构建。
- `build.ps1`：当前构建脚本，跑在 GitHub Actions `windows-latest` 上，
  用系统自带的 .NET Framework `csc.exe` 编译。用法：`./build.ps1 [-BaseUrl <url>] [-OutDir <dir>]`
- `Resources.cs` 由 `build.ps1` 在构建时按两份 ps1 的 SHA256 自动重新生成，
  仓库里的是种子值。
