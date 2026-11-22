// AgenteTI-Setup-<versão>.exe: instala e desinstala o AgenteTI.
// Os arquivos vêm do recurso "payload.zip" embutido pelo tools\Build-Installer.ps1; a versão vem do BuildInfo.cs gerado.
//
// Parâmetros:
//   /S, /SILENT, /VERYSILENT, /QUIET  sem perguntas nem mensagens (o código de saída diz o resultado)
//   /NODESKTOP                        não cria o atalho na Área de Trabalho
//   /D=<pasta>                        pasta de instalação (padrão: %ProgramFiles%\AgenteTI); deve ser o último parâmetro
//   /UNINSTALL                        remove o AgenteTI (é o que o Desinstalar.exe da pasta instalada executa)
//   /CLOSE=<pid>                      fecha o AgenteTI aberto nesse processo antes de gravar (atualização pelo app)
//   /RUN                              abre o AgenteTI ao terminar, sem perguntar
//
// Códigos de saída: 0 sucesso, 1 erro, 2 cancelado.
// C# 5 (compilador do .NET Framework 4): sem interpolação de strings, sem "?." e afins.
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("Instalador do AgenteTI")]
[assembly: AssemblyDescription("Instalador do AgenteTI")]

static class Program
{
    const string AppName = "AgenteTI";
    const string AppUserModelId = "AgenteTI.App";
    const string MarkerFile = "AgenteTI.Gui.ps1";
    const string LauncherFile = "AgenteTI.exe";
    const string UninstallerFile = "Desinstalar.exe";
    const string ShortcutFile = "AgenteTI.lnk";
    const string ShortcutDescription = "AgenteTI - manutenção, reparo e diagnóstico do Windows";
    const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\AgenteTI";

    static bool silent;
    static bool runAfter;

    [STAThread]
    static int Main(string[] args)
    {
        bool uninstall = false;
        bool desktop = true;
        string target = null;
        int closePid = 0;

        for (int i = 0; i < args.Length; i++)
        {
            string arg = args[i].Trim();
            string upper = arg.ToUpperInvariant();

            if (upper == "/S" || upper == "/SILENT" || upper == "/VERYSILENT" || upper == "/QUIET")
            {
                silent = true;
            }
            else if (upper == "/UNINSTALL")
            {
                uninstall = true;
            }
            else if (upper == "/NODESKTOP")
            {
                desktop = false;
            }
            else if (upper == "/RUN")
            {
                runAfter = true;
            }
            else if (upper.StartsWith("/CLOSE="))
            {
                int.TryParse(arg.Substring(7), out closePid);
            }
            else if (upper.StartsWith("/D="))
            {
                // Como no NSIS: /D= é o último parâmetro e pode ter espaços sem aspas.
                target = string.Join(" ", args, i, args.Length - i).Trim().Substring(3).Trim().Trim('"');
                break;
            }
        }

        try
        {
            if (closePid > 0)
            {
                CloseRunningApp(closePid);
            }

            if (uninstall)
            {
                return Uninstall();
            }

            if (string.IsNullOrEmpty(target))
            {
                target = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), AppName);
            }

            if (!Path.IsPathRooted(target))
            {
                Fail("informe a pasta completa em /D= (por exemplo, /D=C:\\Programas\\AgenteTI).");
                return 1;
            }

