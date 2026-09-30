#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$script:phase='PREFLIGHT'; $script:diagnosticCode='POWERSHELL_INITIALIZATION_FAILED'
# 与 C# 启动器 AssemblyVersion 保持一致（P0 移植：版本号统一 4.6.0.0）。
$script:InstallerVersion='4.6.0.0'
function Write-SafeDiagnostic([string]$Result,[string]$ExceptionType='NONE',[string]$ExitCode='NONE') {
    try {
        $line = [DateTime]::UtcNow.ToString('o')+' installer=4.6.0.0 windows='+[Environment]::OSVersion.Version+' stage='+$script:phase+' code='+$(if($Result -eq 'PENDING'){'NONE'}else{$script:diagnosticCode})+' exit='+$ExitCode+' exception='+$ExceptionType+' workspace='+$PSScriptRoot+' verification='+$Result
        [IO.File]::AppendAllText($env:THZ_DIAGNOSTIC_LOG,$line+[Environment]::NewLine)
    } catch {}
}
function Set-DiagnosticStage([string]$Stage,[string]$Code) {
    $script:phase=$Stage; $script:diagnosticCode=$Code
    Write-SafeDiagnostic 'PENDING'
    try { [IO.File]::WriteAllLines((Join-Path $PSScriptRoot 'diagnostic-status.txt'),[string[]]@($Stage,$Code)) } catch {}
}
function ConvertTo-SafeInstallSummary([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return 'EMPTY' }
    $safe = $Text `
        -replace '(?i)Bearer\s+[A-Za-z0-9._~+\-/=]+', 'Bearer [REDACTED]' `
        -replace '(?i)(api[_-]?key|authorization|token|cookie|license(?:[_-]?code)?|password|secret)\s*[:=]\s*[^\s;]+', '$1=[REDACTED]'
    $safe = ($safe -replace '[\r\n\t]+', ' ' -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', '').Trim()
    if ($safe.Length -gt 2000) { $safe = $safe.Substring($safe.Length - 2000) }
    return $safe
}
function Write-InstallProcessEvent {
    param([string]$State,[string]$ExitCode='NONE',[bool]$TimedOut=$false,[string]$ExceptionType='NONE',[string]$Stdout='',[string]$Stderr='')
    if (@('install_process_started','install_process_completed','install_process_failed') -notcontains $State) { return }
    if ($ExitCode -notmatch '^(?:NONE|-?\d+)$') { $ExitCode='NONE' }
    if ($ExceptionType -notmatch '^[A-Za-z0-9_.]+$') { $ExceptionType='UNKNOWN' }
    try {
        $line=[DateTime]::UtcNow.ToString('o')+' stage=INSTALL operation=OFFICIAL_INSTALL state='+$State+' install_process_exit_code='+$ExitCode+' install_process_timed_out='+$TimedOut+' exception_type='+$ExceptionType+' stdout_summary="'+(ConvertTo-SafeInstallSummary $Stdout)+'" stderr_summary="'+(ConvertTo-SafeInstallSummary $Stderr)+'"'
        [IO.File]::AppendAllText($env:THZ_DIAGNOSTIC_LOG,$line+[Environment]::NewLine)
    } catch {}
}
function Write-LicenseRequestEvent {
    param([string]$Operation,[string]$State,[string]$Path,[string]$Status='NONE',[bool]$Received=$false,[string]$ExceptionType='NONE',[string]$ServerCode='NONE')
    # Fixed operation/path pairs. No request body, response text, headers or credentials.
    $allowed=@{'LICENSE_VERIFY'='/api/license/verify';'LICENSE_SELECT_ROUTE'='/api/installer/select-route';'LICENSE_START'='/api/installer/start';'LICENSE_COMPLETE'='/api/installer/complete'}
    if(-not $allowed.ContainsKey($Operation) -or $allowed[$Operation] -ne $Path){return}
    if(@('request_started','request_completed','request_failed') -notcontains $State){return}
    $codes=@('INVALID_LICENSE','LICENSE_DISABLED','LICENSE_EXPIRED','LICENSE_REVOKED','DEVICE_MISMATCH','DEVICE_FINGERPRINT_INVALID','RATE_LIMITED','invalid_session','session_expired','invalid_token','token_expired','token_used','catalog_unavailable','public_base_url_invalid','INVALID_RESPONSE')
    if($codes -notcontains $ServerCode){$ServerCode='UNRECOGNIZED_OR_ABSENT'}
    if($Status -notmatch '^\d{3}$'){$Status='NONE'}
    if($ExceptionType -notmatch '^[A-Za-z0-9_.]+$'){$ExceptionType='UNKNOWN'}
    try {
        $hostName=([Uri]$BASE_URL).DnsSafeHost
        $code=if($State -eq 'request_failed'){$Operation+'_FAILED'}else{'NONE'}
        $line=[DateTime]::UtcNow.ToString('o')+' stage='+$Operation+' operation='+$Operation+' state='+$State+' host='+$hostName+' request_path='+$Path+' http_status='+$Status+' response_received='+$Received+' exception_type='+$ExceptionType+' error_code='+$code+' server_error_code='+$ServerCode
        [IO.File]::AppendAllText($env:THZ_DIAGNOSTIC_LOG,$line+[Environment]::NewLine)
    } catch {}
}
function Invoke-LicenseRequest {
    param([string]$Operation,[string]$Path,[string]$Body,[int]$TimeoutSec)

    try {
        $baseUri = [Uri]$BASE_URL
    } catch {
        throw 'BASE_URL 配置错误：无法解析服务地址。'
    }
    if ($baseUri.Scheme -ne 'https' -or $baseUri.DnsSafeHost -cne 'codex.thz.quest') {
        throw 'BASE_URL 配置错误：服务地址必须为 https://codex.thz.quest。'
    }

    Set-DiagnosticStage $Operation ($Operation+'_FAILED')
    Write-LicenseRequestEvent -Operation $Operation -State 'request_started' -Path $Path
    $requestId = [Guid]::NewGuid().ToString('N')

    try {
        $request = [Net.HttpWebRequest]::Create("$BASE_URL$Path")
        $request.Method = 'POST'
        $request.ContentType = 'application/json'
        $request.Proxy = $null
        $request.Timeout = $TimeoutSec * 1000
        $request.Headers['X-THZ-Request-ID'] = $requestId
        $request.Headers['X-THZ-Installer-Version'] = [string]$script:InstallerVersion

        $requestBytes = [Text.Encoding]::UTF8.GetBytes([string]$Body)
        $request.ContentLength = $requestBytes.Length
        $requestStream = $null
        try {
            $requestStream = $request.GetRequestStream()
            $requestStream.Write($requestBytes, 0, $requestBytes.Length)
        } finally {
            if ($null -ne $requestStream) { $requestStream.Dispose() }
        }

        $response = $null
        $reader = $null
        try {
            $response = [Net.HttpWebResponse]$request.GetResponse()
            $reader = New-Object IO.StreamReader($response.GetResponseStream())
            $responseBody = $reader.ReadToEnd()
        } finally {
            if ($null -ne $reader) { $reader.Dispose() }
            if ($null -ne $response) { $response.Dispose() }
        }

        $result = $responseBody | ConvertFrom-Json
        $state=if($null -ne $result -and $result.ok -eq $true){'request_completed'}else{'request_failed'}
        $safeCode=if($null -ne $result){[string]$result.error}else{'INVALID_RESPONSE'}
        Write-LicenseRequestEvent -Operation $Operation -State $state -Path $Path -Received $true -ServerCode $safeCode
        return $result
    } catch {
        $record=$_; $status='NONE';$received=$false;$type=$record.Exception.GetType().FullName;$safeCode='NONE'
        $state='request_failed'
        $errorResponse=$null
        if($record.Exception -is [Net.WebException]){
            $errorResponse=$record.Exception.Response
        }
        if($null -ne $errorResponse){
            $received=$true
            try{$status=[string][int]$errorResponse.StatusCode}catch{}
            $errorReader=$null
            try{
                $errorReader=New-Object IO.StreamReader($errorResponse.GetResponseStream())
                $errorBody=$errorReader.ReadToEnd()
                try{
                    $parsed=$errorBody|ConvertFrom-Json
                    if(-not [string]::IsNullOrWhiteSpace([string]$parsed.error)){
                        $safeCode=[string]$parsed.error
                    }
                }catch{}
            }finally{
                if($null -ne $errorReader){$errorReader.Dispose()}
                $errorResponse.Dispose()
            }
        }
        Write-LicenseRequestEvent -Operation $Operation -State $state -Path $Path -Status $status -Received $received -ExceptionType $type -ServerCode $safeCode
        throw
    }
}

function Get-OfficialCodexDesktopPackage {
    $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
        Where-Object { $_.PublisherId -eq '2p2nqsd0c76g0' -and $_.Status -eq 'Ok' } |
        Sort-Object Version -Descending | Select-Object -First 1
    return $package
}

function Write-DesktopDownloadEvent {
    param([int]$Attempt,[long]$ElapsedMs,[string]$Status='NONE',[long]$Expected=-1,[long]$Written=0,[string]$FailureStage='NONE',$ErrorRecord=$null,[string]$DownloadVia='direct')
    try {
        $parts=New-Object Collections.Generic.List[string];$cursor=if($null-ne $ErrorRecord){$ErrorRecord.Exception}else{$null};$depth=0
        while($null-ne $cursor -and $depth -lt 3){
            $parts.Add(($cursor.GetType().FullName+': '+(ConvertTo-SafeInstallSummary ([string]$cursor.Message))))
            $cursor=$cursor.InnerException;$depth++
        }
        if($Status -notmatch '^(NONE|[1-5][0-9][0-9])$'){$Status='NONE'}
        $line=[DateTime]::UtcNow.ToString('o')+' stage=DOWNLOAD operation=DESKTOP_MSIX_DOWNLOAD download_attempt='+$Attempt+' download_elapsed_ms='+$ElapsedMs+' http_status='+$Status+' content_length_expected='+$Expected+' bytes_written='+$Written+' failure_stage='+$FailureStage+' exception_chain="'+(ConvertTo-SafeInstallSummary ($parts -join ' <- '))+'" download_via='+$DownloadVia
        [IO.File]::AppendAllText($env:THZ_DIAGNOSTIC_LOG,$line+[Environment]::NewLine)
    }catch{}
}

function Get-OfficialDesktopMsix {
    param([string]$Source,[string]$Destination)
    $proxyUrl=Get-TempProxyUrl
    Add-Type -AssemblyName System.Net.Http
    $partial=$Destination+'.partial';$maxAttempts=3
    for($attempt=1;$attempt -le $maxAttempts;$attempt++){
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        $watch=[Diagnostics.Stopwatch]::StartNew();$status='NONE';$expected=[long]-1;$written=[long]0;$response=$null;$client=$null;$handler=$null
        try{
            Set-DiagnosticStage 'DOWNLOAD' 'DESKTOP_MSIX_DOWNLOAD_FAILED'
            $handler=New-Object Net.Http.HttpClientHandler
            if($attempt -gt 1 -and $proxyUrl){$handler.Proxy=New-Object Net.WebProxy($proxyUrl);$handler.UseProxy=$true}
            $handler.AllowAutoRedirect=$true;$handler.MaxAutomaticRedirections=5
            $client=New-Object Net.Http.HttpClient($handler);$client.Timeout=[TimeSpan]::FromMinutes(15)
            $response=$client.GetAsync($Source,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $status=[string][int]$response.StatusCode
            $final=$response.RequestMessage.RequestUri
            if($final.Scheme -ne 'https' -or $final.DnsSafeHost -ne 'persistent.oaistatic.com'){throw 'DESKTOP_SOURCE_INVALID'}
            if([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300){
                if([int]$response.StatusCode -ge 500){throw 'DESKTOP_DOWNLOAD_RETRYABLE_HTTP'}
                throw 'DESKTOP_DOWNLOAD_HTTP_REJECTED'
            }
            if($response.Content.Headers.ContentLength.HasValue){$expected=[long]$response.Content.Headers.ContentLength.Value;if($expected -lt 50000000){throw 'DESKTOP_PACKAGE_TOO_SMALL'}}
            $input=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult();$output=New-Object IO.FileStream($partial,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            $buffer=New-Object byte[] 1048576
            try{while(($read=$input.Read($buffer,0,$buffer.Length))-gt 0){$output.Write($buffer,0,$read);$written+=$read};$output.Flush($true)}finally{$output.Dispose();$input.Dispose()}
            if($expected -ge 0 -and $written -ne $expected){throw 'DESKTOP_CONTENT_LENGTH_MISMATCH'}
            if($written -lt 50000000){throw 'DESKTOP_PACKAGE_TOO_SMALL'}
            Move-Item -LiteralPath $partial -Destination $Destination -Force
            $watch.Stop();Write-DesktopDownloadEvent -Attempt $attempt -ElapsedMs $watch.ElapsedMilliseconds -Status $status -Expected $expected -Written $written -DownloadVia $(if($attempt -eq 1){'direct'}else{'proxy'})
            return
        }catch{
            $record=$_;$watch.Stop();Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            $message=[string]$record.Exception.Message;$cursor=$record.Exception;$retryable=$false
            while($null-ne $cursor){if($cursor -is [Net.Http.HttpRequestException] -or $cursor -is [IO.IOException] -or $cursor -is [Net.WebException] -or $cursor -is [Threading.Tasks.TaskCanceledException]){$retryable=$true};$cursor=$cursor.InnerException}
            if($message -eq 'DESKTOP_DOWNLOAD_RETRYABLE_HTTP' -or $message -eq 'DESKTOP_CONTENT_LENGTH_MISMATCH'){$retryable=$true}
            if($message -in @('DESKTOP_SOURCE_INVALID','DESKTOP_DOWNLOAD_HTTP_REJECTED','DESKTOP_PACKAGE_TOO_SMALL')){$retryable=$false}
            Write-DesktopDownloadEvent -Attempt $attempt -ElapsedMs $watch.ElapsedMilliseconds -Status $status -Expected $expected -Written $written -FailureStage 'STREAM_OR_TRANSPORT' -ErrorRecord $record -DownloadVia $(if($attempt -eq 1){'direct'}else{'proxy'})
            if(-not $retryable -or $attempt -ge $maxAttempts){throw 'DESKTOP_MSIX_DOWNLOAD_FAILED'}
            Start-Sleep -Seconds $attempt
        }finally{if($null-ne $response){$response.Dispose()};if($null-ne $client){$client.Dispose()};if($null-ne $handler){$handler.Dispose()}}
    }
    throw 'DESKTOP_MSIX_DOWNLOAD_FAILED'
}

function Install-OfficialCodexDesktop {
    $existing = Get-OfficialCodexDesktopPackage
    if ($null -ne $existing) { return $existing }
    $arch=if([string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITEW6432)){[string]$env:PROCESSOR_ARCHITECTURE}else{[string]$env:PROCESSOR_ARCHITEW6432}
    if($arch -eq 'AMD64'){$packageArch='x64'}elseif($arch -eq 'ARM64'){$packageArch='arm64'}else{throw 'DESKTOP_ARCH_UNSUPPORTED'}
    $source="https://persistent.oaistatic.com/codex-app-prod/ChatGPT-$packageArch.msix"
    $msix=Join-Path $env:TEMP ("OpenAI-Codex-{0}-{1}.msix" -f $packageArch,[guid]::NewGuid().ToString('N'))
    try {
        Write-InstallProcessEvent -State 'install_process_started'
        Get-OfficialDesktopMsix -Source $source -Destination $msix
        Set-DiagnosticStage 'PACKAGE_VERIFY' 'DESKTOP_PACKAGE_VERIFY_FAILED'
        if(-not(Test-Path -LiteralPath $msix -PathType Leaf) -or (Get-Item -LiteralPath $msix).Length -lt 50000000){throw 'DESKTOP_PACKAGE_TOO_SMALL'}
        $probe=New-Object IO.FileStream($msix,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$head=New-Object byte[] 4
        try{if($probe.Read($head,0,4)-ne 4){throw 'DESKTOP_MSIX_FORMAT_INVALID'}}finally{$probe.Dispose()}
        if($head[0]-in @(0x3c,0x7b,0x5b)){throw 'DESKTOP_ERROR_BODY_REJECTED'}
        if($head[0]-ne 0x50 -or $head[1]-ne 0x4b){throw 'DESKTOP_MSIX_FORMAT_INVALID'}
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip=[IO.Compression.ZipFile]::OpenRead($msix)
        try{
            $manifest=$zip.GetEntry('AppxManifest.xml');$signature=$zip.GetEntry('AppxSignature.p7x')
            if($null-eq $manifest -or $null-eq $signature -or $manifest.Length -lt 100){throw 'DESKTOP_MSIX_FORMAT_INVALID'}
            $settings=New-Object Xml.XmlReaderSettings;$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null
            $stream=$manifest.Open();$reader=[Xml.XmlReader]::Create($stream,$settings);$xml=New-Object Xml.XmlDocument;$xml.XmlResolver=$null
            try{$xml.Load($reader)}finally{$reader.Dispose();$stream.Dispose()}
            $identity=$xml.DocumentElement.SelectSingleNode("*[local-name()='Identity']")
            if($null-eq $identity -or $identity.GetAttribute('Name') -ne 'OpenAI.Codex' -or $identity.GetAttribute('Publisher') -ne 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B' -or $identity.GetAttribute('ProcessorArchitecture') -ne $packageArch){throw 'DESKTOP_PACKAGE_IDENTITY_INVALID'}
        }finally{$zip.Dispose()}
        $auth=Get-AuthenticodeSignature -FilePath $msix
        if($auth.Status -ne [Management.Automation.SignatureStatus]::Valid){throw 'DESKTOP_SIGNATURE_INVALID'}
        Set-DiagnosticStage 'INSTALL' 'DESKTOP_INSTALL_FAILED'
        if($null-eq (Get-Command Add-AppxPackage -ErrorAction SilentlyContinue)){throw 'DESKTOP_APPX_UNAVAILABLE'}
        try{Add-AppxPackage -Path $msix -ErrorAction Stop}catch{throw 'DESKTOP_APPX_INSTALL_FAILED'}
        $installed = Get-OfficialCodexDesktopPackage
        if ($null -eq $installed) { throw 'DESKTOP_PACKAGE_VERIFY_FAILED' }
        if([string]$installed.Architecture -notmatch $(if($packageArch-eq'x64'){'X64'}else{'Arm64'})){throw 'DESKTOP_ARCH_MISMATCH'}
        Write-InstallProcessEvent -State 'install_process_completed' -ExitCode '0'
        return $installed
    } catch {
        Write-InstallProcessEvent -State 'install_process_failed' -ExceptionType ($_.Exception.GetType().FullName)
        throw
    } finally {
        if(Test-Path -LiteralPath $msix -PathType Leaf){Remove-Item -LiteralPath $msix -Force -ErrorAction SilentlyContinue}
    }
}

function Test-OfficialCodexDesktopRegistration($Package) {
    if ($null -eq $Package -or $Package.Name -ne 'OpenAI.Codex' -or $Package.PublisherId -ne '2p2nqsd0c76g0' -or $Package.Status -ne 'Ok') { throw 'DESKTOP_PACKAGE_VERIFY_FAILED' }
    $app = Get-StartApps | Where-Object { $_.AppID -eq 'OpenAI.Codex_2p2nqsd0c76g0!App' } | Select-Object -First 1
    if ($null -eq $app) { throw 'DESKTOP_APP_REGISTRATION_MISSING' }
    return [string]$app.AppID
}

# =====================================================================
# P0-1 安装日志（文件 transcript）+ P0-2 失败上报服务端
# 移植自 Install-Codex-AI.fixed.ps1（v3.3.0），适配本入口的变量与诊断体系：
#  - Start-InstallTranscript：在 $env:TEMP 下生成
#    THZ-Codex-Setup-<yyyyMMdd-HHmmss>.log，全程记录控制台输出。
#    注意：C# 启动器会把子进程的 $env:TEMP 重定向到安装工作区下的
#    download-temp，因此 transcript 落在工作区内，随"暂时保留"保留、
#    随"立即清理"删除；C# 侧诊断日志（%LOCALAPPDATA%\THZ\InstallerLogs）
#    不受影响，仍是持久化的精简事件流。
#  - Stop-InstallTranscript：停止记录并对日志做脱敏（sk-**** 正则 +
#    install_token 中间掩码），失败时由 catch 块打印日志路径。
#  - Invoke-InstallFailReport：向服务端 POST /api/installer/fail 上报
#    失败阶段与诊断码；自身全程 try/catch，上报失败绝不影响安装主流程。
#    安全策略与现有诊断体系一致：只上报固定阶段码与诊断码，
#    绝不发送异常消息原文、响应体或任何凭据。
# =====================================================================
$script:InstallLogPath = $null
$script:TranscriptOn = $false

function Sanitize-InstallLogText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    # 复用既有脱敏正则：完整 DeepSeek Key 一律写成 sk-****
    $safe = [regex]::Replace($Text, 'sk-[A-Za-z0-9_\-\.]{4,}', 'sk-****')
    # install_token 同样敏感：只保留首尾各 4 位
    $tok = [string]$script:InstallToken
    if (-not [string]::IsNullOrWhiteSpace($tok) -and $tok.Length -gt 12) {
        $safe = $safe.Replace($tok, ($tok.Substring(0, 4) + '****' + $tok.Substring($tok.Length - 4)))
    }
    return $safe
}

function Start-InstallTranscript {
    try {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $script:InstallLogPath = Join-Path $env:TEMP ("THZ-Codex-Setup-{0}.log" -f $stamp)
        Start-Transcript -Path $script:InstallLogPath -ErrorAction Stop | Out-Null
        $script:TranscriptOn = $true
    } catch {
        # 非控制台宿主（如 -NonInteractive 重定向子进程）可能不支持
        # transcript，降级为无文件日志，不影响安装流程。
        $script:TranscriptOn = $false
        $script:InstallLogPath = $null
    }
}

function Stop-InstallTranscript {
    if ($script:TranscriptOn) {
        try { Stop-Transcript | Out-Null } catch { }
        $script:TranscriptOn = $false
    }
    if ($script:InstallLogPath -and (Test-Path -LiteralPath $script:InstallLogPath)) {
        try {
            $raw = [IO.File]::ReadAllText($script:InstallLogPath)
            $clean = Sanitize-InstallLogText $raw
            if ($clean -ne $raw) { [IO.File]::WriteAllText($script:InstallLogPath, $clean) }
        } catch { }
    }
}

function Get-FailStepForPhase {
    param([string]$Phase)
    # 后端 /api/installer/fail 要求 step 为 1~7 整数；映射到 7 步安装流程。
    switch -Wildcard ($Phase) {
        'LICENSE*'       { return 1 }  # [1/7] 验证安装授权
        'PREFLIGHT'      { return 2 }  # [2/7] 检测 Windows 环境
        'INSTALL'        { return 3 }  # [3/7] 安装 Codex / Desktop
        'CONFIG'         { return 5 }  # [5/7] 配置 AI 模型
        'DOWNLOAD'       { return 5 }  # [5/7] 获取官方安装资源
        'PACKAGE_VERIFY' { return 5 }  # [5/7] 安装包校验
        'EXTRACT'        { return 5 }  #        资源解包
        'CODEX_VERIFY'   { return 6 }  # [6/7] 验证 Codex
        default          { return 1 }  # 未知阶段：归入最早桶，error_code 保留真实阶段
    }
}

function Invoke-InstallFailReport {
    try {
        $token = [string]$script:InstallToken
        # 与参考实现一致：只在无 token 或 BASE_URL 未初始化时跳过；
        # 格式不对/服务端不认识的 token 也照报（后端 step-1 报告明确需要），
        # 后端会按 install_token 做宽松匹配，不会 4xx。
        if ([string]::IsNullOrWhiteSpace($token) -or $token -like '*THZ_INSTALL_TICKET*') { return }
        $base = [string]$BASE_URL
        if ([string]::IsNullOrWhiteSpace($base) -or $base -like '*BASE_URL*') { return }
        $code = [string]$script:diagnosticCode
        if ([string]::IsNullOrWhiteSpace($code)) { $code = 'UNKNOWN' }
        if ($code.Length -gt 64) { $code = $code.Substring(0, 64) }
        # 只上报固定阶段码与诊断码，不含异常消息原文（与现有诊断策略一致）；
        # 纵深脱敏：sk-**** 正则再过一遍。
        $msg = [regex]::Replace(("phase={0} code={1}" -f $script:phase, $code), 'sk-[A-Za-z0-9_\-\.]{4,}', 'sk-****')
        $body = @{
            install_token     = $token
            step              = (Get-FailStepForPhase $script:phase)
            error_code        = $code
            message           = $msg
            installer_version = $script:InstallerVersion
        } | ConvertTo-Json
        $null = Invoke-RestMethod -Uri "$base/api/installer/fail" `
            -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 15
    } catch {
        # 上报失败绝不影响安装主流程
    }
}

try {
Start-InstallTranscript
Set-DiagnosticStage 'PREFLIGHT' 'POWERSHELL_INITIALIZATION_FAILED'
. (Join-Path $PSScriptRoot 'InstallerLibrary.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    Test-WindowsEnvironment
    $BASE_URL       = '__THZ_API_BASE_URL__'
try { "BASE_URL="+$BASE_URL | Out-File "$env:USERPROFILE\Desktop\thz-url.txt" -Encoding ascii } catch {}
    $script:InstallToken=[string]$env:THZ_INSTALL_TICKET
    Remove-Item Env:THZ_INSTALL_TICKET -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($script:InstallToken) -or $script:InstallToken -notmatch '^[A-Za-z0-9_-]{32,128}$') { throw 'INSTALLATION_TICKET_INVALID' }
    Set-DiagnosticStage 'LICENSE_START' 'LICENSE_START_FAILED'
    $cfg=Invoke-ApiStart -Token $script:InstallToken
    if ($cfg.client_type -notin @('cli','desktop') -or $cfg.provider_type -notin @('deepseek','chatgpt') -or $cfg.mode -ne $cfg.provider_type) { throw 'INSTALL_PLAN_MISMATCH' }
    if (($cfg.provider_type -eq 'deepseek' -and $cfg.route -ne 'A') -or ($cfg.provider_type -eq 'chatgpt' -and $cfg.route -ne 'C')) { throw 'INSTALL_PLAN_MISMATCH' }
    Set-DiagnosticStage 'PREFLIGHT' 'NETWORK_OR_ENVIRONMENT_FAILED'
    if ($cfg.provider_type -eq 'deepseek') {
        Test-DeepSeekNetwork
        if ($cfg.provider_id -ne 'deepseek' -or $cfg.provider_base_url.TrimEnd('/') -ne 'https://api.deepseek.com') { throw 'PROVIDER_INVALID' }
    }
    $desktopPackage=$null;$desktopAppId=$null;$existing=$null
    if ($cfg.client_type -eq 'cli') {
        $existing=Get-ExistingCodexClassification
        if ($existing.Status -eq 'conflict') { throw 'EXISTING_CODEX_CONFLICT' }
        $payload=$null;if ($existing.Status -ne 'standalone') {$payload=Get-OfficialInstallerScriptPayload}
        Set-DiagnosticStage 'INSTALL' 'OFFICIAL_INSTALL_FAILED'
        if ($existing.Status -ne 'standalone') {$null=Install-CodexCliFromOfficialStandalone -InstallerPayload $payload}
    } else {
        Set-DiagnosticStage 'INSTALL' 'DESKTOP_INSTALL_FAILED'
        $desktopPackage=Install-OfficialCodexDesktop
        $desktopAppId=Test-OfficialCodexDesktopRegistration -Package $desktopPackage
    }
    Set-DiagnosticStage 'CONFIG' 'LOCAL_CONFIG_FAILED'
    $homePath=Get-CodexHome
    if (-not [IO.Path]::IsPathRooted($homePath) -or [IO.Path]::GetFullPath($homePath).StartsWith([IO.Path]::GetFullPath($PSScriptRoot),[StringComparison]::OrdinalIgnoreCase)) { throw 'CONFIG_LOCATION_INVALID' }
    New-Item -ItemType Directory -Path $homePath -Force | Out-Null
    $configPath=Join-Path $homePath 'config.toml';$modelsPath=Join-Path $homePath 'models.json'
    if ($cfg.provider_type -eq 'deepseek') {
        $localKey=Invoke-DeepSeekKeySetup -CodexHome $homePath -ConfigPath $configPath -ModelsPath $modelsPath -Cfg $cfg -UseEnvironmentKey:($cfg.client_type -eq 'desktop')
        $localKey=$null
    } else {
        $null=Set-OfficialAccountConfig -CodexHome $homePath -ConfigPath $configPath -ModelsPath $modelsPath
    }
    Set-DiagnosticStage 'CODEX_VERIFY' 'CODEX_VERSION_OR_CONFIG_FAILED'
    $version=if($cfg.client_type -eq 'cli'){Invoke-CodexProbe -Command $StandaloneExe}else{[string]$desktopPackage.Version}
    $raw=[IO.File]::ReadAllText($configPath)
    if ($cfg.provider_type -eq 'deepseek') {
        $authValid=if($cfg.client_type -eq 'desktop'){$raw -match '(?m)^env_key\s*=\s*"DEEPSEEK_API_KEY"\s*$'}else{$raw -match '(?m)^experimental_bearer_token\s*=\s*"[^"\r\n]+"\s*$'}
        if ($raw -notmatch '(?m)^model_provider\s*=\s*"deepseek"\s*$' -or $raw -notmatch '(?m)^\[model_providers\.deepseek\]\s*$' -or -not $authValid) { throw 'CONFIG_INVALID' }
        if ($raw -notmatch ('(?m)^model\s*=\s*"'+[regex]::Escape($cfg.model)+'"\s*$')) { throw 'MODEL_INVALID' }
        if ($raw -notmatch '(?m)^base_url\s*=\s*"https://api\.deepseek\.com/?"\s*$') { throw 'PROVIDER_URL_INVALID' }
        $catalogPath=$modelsPath -replace '\\','/'
        if ($raw -notmatch ('(?m)^model_catalog_json\s*=\s*"'+[regex]::Escape($catalogPath)+'"\s*$')) { throw 'CATALOG_PATH_INVALID' }
        $models=[IO.File]::ReadAllText($modelsPath)|ConvertFrom-Json
        if (@($models.models|ForEach-Object {$_.slug}) -notcontains $cfg.model) { throw 'MODEL_CATALOG_INVALID' }
    } else {
        $top=($raw -split '(?m)^\s*\[')[0]
        if ($top -match '(?m)^\s*(model|model_provider|preferred_auth_method|forced_login_method|model_reasoning_effort|model_catalog_json)\s*=') { throw 'OFFICIAL_PROVIDER_CONFIG_INVALID' }
    }
    # Only hashes and paths, never configuration contents or keys, leave this child process.
    $proof=New-Object Xml.XmlDocument;$root=$proof.CreateElement('Verification');$null=$proof.AppendChild($root)
    $values=@{Version=$version;ClientType=[string]$cfg.client_type;ProviderType=[string]$cfg.provider_type;Executable=$(if($cfg.client_type -eq 'cli'){$StandaloneExe}else{''});AppId=$(if($desktopAppId){$desktopAppId}else{''});Config=$configPath;Models=$(if(Test-Path -LiteralPath $modelsPath -PathType Leaf){$modelsPath}else{''});ConfigHash=(Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash;ModelsHash=$(if(Test-Path -LiteralPath $modelsPath -PathType Leaf){(Get-FileHash -LiteralPath $modelsPath -Algorithm SHA256).Hash}else{''})}
    foreach($name in $values.Keys){$node=$proof.CreateElement($name);$node.InnerText=$values[$name];$null=$root.AppendChild($node)}
    $proof.Save((Join-Path $PSScriptRoot 'verification.xml'))
    Invoke-ApiComplete
    Write-SafeDiagnostic 'PASS' 'NONE' '0'
    try { Stop-EmbeddedProxy } catch { }
    Stop-InstallTranscript
    exit 0
} catch {
    # Only fixed codes and exception type; never exception messages, bodies or invocation data.
    $known=@('CONFIG_HOME_INVALID','INSTALLATION_TICKET_INVALID','INSTALL_PLAN_MISMATCH','EXISTING_CODEX_CONFLICT','PROVIDER_INVALID','CONFIG_LOCATION_INVALID','CONFIG_INVALID','MODEL_INVALID','PROVIDER_URL_INVALID','CATALOG_PATH_INVALID','MODEL_CATALOG_INVALID','KEY_INPUT_CANCELLED','KEY_VALIDATION_FAILED','KEY_ATTEMPTS_EXHAUSTED','VERIFY_EXECUTABLE_MISSING','VERIFY_START_FAILED','VERIFY_TIMEOUT','VERIFY_EXIT_CODE','VERIFY_INVALID_VERSION','OFFICIAL_INSTALL_START_FAILED','OFFICIAL_INSTALL_TIMEOUT','OFFICIAL_INSTALL_FAILED','OFFICIAL_INSTALL_OUTPUT_MISSING','DESKTOP_ARCH_UNSUPPORTED','DESKTOP_SOURCE_INVALID','DESKTOP_DOWNLOAD_FAILED','DESKTOP_PACKAGE_TOO_SMALL','DESKTOP_MSIX_FORMAT_INVALID','DESKTOP_PACKAGE_IDENTITY_INVALID','DESKTOP_SIGNATURE_INVALID','DESKTOP_PUBLISHER_INVALID','DESKTOP_APPX_UNAVAILABLE','DESKTOP_APPX_INSTALL_FAILED','DESKTOP_ARCH_MISMATCH','DESKTOP_PACKAGE_VERIFY_FAILED','DESKTOP_APP_REGISTRATION_MISSING')
    if ($script:phase -notlike 'LICENSE_*' -and $known -contains $_.Exception.Message) { $script:diagnosticCode=$_.Exception.Message }
    # P0-2: 上报失败到服务端（仅固定阶段码与诊断码，不含异常原文；上报失败不影响退出流程）
    try { Invoke-InstallFailReport } catch { }
    Write-SafeDiagnostic 'FAILED' ($_.Exception.GetType().FullName) '1'
    Set-DiagnosticStage $script:phase $script:diagnosticCode
    # P0-1: 停止 transcript（落盘前脱敏），把 transcript 路径写入 C# 侧持久诊断日志
    # （C# 启动器丢弃了子进程 stdout，Write-Host 只服务于直接运行 PS1 的场景；
    # 持久化可发现性靠下面这行诊断日志桥接）。
    try { Stop-EmbeddedProxy } catch { }
    Stop-InstallTranscript
    try {
        if ($script:InstallLogPath) {
            $tline = [DateTime]::UtcNow.ToString('o') + ' transcript_path=' + $script:InstallLogPath
            [IO.File]::AppendAllText($env:THZ_DIAGNOSTIC_LOG, $tline + [Environment]::NewLine)
        }
    } catch { }
    Write-Host ''
    if ($script:InstallLogPath) {
        Write-Host ("安装日志已保存：{0}" -f $script:InstallLogPath)
        Write-Host '请把这个日志文件发给客服 QQ 89523844，以便定位问题。'
    }
    exit 1
}
