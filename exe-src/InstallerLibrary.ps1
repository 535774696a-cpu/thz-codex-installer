#requires -Version 5.1
<#
  Install-Codex-AI.ps1
  Codex + DeepSeek 一键安装器（双模式：deepseek | chatgpt）

  本文件是服务端个性化模板：
    __BASE_URL__       由服务端在生成 ZIP 时替换为部署地址
    __INSTALL_TOKEN__  由服务端替换为一次性安装令牌（install_token）

  运行流程：
    [1/7] 验证安装授权...   POST /api/installer/start（携带 install_token）
    [2/7] 检测 Windows 环境...
    [3/7] 按模式分叉：
      deepseek: 预检（安全清理 stale tmp，独立于是否重装）-> 安装/复用 Codex CLI（仅官方源）
      chatgpt : Route C 官方 Desktop App 流程（不安装 CLI、不登录、不写配置）
    然后按模式分叉：
      deepseek: [4/7] 备份配置  [5/7] 配置 AI 模型（本机输入自己的 Key）
               [6/7] 验证 Codex  [7/7] 完成
      chatgpt : [4/7] 检查 Desktop [5/7] 获取官方 Desktop App（仅配置的官方 URL）
               [6/7] 提醒官方登录 [7/7] 完成
    成功后 POST /api/installer/complete 标记 install_token consumed。

  Route C（ChatGPT / Codex 会员）最终产品规则：
    - 只负责：检查 Windows、检查 OpenAI 网络可达性、给出官方 Desktop App 下载动作、
      提醒用户自行完成 OpenAI 官方账号登录。
    - 不再：安装 Codex CLI、执行 CLI 登录、要求 DeepSeek Key、
      修改 ~/.codex/config.toml、注入 DeepSeek Provider、调用 DeepSeek API。
    - OpenAI 不可访问时停止安装并明确提示"使用 ChatGPT/Codex 会员方式需要当前网络
      可以正常访问 OpenAI。"；仅当服务器配置了 network_solution_url 才显示"查看网络
      访问解决方案"，未配置不显示死链接。
    - 不采集 OpenAI 密码 / Cookie / Session / 登录 Token；不自动安装 VPN、
      不修改系统代理 / DNS / 证书、不绕过地区限制。
    - Desktop App 只使用服务器配置的官方下载 URL（desktop_download_url）；
      不猜测、不镜像、不自建下载源。

  安全约束：
    - 原始授权码绝不写入安装器；仅携带一次性 install_token。
    - 模式由服务器决定（deepseek/chatgpt），不依赖本文件或 CMD 里的任何开关。
    - chatgpt 模式绝不获取/写入 DeepSeek Key，不触碰用户密码/Cookie/auth 上传。
    - 全程不修改系统代理、防火墙、Winsock、注册表，不删除 .codex 或用户数据。
#>
[CmdletBinding()]
param(
    [string]$InstallToken = ""
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ScriptVersion = '4.6.0.0'

# ---- V1 官方 standalone 安装（OpenAI 官方 install.ps1）----
# V1 主安装路线：官方 Windows standalone（无需 Node/npm）。
# 官方安装器负责：检测平台 / 下载 / SHA256 校验 / 解压 / 建立 standalone / PATH。
# 我们的 Installer 只负责调用它 + 用 codex --version 做最终验证。
$OfficialInstallerUrl = 'https://chatgpt.com/codex/install.ps1'

# ---- 内置代理 (hysteria2) ----

function Get-EmbeddedProxySubscription {
    [CmdletBinding()]
    param()

    try {
        $encodedToken = [Uri]::EscapeDataString([string]$script:InstallToken)
        $subscriptionUri = '{0}/api/installer/proxy-sub?install_token={1}' -f $BASE_URL.TrimEnd('/'), $encodedToken

        Write-Host 'stage=DOWNLOAD operation=EMBEDDED_PROXY subscription_fetch=start'

        $response = Invoke-WebRequest `
            -Uri $subscriptionUri `
            -UseBasicParsing `
            -TimeoutSec 30 `
            -ErrorAction Stop

        if ([string]::IsNullOrWhiteSpace([string]$response.Content)) {
            throw '服务端返回了空的代理订阅。'
        }

        Write-Host 'stage=DOWNLOAD operation=EMBEDDED_PROXY subscription_fetch=success'
        return [string]$response.Content
    }
    catch {
        throw ('获取内置代理订阅失败：{0}' -f $_.Exception.Message)
    }
}

function ConvertFrom-Hysteria2Uri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    try {
        $trimmedUri = $Uri.Trim()

        if (-not $trimmedUri.StartsWith('hysteria2://', [StringComparison]::OrdinalIgnoreCase)) {
            throw '节点地址不是有效的 hysteria2 URI。'
        }

        $parsedUri = New-Object System.Uri($trimmedUri)

        if ($parsedUri.Scheme -ne 'hysteria2') {
            throw '节点协议不是 hysteria2。'
        }

        if ([string]::IsNullOrWhiteSpace($parsedUri.Host)) {
            throw '节点地址缺少服务器主机名。'
        }

        if ($parsedUri.Port -le 0 -or $parsedUri.Port -gt 65535) {
            throw '节点地址中的端口无效。'
        }

        $password = [Uri]::UnescapeDataString([string]$parsedUri.UserInfo)
        $server = [Uri]::UnescapeDataString([string]$parsedUri.Host)
        $name = [Uri]::UnescapeDataString([string]$parsedUri.Fragment.TrimStart('#'))

        $queryValues = @{}
        $query = [string]$parsedUri.Query

        if (-not [string]::IsNullOrWhiteSpace($query)) {
            foreach ($item in $query.TrimStart('?').Split('&')) {
                if ([string]::IsNullOrWhiteSpace($item)) {
                    continue
                }

                $parts = $item.Split('=', 2)
                $key = [Uri]::UnescapeDataString($parts[0]).ToLowerInvariant()
                $value = ''

                if ($parts.Count -gt 1) {
                    $value = [Uri]::UnescapeDataString($parts[1])
                }

                $queryValues[$key] = $value
            }
        }

        $sni = $server
        if ($queryValues.ContainsKey('sni') -and
            -not [string]::IsNullOrWhiteSpace([string]$queryValues['sni'])) {
            $sni = [string]$queryValues['sni']
        }

        $insecure = $false
        if ($queryValues.ContainsKey('insecure')) {
            $insecureValue = ([string]$queryValues['insecure']).Trim().ToLowerInvariant()
            $insecure = (
                $insecureValue -eq '1' -or
                $insecureValue -eq 'true' -or
                $insecureValue -eq 'yes'
            )
        }

        $obfsType = ''
        if ($queryValues.ContainsKey('obfs')) {
            $obfsType = [string]$queryValues['obfs']
        }

        $obfsPassword = ''
        if ($queryValues.ContainsKey('obfs-password')) {
            $obfsPassword = [string]$queryValues['obfs-password']
        }

        $mportRange = ''
        if ($queryValues.ContainsKey('mport')) {
            $mportRange = [string]$queryValues['mport']
        }

        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = '{0}:{1}' -f $server, $parsedUri.Port
        }

        return [PSCustomObject]@{
            Server       = $server
            ServerPort   = [int]$parsedUri.Port
            Password     = $password
            Sni          = $sni
            Insecure     = [bool]$insecure
            ObfsType     = $obfsType
            ObfsPassword = $obfsPassword
            MportRange   = $mportRange
            Name         = $name
        }
    }
    catch {
        throw ('解析 hysteria2 节点失败：{0}' -f $_.Exception.Message)
    }
}

function Test-ProxyNodeLatency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Alias('Host')]
        [string]$TargetHost,

        [Parameter(Mandatory = $true)]
        [int]$Port,

        [int]$TimeoutMs = 3000
    )

    $tcpClient = $null

    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $asyncResult = $tcpClient.BeginConnect($TargetHost, $Port, $null, $null)

        if (-not $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return $null
        }

        $tcpClient.EndConnect($asyncResult)
        $stopwatch.Stop()

        if (-not $tcpClient.Connected) {
            return $null
        }

        return [int][Math]::Max(1, $stopwatch.ElapsedMilliseconds)
    }
    catch {
        return $null
    }
    finally {
        if ($null -ne $tcpClient) {
            $tcpClient.Close()
            $tcpClient.Dispose()
        }
    }
}

