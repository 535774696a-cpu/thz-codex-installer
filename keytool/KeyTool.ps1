Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

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
            [Environment]::SetEnvironmentVariable(
                'DEEPSEEK_API_KEY',
                $key,
                [EnvironmentVariableTarget]::User
            )

            [System.Windows.Forms.MessageBox]::Show(
                $mainForm,
                '配置成功！已保存到用户环境变量。',
                '配置成功',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null

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
        [Environment]::SetEnvironmentVariable(
            'DEEPSEEK_API_KEY',
            $null,
            [EnvironmentVariableTarget]::User
        )

        [System.Windows.Forms.MessageBox]::Show(
            $mainForm,
            '已清理 Key。',
            '清理成功',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
})

[System.Windows.Forms.Application]::Run($mainForm)
