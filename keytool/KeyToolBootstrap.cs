using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
[assembly: AssemblyTitle("特好装 · DeepSeek Key 管理工具")]
[assembly: AssemblyVersion("1.0.0.0")]
public static class KeyToolBootstrap {
    [STAThread]
    public static int Main() {
        try {
            string script = LoadEmbeddedScript();
            string tempDir = Path.Combine(Path.GetTempPath(), "THZ-KeyTool-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(tempDir);
            string psPath = Path.Combine(tempDir, "KeyTool.ps1");
            // Write with BOM so PS 5.1 decodes Chinese correctly
            File.WriteAllText(psPath, script, new UTF8Encoding(true));
            string psExe = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
            var psi = new ProcessStartInfo(psExe, "-NoProfile -ExecutionPolicy Bypass -STA -File \"" + psPath + "\"");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = false;
            using (var p = Process.Start(psi)) { p.WaitForExit(); }
            try { Directory.Delete(tempDir, true); } catch {}
            return 0;
        } catch (Exception ex) {
            try {
                System.Windows.Forms.MessageBox.Show("启动失败：" + ex.Message, "特好装 · DeepSeek Key 管理工具",
                    System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Error);
            } catch {}
            return 1;
        }
    }
    static string LoadEmbeddedScript() {
        var asm = Assembly.GetExecutingAssembly();
        using (var s = asm.GetManifestResourceStream("KeyTool.ps1")) {
            if (s == null) throw new InvalidOperationException("嵌入脚本缺失");
            using (var r = new StreamReader(s, new UTF8Encoding(true))) { return r.ReadToEnd(); }
        }
    }
}