function Start-EmbeddedProxy {
    [CmdletBinding()]
    param()

    if ($null -ne $script:EmbeddedProxyProcess) {
        try {
            if (-not $script:EmbeddedProxyProcess.HasExited -and
                -not [string]::IsNullOrWhiteSpace([string]$script:EmbeddedProxyUrl)) {
                Write-Host 'stage=DOWNLOAD operation=EMBEDDED_PROXY proxy_status=already_running'
                return $script:EmbeddedProxyUrl
            }
        }
        catch {
            $script:EmbeddedProxyProcess = $null
            $script:EmbeddedProxyUrl = $null
        }
    }

    $proxyDirectory = Join-Path $env:TEMP 'THZ-hysteria'
    $hysteriaPath = Join-Path $proxyDirectory 'hysteria.exe'
    $configPath = Join-Path $proxyDirectory 'config.yaml'
    $stdoutLogPath = Join-Path $proxyDirectory 'hysteria.stdout.log'
    $stderrLogPath = Join-Path $proxyDirectory 'hysteria.stderr.log'
    $minimumCachedSize = 1MB

    try {
        if (-not (Test-Path -LiteralPath $proxyDirectory)) {
            New-Item -ItemType Directory -Path $proxyDirectory -Force -ErrorAction Stop | Out-Null
        }

        $downloadHysteria = $true
        if (Test-Path -LiteralPath $hysteriaPath -PathType Leaf) {
            $existingFile = Get-Item -LiteralPath $hysteriaPath -ErrorAction Stop
            if ($existingFile.Length -gt $minimumCachedSize) {
                $downloadHysteria = $false
                Write-Host 'stage=DOWNLOAD operation=EMBEDDED_PROXY binary_cache=hit'
            }
        }

        if ($downloadHysteria) {
            $hysteriaUri = '{0}/static/hysteria.exe' -f $BASE_URL.TrimEnd('/')
            $temporaryBinaryPath = Join-Path $proxyDirectory 'hysteria.exe.download'

            Write-Host 'stage=DOWNLOAD operation=EMBEDDED_PROXY binary_download=start'

            Invoke-WebRequest `
                -Uri $hysteriaUri `
                -OutFile $temporaryBinaryPath `
                -UseBasicParsing `
                -TimeoutSec 120 `
                -ErrorAction Stop

            $downloadedFile = Get-Item -LiteralPath $temporaryBinaryPath -ErrorAction Stop
            if ($downloadedFile.Length -le $minimumCachedSize) {
                Remove-Item -LiteralPath $temporaryBinaryPath -Force -ErrorAction SilentlyContinue
                throw '下载的 hysteria 程序文件不完整。'
            }

            Move-Item `
                -LiteralPath $temporaryBinaryPath `
                -Destination $hysteriaPath `
                -Force `
                -ErrorAction Stop

            Write-Host 'stage=DOWNLOAD operation=EMBEDDED_PROXY binary_download=success'
        }

        $subscription = Get-EmbeddedProxySubscription

        try {
            $base64Text = ($subscription -replace '\s', '')
            $subscriptionBytes = [Convert]::FromBase64String($base64Text)
            $decodedSubscription = [Text.Encoding]::UTF8.GetString($subscriptionBytes)
        }
        catch {
            throw ('代理订阅的 Base64 内容无效：{0}' -f $_.Exception.Message)
        }

        $nodes = New-Object System.Collections.Generic.List[object]

        foreach ($line in ($decodedSubscription -split '\r?\n')) {
            $nodeUri = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($nodeUri)) {
                continue
            }

            if (-not $nodeUri.StartsWith('hysteria2://', [StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            try {
                $nodes.Add((ConvertFrom-Hysteria2Uri -Uri $nodeUri))
            }
            catch {
                Write-Host 'stage=DOWNLOAD operation=EMBEDDED_PROXY node_parse=failed'
            }
        }

        if ($nodes.Count -eq 0) {
            throw '代理订阅中没有可用的 hysteria2 节点。'
        }

        $candidateIndices = 0..($nodes.Count - 1) | Sort-Object { Get-Random }
        $candidateIndices = @($candidateIndices | Select-Object -First ([Math]::Min(5, $candidateIndices.Count)))
        Write-Host ('stage=DOWNLOAD operation=EMBEDDED_PROXY candidate_order=shuffled try_count={0} total_nodes={1}' -f $candidateIndices.Count, $nodes.Count)

        foreach ($candidateIdx in $candidateIndices) {
            $selectedNode = $nodes[$candidateIdx]
            Write-Host ('stage=DOWNLOAD operation=EMBEDDED_PROXY candidate_attempt node={0}' -f (($selectedNode.Name -replace '\s+','_') -replace '=','_'))

            $process = $null
            $socksPort = $null
            for ($attempt = 0; $attempt -lt 100; $attempt++) {
                $candidatePort = Get-Random -Minimum 18000 -Maximum 19000
                $listener = $null

                try {
                    $listener = New-Object System.Net.Sockets.TcpListener(
                        [Net.IPAddress]::Loopback,
                        $candidatePort
                    )
                    $listener.Start()
                    $socksPort = $candidatePort
                    break
                }
                catch {
                }
                finally {
                    if ($null -ne $listener) {
                        try {
                            $listener.Stop()
                        }
                        catch {
                        }
                    }
                }
            }

            if ($null -eq $socksPort) {
                $script:EmbeddedProxyProcess = $null
                $script:EmbeddedProxyUrl = $null
                Write-Host 'stage=DOWNLOAD operation=EMBEDDED_PROXY candidate_result=failed'
                continue
            }

            $httpPort = $null
            for ($attempt = 0; $attempt -lt 100; $attempt++) {
                $candidatePort = Get-Random -Minimum 19000 -Maximum 19100
                $listener = $null

                try {
                    $listener = New-Object System.Net.Sockets.TcpListener(
                        [Net.IPAddress]::Loopback,
                        $candidatePort
                    )
                    $listener.Start()
                    $httpPort = $candidatePort
                    break
                }
                catch {
                }
                finally {
                    if ($null -ne $listener) {
                        try {
                            $listener.Stop()
                        }
                        catch {
                        }
                    }
                }
            }

            if ($null -eq $httpPort) {
                $script:EmbeddedProxyProcess = $null
                $script:EmbeddedProxyUrl = $null
                Write-Host 'stage=DOWNLOAD operation=EMBEDDED_PROXY candidate_result=failed'
                continue
            }

            # hysteria2 客户端使用 YAML 配置
            # 参考: https://v2.hysteria.network/docs/advanced/Client-Configuration/
            $yamlLines = New-Object System.Collections.Generic.List[string]

            # server: "host:port" 或 "host:mport-range"（端口跳跃）
            $serverPortPart = $selectedNode.ServerPort
            if (-not [string]::IsNullOrWhiteSpace([string]$selectedNode.MportRange)) {
                $serverPortPart = ([string]$selectedNode.MportRange).Trim()
            }
            $yamlLines.Add(('server: "{0}:{1}"' -f $selectedNode.Server, $serverPortPart))
            # auth: password
            $yamlLines.Add(('auth: "{0}"' -f $selectedNode.Password.Replace('"', '\"')))
            # tls
            $yamlLines.Add('tls:')
            $yamlLines.Add(('  sni: "{0}"' -f $selectedNode.Sni.Replace('"', '\"')))
            $yamlLines.Add(('  insecure: {0}' -f $selectedNode.Insecure.ToString().ToLower()))
            # socks5 inbound
            $yamlLines.Add('socks5:')
            $yamlLines.Add(('  listen: "127.0.0.1:{0}"' -f $socksPort))
            # http inbound
            $yamlLines.Add('http:')
            $yamlLines.Add(('  listen: "127.0.0.1:{0}"' -f $httpPort))
            # obfs (salamander) - 密码必须在 salamander 子节下
            if ($selectedNode.ObfsType -eq 'salamander') {
                $yamlLines.Add('obfs:')
                $yamlLines.Add('  type: "salamander"')
                $yamlLines.Add('  salamander:')
                $yamlLines.Add(('    password: "{0}"' -f $selectedNode.ObfsPassword.Replace('"', '\"')))
            }

            [IO.File]::WriteAllText(
                $configPath,
                (($yamlLines -join "`n") + "`n"),
                (New-Object Text.UTF8Encoding($false))
            )

            Write-Host ('stage=DOWNLOAD operation=EMBEDDED_PROXY proxy_start=begin listen_port={0}' -f $httpPort)

            $process = Start-Process `
                -FilePath $hysteriaPath `
                -ArgumentList @('client', '-c', $configPath) `
                -WorkingDirectory $proxyDirectory `
                -NoNewWindow `
                -RedirectStandardOutput $stdoutLogPath `
                -RedirectStandardError $stderrLogPath `
                -PassThru `
                -ErrorAction Stop

            $script:EmbeddedProxyProcess = $process
            $proxyReady = $false
            $deadline = [DateTime]::UtcNow.AddSeconds(15)

            while ([DateTime]::UtcNow -lt $deadline) {
                $process.Refresh()

                if ($process.HasExited) {
                    break
                }

                $probe = Test-ProxyNodeLatency `
                    -TargetHost '127.0.0.1' `
                    -Port $httpPort `
                    -TimeoutMs 500

                if ($null -ne $probe) {
                    $proxyReady = $true
                    break
                }

                Start-Sleep -Milliseconds 500
            }

            if (-not $proxyReady) {
                try {
                    if (-not $process.HasExited) {
                        $process.Kill()
                    }
                }
                catch {
                }

                $script:EmbeddedProxyProcess = $null
                $script:EmbeddedProxyUrl = $null
                Write-Host 'stage=DOWNLOAD operation=EMBEDDED_PROXY candidate_result=failed'
                continue
            }

            $e2eOk = $false
            try {
                $e2eResp = Invoke-WebRequest -Uri 'https://www.google.com/generate_204' -Method Get -Proxy ('http://127.0.0.1:{0}' -f $httpPort) -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
                $e2eCode = [int]$e2eResp.StatusCode
                if ($e2eCode -eq 200 -or $e2eCode -eq 204) {
                    $e2eOk = $true
                }
            }
            catch {
                $e2eOk = $false
            }

            Write-Host ('stage=DOWNLOAD operation=EMBEDDED_PROXY candidate_e2e={0}' -f $(if ($e2eOk) { 'success' } else { 'failed' }))

            if (-not $e2eOk) {
                try {
                    if (-not $process.HasExited) {
                        $process.Kill()
                    }
                }
                catch {
                }

                $script:EmbeddedProxyProcess = $null
                $script:EmbeddedProxyUrl = $null
                Write-Host 'stage=DOWNLOAD operation=EMBEDDED_PROXY candidate_result=failed'
                continue
            }

            $script:EmbeddedProxyUrl = 'http://127.0.0.1:{0}' -f $httpPort
            $script:EmbeddedProxyProcess = $process

            Write-Host (
                'stage=DOWNLOAD operation=EMBEDDED_PROXY proxy_start=success proxy_url={0}' -f
                $script:EmbeddedProxyUrl
            )

            return $script:EmbeddedProxyUrl
        }

        throw '所有内置代理节点均无法连接，请检查网络后重试。'
    }
    catch {
        if ($null -ne $script:EmbeddedProxyProcess) {
            try {
                if (-not $script:EmbeddedProxyProcess.HasExited) {
                    $script:EmbeddedProxyProcess.Kill()
                }
            }
            catch {
            }
        }

        $script:EmbeddedProxyProcess = $null
        $script:EmbeddedProxyUrl = $null
        throw ('启动内置代理失败：{0}' -f $_.Exception.Message)
    }
}

