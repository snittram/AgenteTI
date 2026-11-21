# Lista dos módulos do AgenteTI. Os pontos de entrada (AgenteTI.Console.ps1 e AgenteTI.Gui.ps1) e as
# ações que rodam dentro da janela leem este arquivo; assim a lista existe em um lugar só.
#
#   Common  - tudo o que as ações usam (importado em todos os contextos)
#   Console - menus de texto (apenas AgenteTI.Console.ps1)
#   Gui     - ponte entre a janela e as ações (apenas AgenteTI.Gui.ps1, na thread da janela)
@{
    Common  = @(
        'Core',
        'Console',
        'Shortcuts',
        'Shell',
        'Launcher',
        'AppUpdate',
        'Cleanup',
        'CleanupTools',
        'Repair',
        'Software',
        'Network',
        'NetworkTools',
        'Diagnostics',
        'WindowsUpdate',
        'Startup',
        'Hardware',
        'Security',
        'Reports',
        'Tweaks',
        'Backup',
        'WindowsFeatures',
        'PreinstalledApps',
        'Maintenance',
        'Schedule',
        'Catalog',
        'Journal',
        'WindowsSupport',
        'RegistryCleaner',
        'Performance',
        'Drivers',
        'Checkup',
        'Agent',
        'Navigation',
        'Home'
    )

    Console = @(
        'Menus'
    )

    Gui     = @(
        'GuiHost',
        'GuiDesign'
    )
}
