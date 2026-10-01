param(
    [Parameter(Mandatory = $true)]
    [string]$ExePath,

    [Parameter(Mandatory = $true)]
    [string]$Ticket
)

$ErrorActionPreference = 'Stop'

if ($Ticket -notmatch '^[A-Za-z0-9_-]{32,128}$') {
    throw 'Ticket must match ^[A-Za-z0-9_-]{32,128}$'
}

if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
    throw "Executable not found: $ExePath"
}

$ticketBytes = [System.Text.Encoding]::ASCII.GetBytes($Ticket)
$lengthBytes = [System.BitConverter]::GetBytes([int]$ticketBytes.Length)
$markerBytes = [System.Text.Encoding]::ASCII.GetBytes('THZTICKETV1!')
$bytesWritten = $ticketBytes.Length + $lengthBytes.Length + $markerBytes.Length
$stream = $null

try {
    $stream = New-Object System.IO.FileStream(
        $ExePath,
        [System.IO.FileMode]::Append,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )
    $stream.Write($ticketBytes, 0, $ticketBytes.Length)
    $stream.Write($lengthBytes, 0, $lengthBytes.Length)
    $stream.Write($markerBytes, 0, $markerBytes.Length)
    $stream.Flush()
}
finally {
    if ($null -ne $stream) {
        $stream.Dispose()
    }
}

Write-Host ("Wrote {0} bytes" -f $bytesWritten)