function Test-DirectConnection {
    <#
    .SYNOPSIS
        测试是否能直连境外，用于按需下载判断。
    .DESCRIPTION
        对目标 URL 发送轻量 HEAD 请求，10 秒超时。
        成功返回 $true，失败返回 $false。全程 try/catch，不抛异常。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [int]$TimeoutSec = 10
    )

    try {
        $request = [Net.HttpWebRequest]::Create($Uri)
        $request.Method = 'HEAD'
        $request.Proxy = $null
        $request.Timeout = $TimeoutSec * 1000

        $response = $null
        try {
            $response = [Net.HttpWebResponse]$request.GetResponse()
            return $true
        }
        finally {
            if ($null -ne $response) { $response.Dispose() }
        }
    }
    catch {
        return $false
    }
}

function Remove-EmbeddedProxy {
    <#
    .SYNOPSIS
        彻底清理内置代理：停止进程 + 删除文件目录。
    .DESCRIPTION
        安装完成后调用，确保零残留。全程 try/catch，不抛异常。
    #>
    [CmdletBinding()]
    param()

    try {
        # 1. 停止进程
        if ($null -ne $script:EmbeddedProxyProcess) {
            try {
                if (-not $script:EmbeddedProxyProcess.HasExited) {
                    $script:EmbeddedProxyProcess.Kill()
                    $script:EmbeddedProxyProcess.WaitForExit(5000) | Out-Null
                }
            }
            catch {
            }
            finally {
                $script:EmbeddedProxyProcess = $null
                $script:EmbeddedProxyUrl = $null
            }
        }

        # 2. 删除代理目录
        $proxyDirectory = Join-Path $env:TEMP 'THZ-hysteria'
        if (Test-Path -LiteralPath $proxyDirectory) {
            Remove-Item -LiteralPath $proxyDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }

        Write-Host 'stage=CLEANUP operation=EMBEDDED_PROXY cleanup=done'
    }
    catch {
        # 清理失败不影响主流程
        Write-Host 'stage=CLEANUP operation=EMBEDDED_PROXY cleanup=failed'
    }
}

function Stop-EmbeddedProxy {
    [CmdletBinding()]
    param()

    if ($null -ne $script:EmbeddedProxyProcess) {
        try {
            if (-not $script:EmbeddedProxyProcess.HasExited) {
                $script:EmbeddedProxyProcess.Kill()
                $script:EmbeddedProxyProcess.WaitForExit(5000) | Out-Null
            }
        }
        catch {
            throw ('停止内置代理失败：{0}' -f $_.Exception.Message)
        }
        finally {
            $script:EmbeddedProxyProcess = $null
            $script:EmbeddedProxyUrl = $null
        }
    }

    Write-Host 'stage=DOWNLOAD operation=EMBEDDED_PROXY proxy_stopped=true'
}

function Invoke-ForeignWebRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [int]$TimeoutSec = 30
    )

    # P0 按需下载：先测试直连，直连可用则不下载代理
    if (Test-DirectConnection -Uri $Uri -TimeoutSec 10) {
        Write-Host 'stage=DOWNLOAD operation=FOREIGN_WEB_REQUEST download_via=direct_probed'

        return Invoke-WebRequest `
            -Uri $Uri `
            -UseBasicParsing `
            -TimeoutSec $TimeoutSec `
            -ErrorAction Stop
    }

    Write-Host 'stage=DOWNLOAD operation=FOREIGN_WEB_REQUEST direct_probed=failed'

    try {
        Write-Host 'stage=DOWNLOAD operation=FOREIGN_WEB_REQUEST download_via=direct'

        return Invoke-WebRequest `
            -Uri $Uri `
            -UseBasicParsing `
            -TimeoutSec $TimeoutSec `
            -ErrorAction Stop
    }
    catch {
        $directError = $_.Exception.Message
        Write-Host 'stage=DOWNLOAD operation=FOREIGN_WEB_REQUEST download_via=direct result=failed'
    }

    try {
        $embeddedProxyUrl = Start-EmbeddedProxy

        Write-Host 'stage=DOWNLOAD operation=FOREIGN_WEB_REQUEST download_via=embedded_proxy'

        return Invoke-WebRequest `
            -Uri $Uri `
            -Proxy $embeddedProxyUrl `
            -UseBasicParsing `
            -TimeoutSec $TimeoutSec `
            -ErrorAction Stop
    }
    catch {
        $embeddedProxyError = $_.Exception.Message
        Write-Host 'stage=DOWNLOAD operation=FOREIGN_WEB_REQUEST download_via=embedded_proxy result=failed'
    }

    try {
        $baseServerUri = New-Object System.Uri($BASE_URL)
        $legacyProxyUrl = 'http://{0}:18888' -f $baseServerUri.Host

        Write-Host 'stage=DOWNLOAD operation=FOREIGN_WEB_REQUEST download_via=legacy_proxy'

        return Invoke-WebRequest `
            -Uri $Uri `
            -Proxy $legacyProxyUrl `
            -UseBasicParsing `
            -TimeoutSec $TimeoutSec `
            -ErrorAction Stop
    }
    catch {
        $legacyProxyError = $_.Exception.Message

        Write-Host 'stage=DOWNLOAD operation=FOREIGN_WEB_REQUEST download_via=proxy_failed'

        throw (
            '境外资源下载失败。直连错误：{0}；内置代理错误：{1}；备用代理错误：{2}' -f
            $directError,
            $embeddedProxyError,
            $legacyProxyError
        )
    }
}
$StandaloneBinDir     = Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin'
$StandaloneExe        = Join-Path $StandaloneBinDir 'codex.exe'

