#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$BaseUrl = 'https://codex.thz.quest',
    [string]$TestUri = 'https://www.google.com/robots.txt'
)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion -lt [version]'5.1' -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'Run this probe in Windows PowerShell 5.1 (.NET Framework).'
}
Add-Type -AssemblyName System.Net.Http
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Write-Host ('runtime={0} clr={1}' -f $PSVersionTable.PSVersion, [Environment]::Version)
function Write-ProbeException {
    param([Exception]$Exception)
    $depth = 0
    while ($null -ne $Exception) {
        Write-Host ('exception_depth={0} type={1} message={2}' -f $depth, $Exception.GetType().FullName, ($Exception.Message -replace '[\r\n]+', ' '))
        $Exception = $Exception.InnerException
        $depth++
    }
}
$create = '$h = New-Object System.Net.Http.HttpClientHandler'
$disable = '$h.UseProxy = $false'
$enable = '$h.UseProxy = $true'
$original = '$h.Proxy = New-Object System.Net.WebProxy(''http://127.0.0.1:18888'')'
$variants = [ordered]@{
    A = @($create, $disable, $original, $enable)
    B = @($create, $disable, '$proxy = [System.Net.WebProxy]::new([System.Uri]''http://127.0.0.1:18888'')', '$h.Proxy = $proxy', $enable)
    C = @($create, $original, $enable)
    D = @($create, $disable, '$h.Proxy = [System.Net.IWebProxy](New-Object System.Net.WebProxy(''http://127.0.0.1:18888''))', $enable)
    E = @($create, $disable, '$h.Proxy = New-Object System.Net.WebProxy(''http://us.thz.quest:18888'')', $enable)
}
$winner = $null
foreach ($name in $variants.Keys) {
    $h = $proxy = $null
    $passed = $true
    $lineNumber = 0
    try {
        foreach ($line in $variants[$name]) {
            $lineNumber++
            Write-Host "variant=$name line=$lineNumber code=$line"
            try {
                . ([scriptblock]::Create($line))
                Write-Host "variant=$name line=$lineNumber result=ok"
            } catch {
                $passed = $false
                Write-Host "variant=$name line=$lineNumber result=failed"
                Write-ProbeException $_.Exception
            }
        }
        if ($passed -and $null -ne $h.Proxy -and $h.UseProxy) {
            if ($null -eq $winner) { $winner = $name }
            Write-Host "variant=$name setup=PASS"
        } else { Write-Host "variant=$name setup=FAIL" }
    } finally { if ($h) { $h.Dispose() } }
}
if ($null -eq $winner) { throw 'No proxy setup variant passed.' }
# A passing baseline does not reproduce the reported production failure.
if ($winner -eq 'A') {
    Write-Warning 'Baseline A passed: production SetValueInvocationException was not reproduced; do not infer a root cause from this run.'
}
Write-Host "winner=$winner"
# Replay the winning setup, changing only the public proxy endpoint.
$proxyUrl = 'http://{0}:18888' -f ([Uri]$BaseUrl).DnsSafeHost
$h = $client = $response = $null
try {
    foreach ($line in $variants[$winner]) {
        $productionLine = $line.Replace('http://127.0.0.1:18888', $proxyUrl).Replace('http://us.thz.quest:18888', $proxyUrl)
        . ([scriptblock]::Create($productionLine))
    }
    $client = [System.Net.Http.HttpClient]::new($h)
    $client.Timeout = [TimeSpan]::FromSeconds(60)
    $response = $client.GetAsync($TestUri).GetAwaiter().GetResult()
    $null = $response.EnsureSuccessStatusCode()
    $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    if ($bytes.Length -le 0) { throw 'Proxy download returned zero bytes.' }
    Write-Host ('proxy={0} winner={1} bytes={2} transfer=PASS' -f $proxyUrl, $winner, $bytes.Length)
} catch {
    Write-ProbeException $_.Exception
    throw
} finally {
    if ($response) { $response.Dispose() }
    if ($client) { $client.Dispose() }
    if ($h) { $h.Dispose() }
}
