param(
    [string]$BaseUrl = 'https://thz.quest',
    [string]$OutDir = (Join-Path $PSScriptRoot 'dist'),
    [switch]$TestHook
)

$ErrorActionPreference = 'Stop'
$stage = Join-Path ([System.IO.Path]::GetTempPath()) ('thz-build-' + [Guid]::NewGuid().ToString('N'))

try {
    Write-Host "Creating stage directory: $stage"
    [System.IO.Directory]::CreateDirectory($stage) | Out-Null

    foreach ($name in @('Safety.cs', 'Bootstrap.cs', 'Runner.ps1', 'InstallerLibrary.ps1')) {
        $source = Join-Path $PSScriptRoot $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Required source file not found: $source"
        }

        Copy-Item -LiteralPath $source -Destination (Join-Path $stage $name)
    }

    Write-Host "Stamping BASE_URL in staged PowerShell resources"
    $baseUrlPattern = '\$BASE_URL\s*=\s*''[^'']*'''
    $escapedBaseUrl = $BaseUrl.Replace("'", "''")
    $baseUrlAssignment = '$BASE_URL=''' + $escapedBaseUrl + ''''
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    foreach ($name in @('Runner.ps1', 'InstallerLibrary.ps1')) {
        $path = Join-Path $stage $name
        $text = [System.IO.File]::ReadAllText($path)
        $matches = [System.Text.RegularExpressions.Regex]::Matches($text, $baseUrlPattern)

        if ($matches.Count -lt 1) {
            throw "BASE_URL assignment not found in $name"
        }

        $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{ param($match) return $baseUrlAssignment }
        $re = [regex]$baseUrlPattern
        $text = $re.Replace($text, $evaluator, 1, 0)
        [System.IO.File]::WriteAllText($path, $text, $utf8NoBom)
    }

    if ($TestHook) {
        Write-Host "Applying CI test hook to staged InstallerLibrary.ps1"
        $hookPath = Join-Path $stage 'InstallerLibrary.ps1'
        $hookText = [System.IO.File]::ReadAllText($hookPath)
        if ($hookText.Contains("`r`n")) { $hookEol = "`r`n" } else { $hookEol = "`n" }
        $hookLines = [System.Text.RegularExpressions.Regex]::Split($hookText, "\r?\n")
        $hookList = New-Object System.Collections.ArrayList
        $hookList.AddRange($hookLines) | Out-Null

        $anchorGui = '        $res=Show-DeepSeekKeyGuiDialog'
        $guiIdx = @()
        for ($i = 0; $i -lt $hookList.Count; $i++) { if ($hookList[$i] -ceq $anchorGui) { $guiIdx += $i } }
        if ($guiIdx.Count -ne 1) { throw "TestHook: expected 1 Show-DeepSeekKeyGuiDialog call site, found $($guiIdx.Count)" }
        $gi = $guiIdx[0]
        $assertLine = '    Assert-CodexConfigPaths -CodexHome $CodexHome -ConfigPath $ConfigPath -ModelsPath $ModelsPath'
        if ($hookList[$gi - 2] -cne $assertLine) { throw "TestHook: anchor context mismatch near Show-DeepSeekKeyGuiDialog" }

        $hookList[$gi] = '        if($hookMode){$res=@{Ok=$true;Key=$hookKey};$hookKey=$null}else{$res=Show-DeepSeekKeyGuiDialog}'

        $lenPrefix = '        if($key.Length -lt 12){[Windows.Forms.MessageBox]::Show('
        $lenIdx = @()
        for ($i = 0; $i -lt $hookList.Count; $i++) { if ($hookList[$i].StartsWith($lenPrefix)) { $lenIdx += $i } }
        if ($lenIdx.Count -ne 1) { throw "TestHook: expected 1 key-length check, found $($lenIdx.Count)" }
        $hookList[$lenIdx[0]] = $hookList[$lenIdx[0]].Replace($lenPrefix, '        if($key.Length -lt 12){if($hookMode){$key=$null;$hookKey=$null;throw ''KEY_INVALID''};[Windows.Forms.MessageBox]::Show(')

        $retryPrefix = '            $retry=[Windows.Forms.MessageBox]::Show('
        $nullLine = '            $key=$null'
        $valIdx = @()
        for ($i = 0; $i -lt $hookList.Count - 1; $i++) {
            if ($hookList[$i] -ceq $nullLine -and $hookList[$i + 1].StartsWith($retryPrefix)) { $valIdx += $i }
        }
        if ($valIdx.Count -ne 1) { throw "TestHook: expected 1 validation-failure site, found $($valIdx.Count)" }
        $hookList.Insert($valIdx[0] + 1, '            if($hookMode){throw ''KEY_VALIDATION_FAILED''}')

        $hookList.Insert($gi - 1, '    $hookMode=-not [string]::IsNullOrWhiteSpace($hookKey)')
        $hookList.Insert($gi - 1, '    $hookKey=[Environment]::GetEnvironmentVariable(''THZ_DEEPSEEK_KEY'')')

        $hookedText = [string]::Join($hookEol, $hookList.ToArray())
        [System.IO.File]::WriteAllText($hookPath, $hookedText, $utf8NoBom)
        Write-Host "TestHook applied: 4 edits"
    }

    Write-Host "Calculating embedded resource hashes"
    $runnerHash = (Get-FileHash -LiteralPath (Join-Path $stage 'Runner.ps1') -Algorithm SHA256).Hash.ToUpperInvariant()
    $libraryHash = (Get-FileHash -LiteralPath (Join-Path $stage 'InstallerLibrary.ps1') -Algorithm SHA256).Hash.ToUpperInvariant()

    $resourcesSource = 'public static partial class Bootstrap { static readonly System.Collections.Generic.Dictionary<string,string> Resources=new System.Collections.Generic.Dictionary<string,string> { {"Runner.ps1","' + $runnerHash + '"},{"InstallerLibrary.ps1","' + $libraryHash + '"} }; }'
    [System.IO.File]::WriteAllText(
        (Join-Path $stage 'Resources.cs'),
        $resourcesSource,
        $utf8NoBom
    )

    $csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) {
        throw "csc.exe not found: $csc"
    }

    Write-Host "Compiling THZ-Codex-Setup.exe"
    Push-Location $stage
    try {
        $compilerOutput = & $csc `
            '-target:winexe' `
            '-platform:anycpu' `
            '-r:System.Windows.Forms' `
            '-r:System.Drawing' `
            '-out:THZ-Codex-Setup.exe' `
            'Safety.cs' `
            'Bootstrap.cs' `
            'Resources.cs' `
            '-resource:Runner.ps1,Runner.ps1' `
            '-resource:InstallerLibrary.ps1,InstallerLibrary.ps1' 2>&1
        $compilerExitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if ($compilerExitCode -ne 0) {
        $compilerOutput | ForEach-Object { Write-Host $_ }
        Write-Error "Compilation failed with exit code $compilerExitCode"
        exit 1
    }

    if ($compilerOutput) {
        $compilerOutput | ForEach-Object { Write-Host $_ }
    }

    [System.IO.Directory]::CreateDirectory($OutDir) | Out-Null
    $outputExe = Join-Path $OutDir 'THZ-Codex-Setup.exe'

    Write-Host "Copying executable to: $outputExe"
    Copy-Item -LiteralPath (Join-Path $stage 'THZ-Codex-Setup.exe') -Destination $outputExe -Force

    Write-Host "Writing SHA256SUMS.txt"
    $outputHash = (Get-FileHash -LiteralPath $outputExe -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText(
        (Join-Path $OutDir 'SHA256SUMS.txt'),
        ($outputHash + '  THZ-Codex-Setup.exe' + [Environment]::NewLine),
        $utf8NoBom
    )

    Write-Host "Build completed successfully"
    exit 0
}
catch {
    Write-Error $_
    exit 1
}
finally {
    if (Test-Path -LiteralPath $stage) {
        Write-Host "Removing stage directory: $stage"
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