# ---- 服务端替换的占位符 ----
$BASE_URL       = '__THZ_API_BASE_URL__'
$TOKEN_EMB      = '__INSTALL_TOKEN__'

# ---- 全局状态 ----
$script:CodexCliOk = $false
$script:ModelOk = $false
$script:DesktopOk = $false
$script:DesktopNote = ''

function Write-Step {
    param([int]$N, [string]$Msg)
    Write-Host "[$N/7] $Msg" -ForegroundColor Cyan
}
function Write-Ok  { param([string]$M) Write-Host "[OK] " -ForegroundColor Green -NoNewline; Write-Host $M }
function Write-Warn{ param([string]$M) Write-Host "[!] "  -ForegroundColor Yellow -NoNewline; Write-Host $M }
function Write-Fail{ param([string]$M) Write-Host "[X] "  -ForegroundColor Red -NoNewline; Write-Host $M }

# =====================================================================
# [1/7] 验证安装授权（install_token）并获取模式配置
# =====================================================================
function Get-DeviceFingerprint {
    # Raw identifiers never leave this process and are never printed. The
    # server receives only this normalized SHA-256 digest.
    $parts = New-Object System.Collections.Generic.List[string]
    try {
        $machineGuid = (Get-ItemProperty -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid
        if (-not [string]::IsNullOrWhiteSpace($machineGuid)) {
            $parts.Add(('machineguid:{0}' -f $machineGuid.Trim().ToLowerInvariant()))
        }
    } catch { }
    try {
        $uuid = (Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop).UUID
        if (-not [string]::IsNullOrWhiteSpace($uuid)) {
            $normalizedUuid = $uuid.Trim().ToLowerInvariant()
            if ($normalizedUuid -notin @('00000000-0000-0000-0000-000000000000', 'ffffffff-ffff-ffff-ffff-ffffffffffff')) {
                $parts.Add(('systemuuid:{0}' -f $normalizedUuid))
            }
        }
    } catch {
        try {
            $uuid = (Get-WmiObject -Class Win32_ComputerSystemProduct -ErrorAction Stop).UUID
            if (-not [string]::IsNullOrWhiteSpace($uuid)) {
                $normalizedUuid = $uuid.Trim().ToLowerInvariant()
                if ($normalizedUuid -notin @('00000000-0000-0000-0000-000000000000', 'ffffffff-ffff-ffff-ffff-ffffffffffff')) {
                    $parts.Add(('systemuuid:{0}' -f $normalizedUuid))
                }
            }
        } catch { }
    }
    if ($parts.Count -eq 0) {
        throw '无法读取稳定的 Windows 设备标识，请联系管理员。'
    }
    $normalized = (($parts | Sort-Object) -join '|')
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
}

function Invoke-ApiStart {
    param([string]$Token = '')

    $useToken = $Token
    if ([string]::IsNullOrWhiteSpace($useToken)) { $useToken = $script:InstallToken }
    if ([string]::IsNullOrWhiteSpace($useToken)) { $useToken = [string]$env:THZ_INSTALL_TICKET }
    if ([string]::IsNullOrWhiteSpace($useToken)) { $useToken = $TOKEN_EMB }
    $script:InstallToken = $useToken

    $useToken = ([string]$useToken).Trim().TrimStart([char]0xFEFF)
    if ([string]::IsNullOrWhiteSpace($useToken) -or $useToken -like '*INSTALL_TOKEN*') {
        throw '缺少安装授权。请回到安装网站重新下载安装包。'
    }
    if ($useToken -notmatch '\A[A-Za-z0-9_-]{64}\z') {
        throw ("安装授权格式无效（长度={0}）。请回到安装网站重新下载安装包。" -f $useToken.Length)
    }
    if ($BASE_URL -like '*BASE_URL*') {
        throw '安装包配置不完整（缺少服务器地址）。请重新下载。'
    }
    $deviceFingerprint = Get-DeviceFingerprint
    if (-not [string]::IsNullOrWhiteSpace($deviceFingerprint) -and $deviceFingerprint -notmatch '\A[0-9a-f]{64}\z') {
        throw '设备指纹无效，请重新下载安装包。'
    }
    $body = @{
        install_token = $useToken;
        device_fingerprint = $deviceFingerprint
        installer_version = $ScriptVersion
        os_type = 'windows'
    } | ConvertTo-Json
    try {
        $resp = Invoke-LicenseRequest -Operation 'LICENSE_START' -Path '/api/installer/start' -Body $body -TimeoutSec 30
        if (-not $resp.ok) { throw ($resp.message) }
        return $resp
    } catch {
        $detail = $null
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            try { $detail = ($_.ErrorDetails.Message | ConvertFrom-Json).message } catch { $detail = $null }
        }
        if (-not [string]::IsNullOrWhiteSpace($detail)) { throw $detail }
        throw ("无法连接安装服务器：{0}" -f $_.Exception.Message)
    }
}

function Invoke-ApiComplete {
    $body = @{ install_token = $script:InstallToken; device_fingerprint = (Get-DeviceFingerprint) } | ConvertTo-Json
    try {
        $null = Invoke-LicenseRequest -Operation 'LICENSE_COMPLETE' -Path '/api/installer/complete' -Body $body -TimeoutSec 20
    } catch {
        # 上报失败不影响本地安装结果
    }
}

# =====================================================================
# [2/7] 检测 Windows 环境 + 网络
# =====================================================================
function Test-WindowsEnvironment {
    if ($env:OS -ne 'Windows_NT') { throw '此安装器仅支持 Windows。' }
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'Codex 需要 64 位 Windows。' }
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    if ($arch -eq 'X64') { Write-Ok 'Windows x64 环境正常' }
    elseif ($arch -eq 'Arm64') { Write-Warn '检测到 ARM64 Windows，将尝试安装官方 ARM64 版本' }
    else { throw ("不支持的 CPU 架构：{0}" -f $arch) }
}

# ---------------------------------------------------------------------
# 网络检测（分层：DNS -> TCP 443 -> HTTP）
# 关键原则：只要收到 DeepSeek HTTP 服务器的真实响应（2xx/400/401/403/
# 404/429 等）就说明服务器可达。鉴权错误不是网络错误；只有 DNS 失败 /
# 连接超时 / 拒绝连接 / TLS 握手失败 / TCP 443 不通 才判定不可达。
# ---------------------------------------------------------------------
function Invoke-HttpGetStatus {
    param([string]$Url, [int]$TimeoutSec = 15)
    # 返回 [int] HTTP 状态码；仅在真实网络层失败（DNS/TCP/TLS/超时）时抛异常。
    $client = $null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
        $resp = $client.GetAsync($Url).GetAwaiter().GetResult()
        return [int]$resp.StatusCode
    } finally {
        if ($client) { $client.Dispose() }
    }
}

function Test-Reachable {
    param([string]$Url)
    # 任何真实 HTTP 响应（含 400/401/403/404/429）都视为服务器可达；
    # 只有网络层失败才返回 $false。
    try {
        $null = Invoke-HttpGetStatus -Url $Url
        return $true
    } catch {
        return $false
    }
}

