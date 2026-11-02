Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()


$ErrorActionPreference = 'Stop'
$codexDir = Join-Path $env:USERPROFILE '.codex'
$configPath = Join-Path $codexDir 'config.toml'
$modelsPath = Join-Path $codexDir 'models.json'
$backupDir = Join-Path $codexDir '.thz-keytool-backup'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$modelsJson = '{"models":[{"slug":"deepseek-chat","display_name":"DeepSeek Chat","description":"DeepSeek Chat","default_reasoning_level":"high","supported_reasoning_levels":[{"effort":"high","description":"High reasoning effort"}],"shell_type":"shell_command","visibility":"list","minimal_client_version":"0.0.0","supported_in_api":true,"priority":1}]}'
$rootKeys = @('model', 'model_provider', 'preferred_auth_method', 'forced_login_method', 'model_reasoning_effort', 'model_catalog_json')

function Restore-Snapshot([string]$Snapshot) {
    foreach ($name in @('config.toml', 'models.json')) {
        $source = Join-Path $Snapshot $name
        $target = Join-Path $codexDir $name
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Copy-Item -LiteralPath $source -Destination $target -Force
        } elseif (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Force
        }
    }
}

function Remove-DeepSeekContent([string]$Text, [bool]$RemoveRoots) {
    $inSection = $false
    $skip = $false
    $kept = New-Object System.Text.StringBuilder
    # Keep each retained line, including its original line ending.
    foreach ($match in [regex]::Matches($Text, '[^\r\n]*(?:\r\n|\n|\r|$)')) {
        $line = $match.Value
        if ($line.Length -eq 0) { continue }
        if ($line -match '^\s*\[') {
            $inSection = $true
            $skip = $line -match '^\s*\[\s*model_providers\s*\.\s*deepseek\s*\]\s*(?:#.*)?$'
        }
        if ($skip) { continue }
        $trimmed = $line.Trim()
        if ($RemoveRoots -and -not $inSection -and -not $trimmed.StartsWith('#') -and $trimmed.Contains('=')) {
            $name = $trimmed.Substring(0, $trimmed.IndexOf('=')).Trim().Trim('"', "'")
            if ($rootKeys -contains $name) { continue }
        }
        [void]$kept.Append($line)
    }
    return $kept.ToString()
}

function Assert-RootKeys([string]$Text) {
    $seen = @{}
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -match '^\s*\[') { break }
        $trimmed = $line.Trim()
        if (-not $trimmed.StartsWith('#') -and $trimmed.Contains('=')) {
            $name = $trimmed.Substring(0, $trimmed.IndexOf('=')).Trim().Trim('"', "'")
            if ($seen.ContainsKey($name)) { throw '配置包含重复顶层键。' }
            $seen[$name] = $true
        }
    }
}

function Assert-ProviderFiles([string]$Config, [string]$Models) {
    $text = [IO.File]::ReadAllText($Config)
    Assert-RootKeys $text
    if ($text -notmatch '(?m)^\[model_providers\.deepseek\]\s*$' -or
        $text -notmatch '(?m)^base_url = "https://api\.deepseek\.com"\s*$' -or
        $text -notmatch '(?m)^env_key = "DEEPSEEK_API_KEY"\s*$') {
        throw '配置校验失败。'
    }
    $catalog = [IO.File]::ReadAllText($Models) | ConvertFrom-Json
    if (@($catalog.models | Where-Object { $_.slug -eq 'deepseek-chat' }).Count -ne 1) {
        throw '模型目录校验失败。'
    }
}

