// AgenteTI.exe: abre a janela do AgenteTI sem nenhuma janela preta de console.
//
// Por que existe: no Windows 11 o console padrão é o Terminal do Windows, que ignora o "-WindowStyle Hidden" do
// PowerShell; um atalho que aponta direto para o powershell.exe deixa uma aba preta aberta ao lado da janela.
// Este .exe é um programa de janela (sem console) e inicia o PowerShell com CREATE_NO_WINDOW: nenhum console aparece.
// Gerado por tools\Build-Installer.ps1 e colocado na raiz da pasta do AgenteTI.
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
        string root = Path.GetDirectoryName(Path.GetFullPath(Assembly.GetExecutingAssembly().Location));
        string gui = Path.Combine(root, "AgenteTI.Gui.ps1");

        if (!File.Exists(gui) || !File.Exists(Path.Combine(root, @"modules\Modules.psd1")))
        {
            MessageBox.Show("Faltam arquivos do AgenteTI na pasta:\n\n" + root + "\n\nReinstale o AgenteTI.",
                            "AgenteTI", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        // O PowerShell de 64 bits (Sysnative só existe quando este processo roda em 32 bits).
        string windir = Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows";
        string powershell = Path.Combine(windir, @"Sysnative\WindowsPowerShell\v1.0\powershell.exe");
        if (!File.Exists(powershell)) powershell = Path.Combine(windir, @"System32\WindowsPowerShell\v1.0\powershell.exe");

        StringBuilder arguments = new StringBuilder("-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + gui + "\"");
        foreach (string arg in args)
        {
            arguments.Append(' ').Append(Quote(arg));
        }

        ProcessStartInfo psi = new ProcessStartInfo(powershell, arguments.ToString());
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = root;

        try
        {
            Process.Start(psi);
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show("Não foi possível abrir o AgenteTI: " + ex.Message, "AgenteTI", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    // Repassa argumentos extras com as aspas certas para a linha de comando do Windows.
    static string Quote(string value)
    {
        if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return value;
        return "\"" + value.Replace("\\\"", "\\\\\"").Replace("\"", "\\\"") + "\"";
    }
}