function Test-DeepSeekNetwork {
    # STEP A：DNS
    try {
        $null = Resolve-DnsName -Name api.deepseek.com -ErrorAction Stop
        Write-Ok 'DNS 解析正常（api.deepseek.com）'
    } catch {
        throw '无法解析 api.deepseek.com（DNS 失败）'
    }
    # STEP B：TCP 443
    $tcpOk = Test-NetConnection api.deepseek.com -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
    if (-not $tcpOk) {
        throw '无法连接 api.deepseek.com:443（TCP 连接失败）'
    }
    Write-Ok 'HTTPS 端口连通（api.deepseek.com:443）'
    # STEP C：HTTP —— 只要收到 DeepSeek 服务器响应即可达（鉴权码不视为网络错误）
    try {
        $code = Invoke-HttpGetStatus -Url 'https://api.deepseek.com/' -TimeoutSec 15
        Write-Ok "DeepSeek API 服务器已响应（HTTP $code）"
    } catch {
        throw '无法连接 DeepSeek API（api.deepseek.com:443）'
    }
}

function Test-DeepSeekApiWithKey {
    param([string]$ApiKey)
    Add-Type -AssemblyName System.Net.Http
    $client=New-Object Net.Http.HttpClient
    try {
        $client.Timeout=[TimeSpan]::FromSeconds(20)
        $null=$client.DefaultRequestHeaders.TryAddWithoutValidation('Authorization',"Bearer $ApiKey")
        $resp=$client.GetAsync('https://api.deepseek.com/models').GetAwaiter().GetResult()
        try {if([int]$resp.StatusCode -ge 200 -and [int]$resp.StatusCode -lt 300){return 'ok'};return 'auth_or_api_failed'} finally {$resp.Dispose()}
    } catch {return 'unreachable'} finally {$client.Dispose()}
}

function Get-OfficialInstallerScriptPayload {
    Set-DiagnosticStage 'DOWNLOAD' 'OFFICIAL_SCRIPT_DOWNLOAD_FAILED'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $resp = Invoke-ForeignWebRequest -Uri $OfficialInstallerUrl -TimeoutSec 30
    } catch {
        $kind = $_.Exception.GetType().FullName
        $webStatus = $null
        $cursor = $_.Exception
        while ($null -ne $cursor) {
            if ($cursor -is [System.Net.WebException]) {
                $webStatus = [string]$cursor.Status
                break
            }
            $cursor = $cursor.InnerException
        }
        $detail = if ([string]::IsNullOrWhiteSpace($webStatus)) {
            "异常类型：$kind；$($_.Exception.Message)"
        } else {
            "异常类型：$kind；网络状态：$webStatus；$($_.Exception.Message)"
        }
        throw ("DeepSeek API 可以访问，但当前网络无法下载 OpenAI 官方 Codex 安装程序。{0}" -f $detail)
    }

    Set-DiagnosticStage 'PACKAGE_VERIFY' 'OFFICIAL_SCRIPT_VALIDATION_FAILED'
    $statusCode = [int]$resp.StatusCode
    $finalUrl = $OfficialInstallerUrl
    try { $finalUrl = $resp.BaseResponse.ResponseUri.AbsoluteUri } catch {}
    $finalUri = $null
    try { $finalUri = [Uri]$finalUrl } catch {}
    $allowedFinalHosts = @('chatgpt.com', 'releases.openai.com')
    if ($statusCode -lt 200 -or $statusCode -ge 300) {
        throw ("OpenAI 官方 Codex 安装程序返回异常状态（HTTP {0}，最终地址：{1}）。" -f $statusCode, $finalUrl)
    }
    if ($null -eq $finalUri -or $finalUri.Scheme -ne 'https' -or $allowedFinalHosts -notcontains $finalUri.Host.ToLowerInvariant()) {
        throw ("OpenAI 官方 Codex 安装程序重定向到了非预期地址：{0}" -f $finalUrl)
    }

    $contentType = [string]$resp.Headers['Content-Type']
    $contentTypePresent = -not [string]::IsNullOrWhiteSpace($contentType)
    $mediaType = if ($contentTypePresent) { ($contentType -split ';', 2)[0].Trim().ToLowerInvariant() } else { '' }
    $allowedMediaTypes = @('text/plain', 'application/octet-stream', 'text/x-powershell', 'application/x-powershell')
    if ($contentTypePresent -and $allowedMediaTypes -notcontains $mediaType) {
        throw ("OpenAI 官方 Codex 安装程序 Content-Type 异常：{0}" -f $contentType)
    }

    $raw = $resp.Content
    if ($raw -is [string]) { $raw = [System.Text.Encoding]::UTF8.GetBytes([string]$raw) }
    $raw = [byte[]]$raw
    $text = [System.Text.Encoding]::UTF8.GetString($raw)
    $looksPowerShell = ($text -match '(?im)\bparam\s*\(' -or $text -match '(?im)\bfunction\s+' -or $text -match 'releases\.openai\.com')
    if ($raw.Length -lt 1000 -or -not $looksPowerShell -or $text -match '(?i)<!doctype|<html|not found') {
        throw 'OpenAI 官方安装器下载内容异常（可能为 HTML 错误页或非脚本内容），放弃该来源。'
    }

    return [PSCustomObject]@{
        Bytes       = $raw
        StatusCode  = $statusCode
        FinalUrl    = $finalUrl
        ContentType = $contentType
        Length      = $raw.Length
    }
}

function Test-NetworkByMode {
    param([string]$Mode)
    if ($Mode -eq 'deepseek') {
        Test-DeepSeekNetwork
    } else {
        if (-not (Test-Reachable 'https://chatgpt.com') -and -not (Test-Reachable 'https://auth.openai.com')) {
            Write-Fail '使用 ChatGPT/Codex 会员方式需要当前网络可以正常访问 OpenAI。'
            Write-Host '（境外资源直连失败时会自动使用一次性临时代理，仅本次安装进程有效，不修改系统设置。）'
            throw '使用 ChatGPT/Codex 会员方式需要当前网络可以正常访问 OpenAI。'
        }
        Write-Ok 'OpenAI 官方登录服务可达'
    }
}

