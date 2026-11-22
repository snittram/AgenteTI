// AgenteTI.exe: abre a janela do AgenteTI sem nenhum console visível.
// No Windows 11, um atalho direto para o powershell.exe abre o Terminal do Windows, que ignora o -WindowStyle Hidden e
// deixa uma janela preta aberta. Este programa inicia o PowerShell sem console (CreateNoWindow).
// C# 5 (compilador do .NET Framework 4): sem interpolação de strings, sem "?." e afins.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("AgenteTI")]
[assembly: AssemblyDescription("AgenteTI - manutenção, reparo e diagnóstico do Windows")]

static class Launcher
{
    [STAThread]
    static int Main(string[] args)
    {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string guiScript = Path.Combine(root, "AgenteTI.Gui.ps1");

        if (!File.Exists(guiScript) || !File.Exists(Path.Combine(root, @"modules\Modules.psd1")))
        {
            MessageBox.Show("Faltam arquivos do AgenteTI na pasta:\n\n" + root + "\n\nReinstale o AgenteTI.",
                "AgenteTI", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        // O PowerShell de 64 bits: o Sysnative só existe para processos de 32 bits e leva ao System32 de verdade.
        string systemRoot = Environment.GetEnvironmentVariable("SystemRoot");

        if (string.IsNullOrEmpty(systemRoot))
        {
            systemRoot = @"C:\Windows";
        }

        string powershell = Path.Combine(systemRoot, @"Sysnative\WindowsPowerShell\v1.0\powershell.exe");

        if (!File.Exists(powershell))
        {
            powershell = Path.Combine(systemRoot, @"System32\WindowsPowerShell\v1.0\powershell.exe");
        }

        StringBuilder arguments = new StringBuilder("-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File ");
        arguments.Append(Quote(guiScript));

        foreach (string arg in args)
        {
            arguments.Append(' ').Append(Quote(arg));
        }

        ProcessStartInfo start = new ProcessStartInfo(powershell, arguments.ToString());
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        start.WorkingDirectory = root;

        try
        {
            Process.Start(start);
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show("Não foi possível abrir o AgenteTI: " + ex.Message,
                "AgenteTI", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    // Aspas no padrão do CommandLineToArgvW: barras antes de aspas são dobradas e a aspa interna vira \".
    static string Quote(string value)
    {
        if (value.Length > 0 && value.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0)
        {
            return value;
        }

        StringBuilder result = new StringBuilder("\"");
        int backslashes = 0;

        foreach (char c in value)
        {
            if (c == '\\')
            {
                backslashes++;
                continue;
            }

            if (c == '"')
            {
                result.Append('\\', backslashes * 2 + 1);
            }
            else
            {
                result.Append('\\', backslashes);
            }

            backslashes = 0;
            result.Append(c);
        }

        result.Append('\\', backslashes * 2);
        result.Append('"');
        return result.ToString();
    }
}
