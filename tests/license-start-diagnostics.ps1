#requires -Version 5.1
param([string]$BuiltExe = '')
$ErrorActionPreference = 'Stop'
# Load functions only; never execute installer entry points or contact production.
foreach ($file in @('exe-src/Runner.ps1','exe-src/InstallerLibrary.ps1')) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PWD $file), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Parse failed' }
    foreach ($name in @('ConvertTo-SafeDiagDetail','Set-LicenseStartFailure','Invoke-InstallFailReport','Get-FailStepForPhase','Invoke-ApiStart')) {
        $fn = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        foreach ($item in $fn) { . ([scriptblock]::Create($item.Extent.Text)) }
    }
}
$script:InstallToken = 'A' * 64
$script:InstallerVersion = '4.6.5.0'
$script:phase = 'LICENSE_START'; $script:diagnosticCode = 'LICENSE_START_FAILED'
$BASE_URL = 'http://staging.invalid'
function Invoke-RestMethod { param($Uri,$Method,$ContentType,$Body,$TimeoutSec) $script:Captured = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json }
foreach ($code in @('token_invalid','token_expired','token_state_invalid','token_device_mismatch','license_inactive','route_unavailable')) {
    Set-LicenseStartFailure ([pscustomobject]@{error=$code;message='安装授权已过期，请回到安装页面重新下载'})
    Invoke-InstallFailReport
    if ($script:Captured.detail -notlike "server_error=$code message=*") { throw "Missing server error: $code" }
    if ($script:LicenseStartMessage -ne '安装授权已过期，请回到安装页面重新下载') { throw 'Message changed' }
}
Set-LicenseStartFailure ([pscustomobject]@{error='token_expired';message=("过期 $script:InstallToken https://user:password@example.com/?key=secret`r`n下一行 sk-123456789")})
if ($script:LicenseStartFailDetail -match 'AAAA|user:password|example.com|key=secret|sk-123456789|[\r\n]') { throw 'Sensitive detail leaked' }
function Get-DeviceFingerprint { return ('b' * 64) }
function Invoke-LicenseRequest { return [pscustomobject]@{ok=$true;client_type='cli';provider_type='chatgpt'} }
$result = Invoke-ApiStart -Token $script:InstallToken
if (-not $result.ok -or $result.client_type -ne 'cli') { throw 'Success response changed' }
Write-Host 'PASS: six server errors, Chinese message, redaction, successful start response (isolated tests; no staging claims).'

if ($BuiltExe) {
    $assembly = [Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($BuiltExe))
    $type = $assembly.GetType('Bootstrap')
    $flags = [Reflection.BindingFlags]'NonPublic,Static'
    $dir = Join-Path $env:TEMP ('license-message-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    try {
        $text = '安装授权已过期，请回到安装页面重新下载'
        [IO.File]::WriteAllText((Join-Path $dir 'license-start-message.txt'), $text, [Text.Encoding]::UTF8)
        $type.GetField('workspace', $flags).SetValue($null, $dir)
        $type.GetField('errorCode', $flags).SetValue($null, 'LICENSE_START_FAILED')
        $type.GetField('stage', $flags).SetValue($null, 'LICENSE_START')
        $dialog = $type.GetMethod('Failure', $flags).Invoke($null, @([Exception]::new('test')))
        if (-not $dialog.Contains($text) -or $dialog.Contains('SAFE_MESSAGE')) { throw 'Dialog lost server message' }
        Remove-Item -LiteralPath (Join-Path $dir 'license-start-message.txt')
        $dialog = $type.GetMethod('Failure', $flags).Invoke($null, @([Exception]::new('test')))
        if (-not $dialog.Contains('SAFE_MESSAGE')) { throw 'Dialog fallback missing' }
        Write-Host 'PASS: built EXE dialog text preserves server message and falls back when absent.'
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
}