# =====================================================================
# [3/7] 安装 Codex CLI（仅官方渠道）
# =====================================================================
function Get-CodexCommand {
    # V1 优先官方 standalone expected path（%LOCALAPPDATA%\Programs\OpenAI\Codex\bin）。
    # 原因：当前 PowerShell 会话的 PATH 可能尚未刷新（官方安装器只更新了 User PATH），
    # 或 PATH 中存在其他来源的 codex shim（npm / sandbox 等）。
    # 直接使用 expected standalone 路径做验证，不因 console 未刷新 PATH 而误判失败。
    if (Test-Path -LiteralPath $StandaloneExe) { return $StandaloneExe }
    $cmd = Get-Command codex -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# [LEGACY / SUPPORT_ONLY] 方案 B：从 openai/codex 官方 GitHub Releases 直接下载官方资产。
# V1 主安装路线不再调用本函数（主路线 = 官方 standalone install.ps1，官方脚本自带
# releases.openai.com + GitHub fallback）。本函数保留仅作支持/排查用途，不删除。
# 不依赖 api.github.com（部分网络环境会 403/限流），tag 通过 github.com/releases/latest 重定向解析。






function Get-ExistingCodexClassification {
    if (Test-Path -LiteralPath $StandaloneExe) {
        try {
            $ver = Invoke-CodexProbe -Command $StandaloneExe -TimeoutSec 20
            if (-not [string]::IsNullOrWhiteSpace($ver)) {
                return @{ Status = 'standalone'; Version = $ver }
            }
        } catch {}
        return @{ Status = 'conflict'; Reason = 'standalone_present_but_invalid'; Version = $null }
    }
    $cmd = Get-Command codex -ErrorAction SilentlyContinue
    if ($cmd) {
        $low = ([string]$cmd.Source).ToLowerInvariant()
        if ($low -match 'node_modules|\\npm\\|roaming\\npm') {
            return @{ Status = 'conflict'; Reason = 'npm_codex_present'; Version = $null }
        }
        return @{ Status = 'conflict'; Reason = 'unknown_codex_present'; Version = $null }
    }
    return @{ Status = 'none'; Version = $null }
}

# ---------------------------------------------------------------------
# V1 主安装方式：OpenAI 官方 Windows standalone install.ps1
# 流程：
#   1) 下载官方 install.ps1（校验内容确为 PowerShell 脚本，防 HTML 错误页）
#   2) 以官方非交互模式运行（CODEX_NON_INTERACTIVE=1 跳过官方脚本的交互 prompt）
#   3) 外部 5 分钟超时兜底：官方脚本内嵌的"codex.exe --version 验证"在无交互
#      自动执行环境可能挂起；若 standalone 已落地且 codex --version 有效，视为成功
#   4) 不静默 fallback 到 npm（Node/npm 不是 V1 前置）
# ---------------------------------------------------------------------
function Install-CodexCliFromOfficialStandalone {
    param([Parameter(Mandatory = $true)]$InstallerPayload)
    $tmp = Join-Path $env:TEMP ("codex-official-{0}.ps1" -f ([guid]::NewGuid().ToString('N')))
    $proc = $null
    $proxyUrl = $null
    $useOfficialInstallProxy = $false
    $tcpClient = $null

    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $connectTask = $tcpClient.ConnectAsync(
            'releases.openai.com',
            443
        )

        if (-not $connectTask.Wait(8000)) {
            throw 'TCP_CONNECT_TIMEOUT'
        }

        if (-not $tcpClient.Connected) {
            throw 'TCP_CONNECT_FAILED'
        }
    } catch {
        $proxyUrl = Get-TempProxyUrl

        if (-not [string]::IsNullOrWhiteSpace($proxyUrl)) {
            $useOfficialInstallProxy = $true
        }
    } finally {
        if ($null -ne $tcpClient) {
            $tcpClient.Dispose()
            $tcpClient = $null
        }
    }

        $scriptBytes = [byte[]]$InstallerPayload.Bytes

        if ($useOfficialInstallProxy) {
            $escapedProxyUrl = $proxyUrl.Replace("'", "''")
            $proxyBootstrap = (
                "try { [Net.WebRequest]::DefaultWebProxy = " +
                "New-Object Net.WebProxy('$escapedProxyUrl') } catch {}`r`n"
            )
            $proxyBootstrapBytes = [System.Text.Encoding]::UTF8.GetBytes(
                $proxyBootstrap
            )
            $combinedBytes = New-Object byte[] (
                $proxyBootstrapBytes.Length + $scriptBytes.Length
            )

            [Array]::Copy(
                $proxyBootstrapBytes,
                0,
                $combinedBytes,
                0,
                $proxyBootstrapBytes.Length
            )
            [Array]::Copy(
                $scriptBytes,
                0,
                $combinedBytes,
                $proxyBootstrapBytes.Length,
                $scriptBytes.Length
            )

            $scriptBytes = $combinedBytes
            Write-Host 'official_install_proxy=on'
        } else {
            Write-Host 'official_install_proxy=off'
        }
    try {
        [System.IO.File]::WriteAllBytes($tmp, $scriptBytes)

        Write-Host '    正在通过 OpenAI 官方安装器安装 Codex（下载约 130MB，请稍候）…'
        # 官方非交互模式只作用于该子进程；不写 User/System Environment。
        $inner = '& "' + $tmp + '"'
        $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($inner))
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $info.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $enc
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.EnvironmentVariables['CODEX_NON_INTERACTIVE'] = '1'
        if ($useOfficialInstallProxy) {
            $info.EnvironmentVariables['HTTPS_PROXY'] = $proxyUrl
            $info.EnvironmentVariables['HTTP_PROXY'] = $proxyUrl
            $info.EnvironmentVariables['NO_PROXY'] = 'localhost,127.0.0.1'
        }
        $proc = New-Object Diagnostics.Process
        $proc.StartInfo = $info
        Write-InstallProcessEvent -State 'install_process_started'
        if (-not $proc.Start()) { throw 'OFFICIAL_INSTALL_START_FAILED' }
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $done = $proc.WaitForExit(300000)  # 官方安装器下载+解压+安装，5 分钟上限
        if (-not $done) {
            try { $proc.Kill() } catch {}
            $proc.WaitForExit()
            $stdout = $stdoutTask.Result
            $stderr = $stderrTask.Result
            Write-InstallProcessEvent -State 'install_process_failed' -TimedOut $true -ExceptionType 'System.TimeoutException' -Stdout $stdout -Stderr $stderr
            $script:diagnosticCode = 'OFFICIAL_INSTALL_TIMEOUT'
            throw 'OFFICIAL_INSTALL_TIMEOUT'
        }
        $proc.WaitForExit()
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        if ($proc.ExitCode -ne 0) {
            Write-InstallProcessEvent -State 'install_process_failed' -ExitCode ([string]$proc.ExitCode) -ExceptionType 'System.InvalidOperationException' -Stdout $stdout -Stderr $stderr
            # 仅当 THZ 用预期绝对路径再次验证 codex.exe --version 成功时继续；
            # PATH/config/final verify 仍在后续强制执行。
            $installedVersion = $null
            if (Test-Path -LiteralPath $StandaloneExe -PathType Leaf) {
                try { $installedVersion = Invoke-CodexProbe -Command $StandaloneExe -TimeoutSec 20 } catch {}
            }
            if ([string]::IsNullOrWhiteSpace($installedVersion)) { throw 'OFFICIAL_INSTALL_FAILED' }
            Write-Warn '官方安装器末端验证返回非零，已通过 standalone 绝对路径验证；继续完成 PATH 与最终验证。'
            return $true
        }
        Write-InstallProcessEvent -State 'install_process_completed' -ExitCode '0' -Stdout $stdout -Stderr $stderr
        if (-not (Test-Path -LiteralPath $StandaloneExe)) {
            throw 'OFFICIAL_INSTALL_OUTPUT_MISSING'
        }
        return $true
    } catch {
        if ($_.Exception.Message -notin @('OFFICIAL_INSTALL_TIMEOUT','OFFICIAL_INSTALL_FAILED')) {
            Write-InstallProcessEvent -State 'install_process_failed' -ExceptionType ($_.Exception.GetType().FullName)
        }
        throw
    } finally {
        if ($null -ne $proc) { $proc.Dispose() }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}



function Get-CodexHome {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { return $env:CODEX_HOME }
    return (Join-Path $HOME '.codex')
}

