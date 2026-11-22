// Instalador do AgenteTI: um único .exe com o ícone do aplicativo e todos os arquivos compactados dentro (recurso
// "payload.zip"). Gerado por tools\Build-Installer.ps1; compilado com o csc.exe do .NET Framework 4 (C# 5).
//
// Uso:
//   AgenteTI-Setup.exe                     instala com confirmação na tela
//   AgenteTI-Setup.exe /S                  instalação silenciosa (implantação pela rede, GPO, PDQ etc.)
//   AgenteTI-Setup.exe /S /D=C:\Pasta      instala em outra pasta
//   AgenteTI-Setup.exe /S /NODESKTOP       sem atalho na Área de Trabalho
//   Desinstalar.exe /UNINSTALL [/S]        remove (também disponível em Configurações > Aplicativos)
//
// Códigos de saída: 0 = sucesso, 1 = erro, 2 = cancelado pela pessoa.
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Windows.Forms;
using Microsoft.Win32;

static class Program
{
    const string AppName = "AgenteTI";
    const string AppId = "AgenteTI.App";
    const string Publisher = "AgenteTI";
    const string ShortcutName = "AgenteTI.lnk";
    const string UninstallerName = "Desinstalar.exe";
    const string MarkerFile = "AgenteTI.Gui.ps1";
    const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\AgenteTI";

    static bool silent;

    [STAThread]
    static int Main(string[] args)
    {
        bool uninstall = false;
        bool noDesktop = false;
        string targetDir = null;

        foreach (string raw in args)
        {
            string arg = raw.Trim();
            string upper = arg.ToUpperInvariant();

            if (upper == "/S" || upper == "/SILENT" || upper == "/VERYSILENT" || upper == "/QUIET") silent = true;
            else if (upper == "/UNINSTALL") uninstall = true;
            else if (upper == "/NODESKTOP") noDesktop = true;
            else if (upper.StartsWith("/D=")) targetDir = arg.Substring(3).Trim('"');
        }

        try
        {
            return uninstall ? Uninstall() : Install(targetDir, noDesktop);
        }
        catch (Exception ex)
        {
            Fail("Ocorreu um erro: " + ex.Message);
            return 1;
        }
    }

    // ---------------------------------------------------------------- instalação