function Write-ProviderFiles {
    $existing = ''
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $existing = [IO.File]::ReadAllText($configPath)
    }
    Assert-RootKeys $existing
    $preserved = Remove-DeepSeekContent $existing $true
    $catalogPath = $modelsPath.Replace('\', '/').Replace('"', '\"')
    $root = @(
        'model = "deepseek-chat"',
        'model_provider = "deepseek"',
        'preferred_auth_method = "apikey"',
        'forced_login_method = "api"',
        'model_reasoning_effort = "high"',
        ('model_catalog_json = "' + $catalogPath + '"')
    ) -join "`n"
    $provider = @(
        '[model_providers.deepseek]',
        'name = "deepseek"',
        'base_url = "https://api.deepseek.com"',
        'wire_api = "responses"',
        'env_key = "DEEPSEEK_API_KEY"'
    ) -join "`n"
    $text = $root + "`n`n" + $preserved + "`n" + $provider + "`n"
    Assert-RootKeys $text
    $suffix = '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $configTemp = $configPath + $suffix
    $modelsTemp = $modelsPath + $suffix
    try {
        [IO.File]::WriteAllText($configTemp, $text, $utf8NoBom)
        [IO.File]::WriteAllText($modelsTemp, $modelsJson, $utf8NoBom)
        Assert-ProviderFiles $configTemp $modelsTemp
        Move-Item -LiteralPath $modelsTemp -Destination $modelsPath -Force
        Move-Item -LiteralPath $configTemp -Destination $configPath -Force
        Assert-ProviderFiles $configPath $modelsPath
    } finally {
        foreach ($temp in @($configTemp, $modelsTemp)) {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
        }
    }
}