function Assert-CodexConfigPaths {
    param([string]$CodexHome, [string]$ConfigPath, [string]$ModelsPath)
    if ([string]::IsNullOrWhiteSpace($CodexHome) -or -not [IO.Path]::IsPathRooted($CodexHome)) { throw 'CONFIG_HOME_INVALID' }
    $expectedHome = Get-CodexHome
    if ([string]::IsNullOrWhiteSpace($expectedHome) -or -not [IO.Path]::IsPathRooted($expectedHome)) { throw 'CONFIG_HOME_INVALID' }
    try {
        $canonicalHome = [IO.Path]::GetFullPath($CodexHome).TrimEnd([char[]]@('\','/'))
        $canonicalExpected = [IO.Path]::GetFullPath($expectedHome).TrimEnd([char[]]@('\','/'))
        if (-not [string]::Equals($canonicalHome,$canonicalExpected,[StringComparison]::OrdinalIgnoreCase)) { throw 'CONFIG_HOME_INVALID' }
        foreach ($entry in @(@($ConfigPath,'config.toml'),@($ModelsPath,'models.json'))) {
            if ([string]::IsNullOrWhiteSpace($entry[0]) -or -not [IO.Path]::IsPathRooted($entry[0])) { throw 'CONFIG_HOME_INVALID' }
            if (-not [string]::Equals([IO.Path]::GetFullPath($entry[0]),(Join-Path $canonicalHome $entry[1]),[StringComparison]::OrdinalIgnoreCase)) { throw 'CONFIG_HOME_INVALID' }
        }
    } catch { throw 'CONFIG_HOME_INVALID' }
}

function Backup-Config {
    param([string]$CodexHome, [string]$ConfigPath, [string]$ModelsPath)
    Assert-CodexConfigPaths -CodexHome $CodexHome -ConfigPath $ConfigPath -ModelsPath $ModelsPath
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDir = Join-Path $CodexHome ("backups\{0}" -f $ts)
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    if (Test-Path -LiteralPath $ConfigPath) {
        Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $backupDir 'config.toml') -Force
    }
    if (Test-Path -LiteralPath $ModelsPath) {
        Copy-Item -LiteralPath $ModelsPath -Destination (Join-Path $backupDir 'models.json') -Force
    }
    Write-Ok "已备份原有配置 -> $backupDir"
    return $backupDir
}

function Restore-Backup {
    param([string]$BackupDir, [string]$ConfigPath, [string]$ModelsPath)
    Write-Warn '配置校验失败，恢复备份…'
    if (Test-Path -LiteralPath (Join-Path $BackupDir 'config.toml')) {
        Copy-Item -LiteralPath (Join-Path $BackupDir 'config.toml') -Destination $ConfigPath -Force
        Write-Ok 'config.toml 已恢复'
    } elseif (Test-Path -LiteralPath $ConfigPath) {
        Remove-Item -LiteralPath $ConfigPath -Force
        Write-Ok 'config.toml 已移除（安装前不存在）'
    }
    if (Test-Path -LiteralPath (Join-Path $BackupDir 'models.json')) {
        Copy-Item -LiteralPath (Join-Path $BackupDir 'models.json') -Destination $ModelsPath -Force
        Write-Ok 'models.json 已恢复'
    } elseif (Test-Path -LiteralPath $ModelsPath) {
        Remove-Item -LiteralPath $ModelsPath -Force
        Write-Ok 'models.json 已移除（安装前不存在）'
    }
}

function Set-OfficialAccountConfig {
    param([string]$CodexHome, [string]$ConfigPath, [string]$ModelsPath)
    Assert-CodexConfigPaths -CodexHome $CodexHome -ConfigPath $ConfigPath -ModelsPath $ModelsPath
    $backupDir = Backup-Config -CodexHome $CodexHome -ConfigPath $ConfigPath -ModelsPath $ModelsPath
    $tempPath = "$ConfigPath.thz-official.tmp"
    try {
        $lines = if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) { [IO.File]::ReadAllLines($ConfigPath) } else { @() }
        $result = New-Object Collections.Generic.List[string]
        $inTopLevel = $true
        $activeKeys = 'model','model_provider','preferred_auth_method','forced_login_method','model_reasoning_effort','model_catalog_json'
        foreach ($line in $lines) {
            if ($line -match '^\s*\[') { $inTopLevel = $false }
            $drop = $false
            if ($inTopLevel) { foreach ($key in $activeKeys) { if ($line -match ('^\s*' + [regex]::Escape($key) + '\s*=')) { $drop = $true; break } } }
            if (-not $drop) { $result.Add($line) }
        }
        if ($result.Count -eq 0) { $result.Add('# Codex official account route uses official provider defaults.') }
        $utf8NoBom = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllLines($tempPath,$result,$utf8NoBom)
        $check = [IO.File]::ReadAllText($tempPath)
        $top = ($check -split '(?m)^\s*\[')[0]
        foreach ($key in $activeKeys) { if ($top -match ('(?m)^\s*' + [regex]::Escape($key) + '\s*=')) { throw 'OFFICIAL_PROVIDER_CONFIG_INVALID' } }
        Move-Item -LiteralPath $tempPath -Destination $ConfigPath -Force
        return $backupDir
    } catch {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
        Restore-Backup -BackupDir $backupDir -ConfigPath $ConfigPath -ModelsPath $ModelsPath
        throw 'OFFICIAL_PROVIDER_CONFIG_FAILED'
    }
}

# =====================================================================
# DeepSeek 模式 [4/7]：配置 DeepSeek 为默认 Provider / 模型
# =====================================================================
function Write-DeepSeekConfig {
    param(
        [string]$ConfigPath, [string]$ModelsPath, [string]$Model,
        [string]$ProviderId, [string]$ProviderBase, [string]$ApiKey, [string]$ModelsJson,
        [switch]$UseEnvironmentKey
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    $parsed = $ModelsJson | ConvertFrom-Json
    $slugs = @($parsed.models | ForEach-Object { $_.slug })
    if ($slugs -notcontains $Model) { throw "models.json 中缺少默认模型 $Model" }
    $targetKeys = @('model','model_provider','preferred_auth_method','forced_login_method',
                    'model_reasoning_effort','model_catalog_json')
    $lines = if (Test-Path -LiteralPath $ConfigPath) {
        [System.IO.File]::ReadAllLines($ConfigPath)
    } else { @() }

    $preserved = New-Object System.Collections.Generic.List[string]
    $inSection = $false; $skip = $false
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith('[')) {
            $inSection = $true
            $secName = $trimmed.Trim('[', ']').Trim()
            $skip = ($secName -eq "model_providers.$ProviderId")
            if (-not $skip) { $preserved.Add($line) }
            continue
        }
        if ($skip) { continue }
        if (-not $inSection -and -not $trimmed.StartsWith('#') -and $trimmed.Contains('=')) {
            $eq = $trimmed.IndexOf('=')
            $k = $trimmed.Substring(0, $eq).Trim().Trim('"', "'")
            if ($targetKeys -contains $k) { continue }
        }
        $preserved.Add($line)
    }

    $catalogValue = $ModelsPath -replace '\\', '/'
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add("model = `"$Model`"")
    $out.Add("model_provider = `"$ProviderId`"")
    $out.Add('preferred_auth_method = "apikey"')
    $out.Add('forced_login_method = "api"')
    $out.Add('model_reasoning_effort = "high"')
    $out.Add("model_catalog_json = `"$catalogValue`"")
    $out.Add('')
    foreach ($l in $preserved) { $out.Add($l) }
    if ($out[$out.Count - 1] -ne '') { $out.Add('') }
    $out.Add("[model_providers.$ProviderId]")
    $out.Add("name = `"$ProviderId`"")
    $out.Add("base_url = `"$ProviderBase`"")
    $out.Add('wire_api = "responses"')
    if ($UseEnvironmentKey) { $out.Add('env_key = "DEEPSEEK_API_KEY"') }
    else { $out.Add("experimental_bearer_token = `"$ApiKey`"") }

    # TOML keys are scoped by table. Only root keys must be unique here;
    # keys such as command/type/url may legitimately repeat in unrelated
    # MCP/provider tables preserved from the user's existing configuration.
    $seen = @{}; $inTopLevel = $true
    foreach ($l in $out) {
        $t = $l.Trim()
        if ($t.StartsWith('[')) { $inTopLevel = $false; continue }
        if (-not $inTopLevel -or $t.StartsWith('#') -or $t -eq '') { continue }
        if ($t.Contains('=')) {
            $eq = $t.IndexOf('=')
            $k = $t.Substring(0, $eq).Trim().Trim('"', "'")
            if ($seen.ContainsKey($k)) { throw "生成的 config.toml 出现重复顶层键：$k" }
            $seen[$k] = $true
        }
    }
    $suffix = [guid]::NewGuid().ToString('N')
    $configTmp = "$ConfigPath.$suffix.tmp"
    $modelsTmp = "$ModelsPath.$suffix.tmp"
    try {
        # Build and validate both candidates before replacing either live file.
        [System.IO.File]::WriteAllText($configTmp, (($out -join "`n") + "`n"), $utf8NoBom)
        [System.IO.File]::WriteAllText($modelsTmp, $ModelsJson.TrimEnd("`r", "`n") + "`n", $utf8NoBom)
        $candidateConfig = [System.IO.File]::ReadAllText($configTmp, [Text.Encoding]::UTF8)
        $candidateModels = [System.IO.File]::ReadAllText($modelsTmp, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($candidateConfig -notmatch ('(?m)^model_provider\s*=\s*"' + [regex]::Escape($ProviderId) + '"\s*$')) { throw 'CONFIG_CANDIDATE_INVALID' }
        if ($candidateConfig -notmatch ('(?m)^\[model_providers\.' + [regex]::Escape($ProviderId) + '\]\s*$')) { throw 'CONFIG_CANDIDATE_INVALID' }
        if (@($candidateModels.models | ForEach-Object { $_.slug }) -notcontains $Model) { throw 'MODELS_CANDIDATE_INVALID' }
        Move-Item -LiteralPath $modelsTmp -Destination $ModelsPath -Force
        Move-Item -LiteralPath $configTmp -Destination $ConfigPath -Force
        # Re-read the committed files; outer Invoke-DeepSeekKeySetup restores
        # the backup if either commit or post-write validation fails.
        $committedModels = [System.IO.File]::ReadAllText($ModelsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $committedConfig = [System.IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8)
        if (@($committedModels.models | ForEach-Object { $_.slug }) -notcontains $Model -or $committedConfig -notmatch ('(?m)^model_provider\s*=\s*"' + [regex]::Escape($ProviderId) + '"\s*$')) { throw 'CONFIG_COMMIT_INVALID' }
    } finally {
        if (Test-Path -LiteralPath $configTmp) { Remove-Item -LiteralPath $configTmp -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $modelsTmp) { Remove-Item -LiteralPath $modelsTmp -Force -ErrorAction SilentlyContinue }
    }
    Write-Ok "已写入 AI 模型配置：$ConfigPath"
}

# =====================================================================
# DeepSeek 本地 Key 输入（V2：Key 只在客户本机，绝不上传服务器）
# =====================================================================
function Mask-Key {
    param([string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key)) { return '<empty>' }
    if ($Key.Length -le 8) { return '****' }
    return $Key.Substring(0, 4) + '****' + $Key.Substring($Key.Length - 4)
}

function Show-DeepSeekKeyGuiDialog {
    # 独立 Windows GUI 输入窗口（PowerShell + System.Windows.Forms，原生）。
    # 输入框使用密码样式掩码（UseSystemPasswordChar），支持 Ctrl+V / 右键粘贴 / 完整字符串。
    # 返回 Hashtable：@{ Ok=$true; Key='...' } 确认；@{ Ok=$false; Key='' } 取消。
    # Key 只存在于本 PowerShell 进程内存，不写文件、不进日志/URL/命令行参数/环境变量。
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $script:GuiKeyResult = $null
    $script:GuiKeyBox = $null

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Codex AI Installer'
    $form.Size = New-Object System.Drawing.Size(480, 250)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "请输入你的 DeepSeek API Key`n`nKey 只在当前电脑处理，`n不会上传服务器。"
    $lbl.Location = New-Object System.Drawing.Point(24, 18)
    $lbl.Size = New-Object System.Drawing.Size(420, 64)
    $lbl.Font = New-Object System.Drawing.Font('Microsoft YaHei', 10)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(24, 96)
    $txt.Size = New-Object System.Drawing.Size(420, 28)
    $txt.Font = New-Object System.Drawing.Font('Microsoft YaHei', 11)
    $txt.UseSystemPasswordChar = $true   # 密码样式掩码，不显示完整 Key
    $script:GuiKeyBox = $txt

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = '确认'
    $btnOk.Location = New-Object System.Drawing.Point(180, 150)
    $btnOk.Size = New-Object System.Drawing.Size(120, 36)
    $btnOk.DialogResult = 'None'
    $btnOk.Add_Click({
        $script:GuiKeyResult = @{ Ok = $true; Key = $script:GuiKeyBox.Text }
        $form.Close()
    })

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.Location = New-Object System.Drawing.Point(320, 150)
    $btnCancel.Size = New-Object System.Drawing.Size(120, 36)
    $btnCancel.Add_Click({
        $script:GuiKeyResult = @{ Ok = $false; Key = '' }
        $form.Close()
    })

    $form.Controls.Add($lbl)
    $form.Controls.Add($txt)
    $form.Controls.Add($btnOk)
    $form.Controls.Add($btnCancel)
    $form.AcceptButton = $btnOk
    $form.CancelButton = $btnCancel

    $null = $form.ShowDialog()
    if ($null -eq $script:GuiKeyResult) { $script:GuiKeyResult = @{ Ok = $false; Key = '' } }
    $form.Dispose()
    return $script:GuiKeyResult
}





function Invoke-DeepSeekKeySetup {
    param([string]$CodexHome,[string]$ConfigPath,[string]$ModelsPath,$Cfg,[switch]$UseEnvironmentKey)
    Assert-CodexConfigPaths -CodexHome $CodexHome -ConfigPath $ConfigPath -ModelsPath $ModelsPath
    for($attempt=0;$attempt -lt 3;$attempt++) {
        $res=Show-DeepSeekKeyGuiDialog
        if(-not $res.Ok){throw 'KEY_INPUT_CANCELLED'}
        $key=([string]$res.Key).Trim();$res=$null;$script:GuiKeyResult=$null
        if($key.Length -lt 12){[Windows.Forms.MessageBox]::Show('Key 不完整，请重新输入。','特好装')|Out-Null;continue}
        $result=Test-DeepSeekApiWithKey -ApiKey $key
        if($result -ne 'ok'){
            $key=$null
            $retry=[Windows.Forms.MessageBox]::Show('当前 Key 或网络未能通过验证。是否重新输入？','特好装',[Windows.Forms.MessageBoxButtons]::RetryCancel)
            if($retry -eq [Windows.Forms.DialogResult]::Retry){continue}
            throw 'KEY_VALIDATION_FAILED'
        }
        $script:DeepSeekBackupDir=Backup-Config -CodexHome $CodexHome -ConfigPath $ConfigPath -ModelsPath $ModelsPath
        $oldEnv=$null;$hadOldEnv=$false
        try {
            if($UseEnvironmentKey){$oldEnv=[Environment]::GetEnvironmentVariable('DEEPSEEK_API_KEY',[EnvironmentVariableTarget]::User);$hadOldEnv=$null-ne $oldEnv;[Environment]::SetEnvironmentVariable('DEEPSEEK_API_KEY',$key,[EnvironmentVariableTarget]::User)}
            Write-DeepSeekConfig -ConfigPath $ConfigPath -ModelsPath $ModelsPath -Model $Cfg.model -ProviderId $Cfg.provider_id -ProviderBase $Cfg.provider_base_url -ApiKey $key -ModelsJson $Cfg.models_json -UseEnvironmentKey:$UseEnvironmentKey
            if(-not(Test-ConfigWritten -ConfigPath $ConfigPath -ProviderId $Cfg.provider_id)){throw 'CONFIG_INVALID'}
        } catch {
            if($script:DeepSeekBackupDir){Restore-Backup -BackupDir $script:DeepSeekBackupDir -ConfigPath $ConfigPath -ModelsPath $ModelsPath}
            if($UseEnvironmentKey){[Environment]::SetEnvironmentVariable('DEEPSEEK_API_KEY',$(if($hadOldEnv){$oldEnv}else{$null}),[EnvironmentVariableTarget]::User)}
            throw
        } finally {$key=$null}
        return
    }
    throw 'KEY_ATTEMPTS_EXHAUSTED'
}

function Test-ConfigWritten {
    param([string]$ConfigPath, [string]$ProviderId)
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $false }
    $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    return ($raw -match "(?m)^\[model_providers\.$ProviderId\]")
}

# =====================================================================
# ChatGPT 模式（Route C）：官方 Desktop App 流程
# =====================================================================
# Route C 不再安装 Codex CLI、不执行 CLI 登录、不检查 CLI 登录态、
# 不修改 config.toml。登录完全由用户在 OpenAI 官方 Desktop App / 官网
# 流程中自行完成，本安装器不采集任何凭据。

# =====================================================================
# [5/7] / [6/7] 验证 Codex CLI
# =====================================================================
function Invoke-CodexProbe {
    param([string]$Command, [int]$TimeoutSec = 25)
    if (-not (Test-Path -LiteralPath $Command -PathType Leaf) -or [IO.Path]::GetExtension($Command) -ne '.exe') { throw 'VERIFY_EXECUTABLE_MISSING' }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Command
    $info.Arguments = '--version'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $proc = New-Object Diagnostics.Process
    $proc.StartInfo = $info
    try {
        if (-not $proc.Start()) { throw 'VERIFY_START_FAILED' }
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) { $proc.Kill(); throw 'VERIFY_TIMEOUT' }
        $proc.WaitForExit()
        Write-SafeDiagnostic 'PROCESS_EXIT' 'NONE' ([string]$proc.ExitCode)
        if ($proc.ExitCode -ne 0) { throw 'VERIFY_EXIT_CODE' }
        $output = $stdout.Result + "`n" + $stderr.Result
        if ($output -notmatch '(?im)^(?:codex-cli|Codex CLI)\s+v?(\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?)\s*$') { throw 'VERIFY_INVALID_VERSION' }
        return $Matches[1]
    } finally { $proc.Dispose() }
}

function Test-CodexCli {
    $cmd = Get-CodexCommand
    if (-not $cmd) { throw '找不到 codex 命令。' }
    $ver = Invoke-CodexProbe -Command $cmd
    Write-Ok "Codex CLI 可正常执行（$ver）"
    return $ver
}

# =====================================================================
# Desktop 检测（不构成硬失败条件）
# =====================================================================