            return Install(Path.GetFullPath(target).TrimEnd('\\'), desktop);
        }
        catch (Exception ex)
        {
            Fail(ex.Message);
            return 1;
        }
    }

    // --- Instalação --------------------------------------------------------------------------------------------------

    static int Install(string dir, bool desktop)
    {
        if (IsProtectedFolder(dir))
        {
            Fail("a pasta " + dir + " não pode receber a instalação. Escolha uma pasta própria para o AgenteTI.");
            return 1;
        }

        // A desinstalação apaga a pasta inteira: nunca instalar por cima de uma pasta com outros arquivos.
        if (Directory.Exists(dir) && Directory.EnumerateFileSystemEntries(dir).Any() && !File.Exists(Path.Combine(dir, MarkerFile)))
        {
            Fail("a pasta " + dir + " já existe e não é uma instalação do AgenteTI. Escolha outra com /D=<pasta>.");
            return 1;
        }

        if (!Ask("Instalar o AgenteTI " + BuildInfo.Version + " em:\n\n" + dir + "\n\n" +
                 "Serão criados atalhos no Menu Iniciar" + (desktop ? " e na Área de Trabalho" : "") + " de todos os usuários.\n\n" +
                 "Se o AgenteTI estiver aberto, feche-o antes de continuar."))
        {
            return 2;
        }

        Directory.CreateDirectory(dir);
        ExtractPayload(dir);

        string self = Assembly.GetExecutingAssembly().Location;
        string uninstaller = Path.Combine(dir, UninstallerFile);

        if (!string.Equals(Path.GetFullPath(self), uninstaller, StringComparison.OrdinalIgnoreCase))
        {
            File.Copy(self, uninstaller, true);
        }

        string launcher = Path.Combine(dir, LauncherFile);
        string icon = Path.Combine(dir, @"assets\AgenteTI.ico");

        CreateShortcut(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonPrograms), ShortcutFile), launcher, dir, icon);

        if (desktop)
        {
            CreateShortcut(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonDesktopDirectory), ShortcutFile), launcher, dir, icon);
        }

        RegisterUninstall(dir, uninstaller, icon);

        // Aberto pelo Explorador, o AgenteTI roda com a conta de quem usa o PC, e não elevado como este instalador.
        if (runAfter || (!silent && Ask("AgenteTI " + BuildInfo.Version + " instalado com sucesso.\n\nAbrir agora?")))
        {
            Process.Start("explorer.exe", "\"" + launcher + "\"");
        }

        return 0;
    }

    // A atualização pelo próprio AgenteTI: o app inicia este instalador e passa o número do próprio processo. A ação de
    // atualizar termina logo depois de abrir o instalador, então a janela fecha sem a pergunta de "ação em andamento".
    // Só fecha um processo do PowerShell (o que hospeda o AgenteTI), nunca outro programa com o mesmo número.
    static void CloseRunningApp(int pid)
    {
        Process process;

        try
        {
            process = Process.GetProcessById(pid);
        }
        catch (ArgumentException)
        {
            return;
        }

        using (process)
        {
            string name = "";

            try { name = process.ProcessName; } catch { }

            if (!string.Equals(name, "powershell", StringComparison.OrdinalIgnoreCase))
            {
                return;
            }

            // Tempo para a ação de atualizar terminar e a janela ficar livre.
            Thread.Sleep(2000);

            if (process.HasExited)
            {
                return;
            }

            bool closing = false;

            try { closing = process.CloseMainWindow(); } catch { }

            // Sem janela (o menu de texto num Terminal), não há a quem pedir: espera pouco e encerra.
            if (!process.WaitForExit(closing ? 20000 : 3000))
            {
                try
                {
                    process.Kill();
                    process.WaitForExit(5000);
                }
                catch
                {
                }
            }
        }
    }

    static void ExtractPayload(string dir)
    {
        Stream payload = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip");

        if (payload == null)
        {
            throw new InvalidOperationException("o instalador está corrompido (pacote interno ausente).");
        }

        string root = dir + "\\";

        using (payload)
        using (ZipArchive zip = new ZipArchive(payload, ZipArchiveMode.Read))
        {
            foreach (ZipArchiveEntry entry in zip.Entries)
            {
                string relative = entry.FullName.Replace('/', '\\');
                string destination = Path.GetFullPath(Path.Combine(dir, relative));

                // Nenhum arquivo do pacote pode sair da pasta de instalação.
                if (!destination.StartsWith(root, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidOperationException("o instalador está corrompido (caminho inválido: " + entry.FullName + ").");
                }

                if (relative.EndsWith("\\"))
                {
                    Directory.CreateDirectory(destination);
                    continue;
                }

                Directory.CreateDirectory(Path.GetDirectoryName(destination));

                try
                {
                    entry.ExtractToFile(destination, true);
                }
                catch (Exception ex)
                {
                    if (ex is IOException || ex is UnauthorizedAccessException)
                    {
                        throw new IOException("não foi possível gravar " + destination +
                            ". Feche o AgenteTI (e o monitor na bandeja) e tente de novo. Detalhe: " + ex.Message, ex);
                    }

                    throw;
                }
            }
        }
    }

    static RegistryKey OpenMachineKey()
    {
        // A visão de 64 bits: o Painel de Controle lê dela em um Windows de 64 bits.
        RegistryView view = Environment.Is64BitOperatingSystem ? RegistryView.Registry64 : RegistryView.Default;
        return RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, view);
    }

    static void RegisterUninstall(string dir, string uninstaller, string icon)
    {
        using (RegistryKey machine = OpenMachineKey())
        using (RegistryKey key = machine.CreateSubKey(UninstallKey))
        {
            key.SetValue("DisplayName", AppName);
            key.SetValue("DisplayVersion", BuildInfo.Version);
            key.SetValue("Publisher", AppName);
            key.SetValue("DisplayIcon", icon);
            key.SetValue("InstallLocation", dir);
            key.SetValue("InstallDate", DateTime.Now.ToString("yyyyMMdd"));
            key.SetValue("UninstallString", "\"" + uninstaller + "\" /UNINSTALL");
            key.SetValue("QuietUninstallString", "\"" + uninstaller + "\" /UNINSTALL /S");
            key.SetValue("NoModify", 1, RegistryValueKind.DWord);
            key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            key.SetValue("EstimatedSize", (int)Math.Min(int.MaxValue, GetFolderSize(dir) / 1024), RegistryValueKind.DWord);
        }
    }

    static long GetFolderSize(string dir)
    {
        long total = 0;

        foreach (string file in Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories))
        {
            try { total += new FileInfo(file).Length; } catch { }
        }

        return total;
    }

    // --- Desinstalação -----------------------------------------------------------------------------------------------

    static int Uninstall()
    {
        string dir = null;

        using (RegistryKey machine = OpenMachineKey())
        using (RegistryKey key = machine.OpenSubKey(UninstallKey))
        {
            if (key != null)
            {
                dir = key.GetValue("InstallLocation") as string;
            }
        }

        if (string.IsNullOrEmpty(dir))
        {
            dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        }

        dir = Path.GetFullPath(dir).TrimEnd('\\');

        // Só apaga uma pasta que é de fato uma instalação do AgenteTI.
        if (IsProtectedFolder(dir) || !File.Exists(Path.Combine(dir, MarkerFile)))
        {
            Fail("não foi encontrada uma instalação do AgenteTI em " + dir + ".");
            return 1;
        }

        if (!Ask("Remover o AgenteTI de:\n\n" + dir + "\n\n" +
                 "Logs, relatórios e backups em %LOCALAPPDATA%\\AgenteTI de cada usuário são mantidos."))
        {
            return 2;
        }

        TryDelete(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonPrograms), ShortcutFile));
        TryDelete(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonDesktopDirectory), ShortcutFile));

        using (RegistryKey machine = OpenMachineKey())
        {
            machine.DeleteSubKeyTree(UninstallKey, false);
        }

        string self = Path.GetFullPath(Assembly.GetExecutingAssembly().Location);

        if (self.StartsWith(dir + "\\", StringComparison.OrdinalIgnoreCase))
        {
            // O Desinstalar.exe está dentro da pasta: quem apaga é um cmd que espera este processo terminar.
            ProcessStartInfo cleanup = new ProcessStartInfo("cmd.exe", "/c ping 127.0.0.1 -n 4 >nul & rmdir /s /q \"" + dir + "\"");
            cleanup.UseShellExecute = false;
            cleanup.CreateNoWindow = true;
            cleanup.WorkingDirectory = Path.GetTempPath();
            Process.Start(cleanup);
        }
        else
        {
            Directory.Delete(dir, true);
        }

        if (!silent)
        {
            MessageBox.Show("O AgenteTI foi removido.", Title(), MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        return 0;
    }

    // --- Utilidades --------------------------------------------------------------------------------------------------

    // Pastas que nunca podem ser a instalação (a desinstalação apaga a pasta inteira).
    static bool IsProtectedFolder(string dir)
    {
        string full = Path.GetFullPath(dir).TrimEnd('\\');

        if (string.Equals(full + "\\", Path.GetPathRoot(full), StringComparison.OrdinalIgnoreCase) || full.Length <= 3)
        {
            return true;
        }

        Environment.SpecialFolder[] folders = new Environment.SpecialFolder[]
        {
            Environment.SpecialFolder.ProgramFiles,
            Environment.SpecialFolder.ProgramFilesX86,
            Environment.SpecialFolder.Windows,
            Environment.SpecialFolder.System,
            Environment.SpecialFolder.UserProfile,
            Environment.SpecialFolder.DesktopDirectory,
            Environment.SpecialFolder.CommonDesktopDirectory,
            Environment.SpecialFolder.MyDocuments,
            Environment.SpecialFolder.LocalApplicationData,
            Environment.SpecialFolder.ApplicationData,
            Environment.SpecialFolder.CommonApplicationData
        };

        foreach (Environment.SpecialFolder folder in folders)
        {
            string path = Environment.GetFolderPath(folder);

            if (!string.IsNullOrEmpty(path) && string.Equals(full, path.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    static string Title()
    {
        return "Instalador do AgenteTI " + BuildInfo.Version;
    }

    static bool Ask(string message)
    {
        if (silent)
        {
            return true;
        }

        return MessageBox.Show(message, Title(), MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes;
    }

    static void Fail(string message)
    {
        if (!silent)
        {
            MessageBox.Show("Ocorreu um erro: " + message, Title(), MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
        }
    }

    // --- Atalhos (.lnk) com o AppUserModelID do AgenteTI ------------------------------------------------------------

    static void CreateShortcut(string path, string target, string workingDirectory, string icon)
    {
        IShellLinkW link = (IShellLinkW)new CShellLink();

        try
        {
            link.SetPath(target);
            link.SetWorkingDirectory(workingDirectory);
            link.SetDescription(ShortcutDescription);
            link.SetIconLocation(icon, 0);

            // O mesmo AppUserModelID da janela (modules\Launcher.psm1): o atalho e o "Fixar" se unem ao botão dela.
            IPropertyStore store = (IPropertyStore)link;
            PropertyKey key = new PropertyKey();
            key.FormatId = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
            key.PropertyId = 5;

            PropVariant value = PropVariant.FromString(AppUserModelId);

            try
            {
                Marshal.ThrowExceptionForHR(store.SetValue(ref key, ref value));
                Marshal.ThrowExceptionForHR(store.Commit());
            }
            finally
            {
                value.Clear();
            }

            Directory.CreateDirectory(Path.GetDirectoryName(path));
            ((IPersistFile)link).Save(path, true);
        }
        finally
        {
            Marshal.ReleaseComObject(link);
        }
    }

    [ComImport]
    [Guid("00021401-0000-0000-C000-000000000046")]
    class CShellLink
    {
    }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("000214F9-0000-0000-C000-000000000046")]
    interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder file, int maxPath, IntPtr findData, uint flags);
        void GetIDList(out IntPtr idList);
        void SetIDList(IntPtr idList);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder name, int maxName);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder dir, int maxPath);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string dir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder args, int maxPath);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
        void GetHotkey(out short hotkey);
        void SetHotkey(short hotkey);
        void GetShowCmd(out int showCmd);
        void SetShowCmd(int showCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder iconPath, int maxIconPath, out int iconIndex);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string iconPath, int iconIndex);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string relativePath, int reserved);
        void Resolve(IntPtr window, int flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string file);
    }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct PropertyKey
    {
        public Guid FormatId;
        public uint PropertyId;
    }

    // PROPVARIANT de texto (VT_LPWSTR) montado à mão; o PropVariantClear libera a cópia da string.
    [StructLayout(LayoutKind.Sequential)]
    struct PropVariant
    {
        public ushort ValueType;
        public ushort Reserved1;
        public ushort Reserved2;
        public ushort Reserved3;
        public IntPtr Pointer;
        public int Extra;

        public static PropVariant FromString(string value)
        {
            PropVariant variant = new PropVariant();
            variant.ValueType = 31;
            variant.Pointer = Marshal.StringToCoTaskMemUni(value);
            return variant;
        }

        public void Clear()
        {
            PropVariantClear(ref this);
        }

        [DllImport("ole32.dll", ExactSpelling = true)]
        static extern int PropVariantClear(ref PropVariant variant);
    }
}
