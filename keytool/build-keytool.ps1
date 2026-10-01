$ErrorActionPreference = 'Stop'
param(
    [string]$OutDir = (Join-Path $PSScriptRoot 'dist')
)

$stage = Join-Path ([System.IO.Path]::GetTempPath()) ('thz-keytool-build-' + [Guid]::NewGuid().ToString('N'))

try {
    Write-Host "Creating stage directory: $stage"
    [System.IO.Directory]::CreateDirectory($stage) | Out-Null

    foreach ($name in @('KeyToolBootstrap.cs', 'KeyTool.ps1')) {
        $source = Join-Path $PSScriptRoot $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Required source file not found: $source"
        }
        Copy-Item -LiteralPath $source -Destination (Join-Path $stage $name)
    }

    # Verify PS1 syntax (PowerShell 5.1)
    $errors = $null
    [void][System.Management.Automation.PSParser]::Tokenize(
        (Get-Content -LiteralPath (Join-Path $stage 'KeyTool.ps1') -Raw),
        [ref]$errors
    )
    if ($errors.Count -gt 0) {
        foreach ($e in $errors) { Write-Error $e.Message }
        throw 'KeyTool.ps1 syntax validation failed.'
    }
    Write-Host 'KeyTool.ps1 syntax OK'

    $csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) {
        throw "csc.exe not found: $csc"
    }

    $fxDir = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
    $formsRef = Join-Path $fxDir 'System.Windows.Forms.dll'
    $drawingRef = Join-Path $fxDir 'System.Drawing.dll'

    Write-Host 'Compiling THZ-DeepSeek-KeyTool.exe'
    Push-Location $stage
    try {
        $compilerOutput = & $csc `
            '-target:winexe' `
            '-platform:anycpu' `
            "-r:$formsRef" `
            "-r:$drawingRef" `
            '-out:THZ-DeepSeek-KeyTool.exe' `
            'KeyToolBootstrap.cs' `
            '-resource:KeyTool.ps1,KeyTool.ps1' 2>&1
        $compilerExitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if ($compilerExitCode -ne 0) {
        $compilerOutput | ForEach-Object { Write-Host $_ }
        throw "Compilation failed with exit code $compilerExitCode"
    }

    [System.IO.Directory]::CreateDirectory($OutDir) | Out-Null
    $outputExe = Join-Path $OutDir 'THZ-DeepSeek-KeyTool.exe'
    Copy-Item -LiteralPath (Join-Path $stage 'THZ-DeepSeek-KeyTool.exe') -Destination $outputExe -Force

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $outputHash = (Get-FileHash -LiteralPath $outputExe -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText(
        (Join-Path $OutDir 'SHA256SUMS.txt'),
        ($outputHash + '  THZ-DeepSeek-KeyTool.exe' + [Environment]::NewLine),
        $utf8NoBom
    )

    Write-Host "Build completed successfully: $outputExe"
    exit 0
}
catch {
    Write-Error $_
    exit 1
}
finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