function Set-DeepSeekConfiguration([string]$key) {
    $previousKey = [Environment]::GetEnvironmentVariable('DEEPSEEK_API_KEY', [EnvironmentVariableTarget]::User)
    $snapshotReady = $false
    try {
        [Environment]::SetEnvironmentVariable(
            'DEEPSEEK_API_KEY',
            $key,
            [EnvironmentVariableTarget]::User
        )
        [IO.Directory]::CreateDirectory($codexDir) | Out-Null
        # Stage the complete snapshot before replacing the durable rollback directory.
        $stage = Join-Path $codexDir ('.thz-keytool-snapshot-' + [Guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($stage) | Out-Null
        try {
            foreach ($name in @('config.toml', 'models.json')) {
                $source = Join-Path $codexDir $name
                if (Test-Path -LiteralPath $source -PathType Leaf) {
                    Copy-Item -LiteralPath $source -Destination (Join-Path $stage $name) -Force
                }
            }
            if (Test-Path -LiteralPath $backupDir) { Remove-Item -LiteralPath $backupDir -Recurse -Force }
            Move-Item -LiteralPath $stage -Destination $backupDir
            $snapshotReady = $true
        } finally {
            if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        }
        Write-ProviderFiles
    } catch {
        try {
            if ($snapshotReady) { Restore-Snapshot $backupDir }
        } finally {
            [Environment]::SetEnvironmentVariable('DEEPSEEK_API_KEY', $previousKey, [EnvironmentVariableTarget]::User)
        }
        throw '配置失败；已尝试恢复原配置和用户环境变量，请检查备份。'
    }
}

function Clear-DeepSeekConfiguration {
    [Environment]::SetEnvironmentVariable(
        'DEEPSEEK_API_KEY',
        $null,
        [EnvironmentVariableTarget]::User
    )
    # An empty snapshot also records that neither file existed before setup.
    if (Test-Path -LiteralPath $backupDir -PathType Container) {
        Restore-Snapshot $backupDir
        Remove-Item -LiteralPath $backupDir -Recurse -Force
    } elseif (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $text = [IO.File]::ReadAllText($configPath)
        $rootText = ($text -split '(?m)^\s*\[', 2)[0]
        $active = $rootText -match '(?m)^\s*(?:model_provider|"model_provider"|''model_provider'')\s*=\s*["'']deepseek["'']\s*(?:#.*)?$'
        $cleaned = Remove-DeepSeekContent $text $active
        $temp = $configPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
        try {
            [IO.File]::WriteAllText($temp, $cleaned, $utf8NoBom)
            Move-Item -LiteralPath $temp -Destination $configPath -Force
        } finally {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
        }
    }
}

function Show-KeyInputDialog {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = '配置 DeepSeek Key'
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(390, 145)

    $label = New-Object System.Windows.Forms.Label
    $label.Text = '请输入 DeepSeek Key：'
    $label.AutoSize = $true
    $label.Location = New-Object System.Drawing.Point(20, 20)
    $dialog.Controls.Add($label)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Location = New-Object System.Drawing.Point(20, 48)
    $textBox.Size = New-Object System.Drawing.Size(350, 25)
    $textBox.UseSystemPasswordChar = $true
    $dialog.Controls.Add($textBox)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = '确定'
    $okButton.Location = New-Object System.Drawing.Point(205, 92)
    $okButton.Size = New-Object System.Drawing.Size(75, 30)
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dialog.Controls.Add($okButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = '取消'
    $cancelButton.Location = New-Object System.Drawing.Point(295, 92)
    $cancelButton.Size = New-Object System.Drawing.Size(75, 30)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancelButton)

    $dialog.AcceptButton = $okButton
    $dialog.CancelButton = $cancelButton

    $dialog.Add_Shown({
        $textBox.Focus()
    })

    $result = $dialog.ShowDialog($mainForm)
    $value = $null

    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        $value = $textBox.Text.Trim()
    }

    $dialog.Dispose()
    return $value
}

$mainForm = New-Object System.Windows.Forms.Form
$mainForm.Text = '特好装 · DeepSeek Key 管理'
$mainForm.StartPosition = 'CenterScreen'
$mainForm.FormBorderStyle = 'FixedDialog'
$mainForm.MaximizeBox = $false
$mainForm.MinimizeBox = $true
$mainForm.ClientSize = New-Object System.Drawing.Size(320, 125)

$configureButton = New-Object System.Windows.Forms.Button
$configureButton.Text = '配置 Key'
$configureButton.Location = New-Object System.Drawing.Point(35, 38)
$configureButton.Size = New-Object System.Drawing.Size(115, 48)
$mainForm.Controls.Add($configureButton)

$clearButton = New-Object System.Windows.Forms.Button
$clearButton.Text = '清理 Key'
$clearButton.Location = New-Object System.Drawing.Point(170, 38)
$clearButton.Size = New-Object System.Drawing.Size(115, 48)
$mainForm.Controls.Add($clearButton)

$configureButton.Add_Click({
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $key = Show-KeyInputDialog

        if ($null -eq $key) {
            break
        }

        if ($key.StartsWith('sk-') -and $key.Length -ge 12) {
            try {
                Set-DeepSeekConfiguration $key
                [System.Windows.Forms.MessageBox]::Show(
                    $mainForm,
                    '配置成功！已保存到用户环境变量，并写入 Codex 配置文件。',
                    '配置成功',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                ) | Out-Null
            } catch {
                [System.Windows.Forms.MessageBox]::Show(
                    $mainForm,
                    '配置失败。请检查用户环境变量、Codex 配置文件及回滚备份后重试。',
                    '配置失败',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error
                ) | Out-Null
            } finally {
                $key = $null
            }

            break
        }

        [System.Windows.Forms.MessageBox]::Show(
            $mainForm,
            'Key 格式无效。请输入以“sk-”开头且长度不少于 12 个字符的 Key。',
            '输入错误',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$clearButton.Add_Click({
    $result = [System.Windows.Forms.MessageBox]::Show(
        $mainForm,
        '确定要删除已保存的 DeepSeek Key 吗？',
        '确认清理',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2
    )

    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        try {
            Clear-DeepSeekConfiguration
            [System.Windows.Forms.MessageBox]::Show(
                $mainForm,
                '已清理 Key。',
                '清理成功',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                $mainForm,
                '清理失败。请检查 Codex 配置文件及回滚备份后重试。',
                '清理失败',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    }
})

[System.Windows.Forms.Application]::Run($mainForm)