    static int Install(string targetDir, bool noDesktop)
    {
        if (string.IsNullOrEmpty(targetDir))
        {
            targetDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), AppName);
        }

        targetDir = Path.GetFullPath(targetDir);

        if (!silent)
        {
            string text = "Instalar o AgenteTI " + BuildInfo.Version + " em:\n\n" + targetDir +
                          "\n\nSerão criados atalhos no Menu Iniciar" + (noDesktop ? "" : " e na Área de Trabalho") +
                          " de todos os usuários.\n\nSe o AgenteTI estiver aberto, feche-o antes de continuar.";

            if (Ask(text, MessageBoxIcon.Question) != DialogResult.Yes) return 2;
        }

        Directory.CreateDirectory(targetDir);
        string rootWithSlash = targetDir.TrimEnd('\\') + "\\";

        // Extrai os arquivos compactados dentro do próprio .exe.
        using (Stream payload = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"))
        {
            if (payload == null) throw new InvalidOperationException("o instalador está corrompido (pacote interno ausente).");

            using (ZipArchive zip = new ZipArchive(payload, ZipArchiveMode.Read))
            {
                foreach (ZipArchiveEntry entry in zip.Entries)
                {
                    string dest = Path.GetFullPath(Path.Combine(targetDir, entry.FullName));

                    // Proteção contra caminhos que saiam da pasta de destino ("..\").
                    if (!dest.StartsWith(rootWithSlash, StringComparison.OrdinalIgnoreCase)) continue;

                    if (entry.FullName.EndsWith("/") || entry.FullName.EndsWith("\\"))
                    {
                        Directory.CreateDirectory(dest);
                        continue;
                    }

                    Directory.CreateDirectory(Path.GetDirectoryName(dest));

                    try
                    {
                        entry.ExtractToFile(dest, true);
                    }
                    catch (IOException ex)
                    {
                        throw new IOException("não foi possível gravar " + entry.FullName +
                                              ". Feche o AgenteTI (e o monitor na bandeja) e tente de novo. Detalhe: " + ex.Message);
                    }
                }
            }
        }

        // O próprio instalador vira o desinstalador.
        string uninstaller = Path.Combine(targetDir, UninstallerName);
        string self = Assembly.GetExecutingAssembly().Location;
        if (!string.Equals(Path.GetFullPath(self), uninstaller, StringComparison.OrdinalIgnoreCase))
        {
            File.Copy(self, uninstaller, true);
        }

        // Atalhos para todos os usuários (mesma linha de comando que o AgenteTI.cmd e o Launcher.psm1 usam).
        string startMenu = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonPrograms), ShortcutName);
        CreateShortcut(startMenu, targetDir);

        if (!noDesktop)
        {
            CreateShortcut(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonDesktopDirectory), ShortcutName), targetDir);
        }

        RegisterUninstall(targetDir, uninstaller);

        if (!silent)
        {
            if (Ask("AgenteTI " + BuildInfo.Version + " instalado com sucesso.\n\nAbrir agora?", MessageBoxIcon.Information) == DialogResult.Yes)
            {
                // Abre pelo Explorador para a janela iniciar SEM administrador (como o atalho); ela pede elevação quando precisar.
                try { Process.Start("explorer.exe", "\"" + startMenu + "\""); } catch { }
            }
        }

        return 0;
    }

    static void RegisterUninstall(string targetDir, string uninstaller)
    {
        using (RegistryKey hklm = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
        using (RegistryKey key = hklm.CreateSubKey(UninstallKey))
        {
            key.SetValue("DisplayName", AppName);
            key.SetValue("DisplayVersion", BuildInfo.Version);
            key.SetValue("Publisher", Publisher);
            key.SetValue("DisplayIcon", Path.Combine(targetDir, @"assets\AgenteTI.ico"));
            key.SetValue("InstallLocation", targetDir);
            key.SetValue("InstallDate", DateTime.Now.ToString("yyyyMMdd"));
            key.SetValue("UninstallString", "\"" + uninstaller + "\" /UNINSTALL");
            key.SetValue("QuietUninstallString", "\"" + uninstaller + "\" /UNINSTALL /S");
            key.SetValue("NoModify", 1, RegistryValueKind.DWord);
            key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            key.SetValue("EstimatedSize", (int)(GetFolderSize(targetDir) / 1024), RegistryValueKind.DWord);
        }
    }

    // ---------------------------------------------------------------- desinstalação

    static int Uninstall()
    {
        string targetDir = Path.GetDirectoryName(Path.GetFullPath(Assembly.GetExecutingAssembly().Location));

        // Só apaga uma pasta que seja mesmo do AgenteTI (nunca a raiz do disco nem Arquivos de Programas).
        bool safeDir = File.Exists(Path.Combine(targetDir, MarkerFile)) &&
                       Path.GetPathRoot(targetDir).TrimEnd('\\') != targetDir.TrimEnd('\\') &&
                       !string.Equals(targetDir.TrimEnd('\\'), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);

        if (!silent)
        {
            string text = "Remover o AgenteTI de:\n\n" + targetDir +
                          "\n\nLogs, relatórios e backups em %LOCALAPPDATA%\\AgenteTI de cada usuário são mantidos.";
            if (Ask(text, MessageBoxIcon.Question) != DialogResult.Yes) return 2;
        }

        TryDelete(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonPrograms), ShortcutName));
        TryDelete(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonDesktopDirectory), ShortcutName));

        using (RegistryKey hklm = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
        {
            try { hklm.DeleteSubKeyTree(UninstallKey, false); } catch { }
        }

        if (safeDir)
        {
            // O .exe em execução não pode apagar a si mesmo: um cmd oculto termina o serviço após alguns segundos.
            ProcessStartInfo psi = new ProcessStartInfo("cmd.exe",
                "/c ping 127.0.0.1 -n 4 >nul & rmdir /s /q \"" + targetDir + "\"");
            psi.CreateNoWindow = true;
            psi.UseShellExecute = false;
            psi.WorkingDirectory = Path.GetTempPath();
            Process.Start(psi);
        }

        if (!silent)
        {
            MessageBox.Show("O AgenteTI foi removido.", "AgenteTI", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        return 0;
    }

    // ---------------------------------------------------------------- utilitários

    static DialogResult Ask(string text, MessageBoxIcon icon)
    {
        return MessageBox.Show(text, "Instalador do AgenteTI " + BuildInfo.Version, MessageBoxButtons.YesNo, icon);
    }

    static void Fail(string message)
    {
        if (silent)
        {
            try { Console.Error.WriteLine(message); } catch { }
        }
        else
        {
            MessageBox.Show(message, "Instalador do AgenteTI", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }

    static long GetFolderSize(string dir)
    {
        long size = 0;
        try
        {
            foreach (string file in Directory.GetFiles(dir, "*", SearchOption.AllDirectories))
            {
                size += new FileInfo(file).Length;
            }
        }
        catch { }
        return size;
    }

    static void CreateShortcut(string lnkPath, string targetDir)
    {
        // Aponta para o AgenteTI.exe (sem console): direto no powershell.exe, o Terminal do Windows 11 abriria uma
        // janela preta ao lado da janela do AgenteTI.
        string launcher = Path.Combine(targetDir, "AgenteTI.exe");
        string icon = Path.Combine(targetDir, @"assets\AgenteTI.ico");

        IShellLinkW link = (IShellLinkW)new CShellLink();
        link.SetPath(launcher);
        link.SetArguments("");
        link.SetWorkingDirectory(targetDir);
        link.SetIconLocation(File.Exists(icon) ? icon : launcher, 0);
        link.SetDescription("AgenteTI - manutenção, reparo e diagnóstico do Windows");
        link.SetShowCmd(1);

        // Mesmo identificador que a janela usa (Launcher.psm1): o botão fixado na barra de tarefas agrupa com ela.
        try
        {
            IPropertyStore store = (IPropertyStore)link;
            PropertyKey appIdKey = new PropertyKey(new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), 5);
            PropVariant value = PropVariant.FromString(AppId);
            store.SetValue(ref appIdKey, ref value);
            store.Commit();
            value.Clear();
        }
        catch { }

        Directory.CreateDirectory(Path.GetDirectoryName(lnkPath));
        ((IPersistFile)link).Save(lnkPath, true);
        Marshal.ReleaseComObject(link);
    }

    // ---------------------------------------------------------------- COM (atalhos .lnk)

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    class CShellLink { }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
    interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszFile, int cchMaxPath, IntPtr pfd, int fFlags);
        void GetIDList(out IntPtr ppidl);
        void SetIDList(IntPtr pidl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszName, int cchMaxName);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszDir, int cchMaxPath);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszArgs, int cchMaxPath);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
        void GetHotkey(out short pwHotkey);
        void SetHotkey(short wHotkey);
        void GetShowCmd(out int piShowCmd);
        void SetShowCmd(int iShowCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszIconPath, int cchIconPath, out int piIcon);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, int dwReserved);
        void Resolve(IntPtr hwnd, int fFlags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    interface IPropertyStore
    {
        void GetCount(out uint cProps);
        void GetAt(uint iProp, out PropertyKey pkey);
        void GetValue(ref PropertyKey key, out PropVariant pv);
        void SetValue(ref PropertyKey key, ref PropVariant pv);
        void Commit();
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct PropertyKey
    {
        public Guid fmtid;
        public uint pid;
        public PropertyKey(Guid f, uint p) { fmtid = f; pid = p; }
    }

    [StructLayout(LayoutKind.Explicit)]
    struct PropVariant
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr pointer;

        public static PropVariant FromString(string s)
        {
            PropVariant pv = new PropVariant();
            pv.vt = 31; // VT_LPWSTR
            pv.pointer = Marshal.StringToCoTaskMemUni(s);
            return pv;
        }

        public void Clear()
        {
            if (pointer != IntPtr.Zero) { Marshal.FreeCoTaskMem(pointer); pointer = IntPtr.Zero; }
        }
    }
}
