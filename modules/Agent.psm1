# Monitor na bandeja: um ícone perto do relógio que fica de olho no PC e avisa quando algo pede atenção.
#
# O monitor é o AgenteTI.Agent.ps1, na pasta do AgenteTI. Ele começa com o Windows (uma entrada em Run, do usuário) e só
# lê: espaço no disco, proteção, reinício pendente, manutenção, suporte do Windows e programas desatualizados. Cada aviso
# aparece no máximo uma vez a cada tanto tempo (veja Get-AgenteTIAgentChecks) e pode ser pausado por 24 horas no menu do
# ícone. Este módulo tem as regras (o que avisar e quando) e o liga/desliga; o script cuida do ícone.

$script:AgenteTIAgentRunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$script:AgenteTIAgentRunName = "AgenteTI Monitor"
# Onde o Gerenciador de Tarefas (aba Inicializar) marca uma entrada de Run como desativada.
$script:AgenteTIAgentApprovedKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
$script:AgenteTIAgentStopEvent = "Local\AgenteTI.Agent.Stop"
# Quanto tempo esperar o monitor aparecer depois de pedir a abertura.
$script:AgenteTIAgentStartWaitSeconds = 8


function Get-AgenteTIAgentActionIds {
    # As ações que o monitor pede à janela: as do menu do ícone e as dos avisos. A janela só roda estas quando o pedido
    # chega de outra abertura (Receive-AgenteTIWindowRequest).
    # app.monitor (Configurar o monitor) só mostra a tela de escolha: nada muda sem um clique nela.
    return @("performance.boost", "cleanup.quick", "maintenance.checkup", "diagnostics.pending-reboot", "security.status", "diagnostics.windows-support", "updates.winget", "app.monitor")
}


function Get-AgenteTIAgentScriptPath {
    return (Join-Path (Get-AgenteTIAppRoot) "AgenteTI.Agent.ps1")
}


function Get-AgenteTIAgentStopEventName {
    return $script:AgenteTIAgentStopEvent
}


function Get-AgenteTIAgentCommandLine {
    # A linha que o Windows roda ao entrar: o PowerShell, oculto, com o script do monitor.
    $script = Get-AgenteTIAgentScriptPath

    return "$(ConvertTo-AgenteTICommandLineArgument -Value (Get-AgenteTIPowerShellPath)) -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File $(ConvertTo-AgenteTICommandLineArgument -Value $script)"
}


function Get-AgenteTIAgentRunState {
    <#
    Se o monitor começa com o Windows: On; Off (sem a entrada); Elsewhere (a entrada aponta para outra pasta do AgenteTI,
    ou para um script que não existe mais: a pasta mudou de lugar); Disabled (desativado no Gerenciador de Tarefas, aba
    Inicializar: o Windows não roda a entrada).
    #>
    $value = [string](Get-AgenteTIRegistryValueOrNull -Path $script:AgenteTIAgentRunKey -Name $script:AgenteTIAgentRunName)

    if ([string]::IsNullOrWhiteSpace($value)) { return "Off" }

    $script = Get-AgenteTIAgentScriptPath

    if ($value.IndexOf($script, [StringComparison]::OrdinalIgnoreCase) -lt 0 -or -not (Test-Path -LiteralPath $script -PathType Leaf)) {
        return "Elsewhere"
    }

    # O primeiro byte ímpar (03, 07) é "desativado"; par (02, 06) ou sem o valor, "ativado".
    $approved = Get-AgenteTIRegistryValueOrNull -Path $script:AgenteTIAgentApprovedKey -Name $script:AgenteTIAgentRunName

    $first = $(if ($null -ne $approved) { @($approved)[0] } else { $null })

    if ($first -is [byte] -and ($first -band 1) -eq 1) { return "Disabled" }

    return "On"
}


function Test-AgenteTIAgentEnabled {
    # Se o monitor de fato começa com o Windows (a entrada existe, aponta para esta pasta e não foi desativada).
    return ((Get-AgenteTIAgentRunState) -eq "On")
}


function Get-AgenteTIAgentProcesses {
    # Os processos do monitor que estão rodando agora nesta sessão do Windows (pela linha de comando). Lista vazia se não
    # der para ler. Os monitores de outras contas logadas (troca rápida de usuário) não são deste usuário: ligar, abrir e
    # desligar nunca mexem neles.
    try {
        $session = [System.Diagnostics.Process]::GetCurrentProcess().SessionId

        return @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction Stop |
                Where-Object { [string]$_.CommandLine -like "*AgenteTI.Agent.ps1*" -and [int](Get-AgenteTIJsonValue -Object $_ -Name "SessionId" -Default $session) -eq $session })
    }
    catch {
        return @()
    }
}


function Test-AgenteTIAgentStartBlocked {
    # Se o monitor não deve ser ligado nem aberto daqui: com a conta de outro Administrador, ele ficaria no perfil dessa
    # conta. Na janela elevada da própria conta, ele abre sem a elevação (Start-AgenteTIAgent).
    return [bool](Test-AgenteTIUserContextMismatch)
}


function Start-AgenteTIAgent {
    <#
    Abre o monitor agora (o próprio script recusa uma segunda cópia) e devolve se ele apareceu em alguns segundos. O monitor
    nunca roda como Administrador: aberto direto da janela elevada, ele herdaria a elevação até o fim da sessão (e o "Abrir
    o AgenteTI" do menu abriria a janela elevada sem perguntar). Por isso, da janela elevada, ele abre por um atalho
    (monitor.lnk, na pasta de dados) entregue ao Explorador, que o abre na sessão da pessoa, sem elevação. Quem chama
    confere Test-AgenteTIAgentStartBlocked. Uma falha ao pedir a abertura vira um erro em português.
    #>
    $arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File $(ConvertTo-AgenteTICommandLineArgument -Value (Get-AgenteTIAgentScriptPath))"

    try {
        if (Test-AgenteTIAdministrator) {
            $link = Join-Path (Get-AgenteTIDataPath) "monitor.lnk"
            [void](Save-AgenteTIShortcutFile -Path $link -Target (Get-AgenteTIPowerShellPath) -Arguments $arguments -WorkingDirectory (Get-AgenteTIAppRoot) -Description "Monitor do AgenteTI")
            Start-Process -FilePath "explorer.exe" -ArgumentList "`"$link`"" -ErrorAction Stop
        }
        else {
            Start-Process -FilePath (Get-AgenteTIPowerShellPath) -ArgumentList $arguments -WindowStyle Hidden -ErrorAction Stop
        }
    }
    catch {
        throw "o Windows não deixou abrir o monitor agora"
    }

    # O Explorador abre o atalho por conta própria, um instante depois: confere por alguns segundos se o monitor apareceu e
    # continuou aberto por 2 segundos. Um monitor que abriu elevado (o Explorador não fez a troca) fecha sozinho logo no
    # começo (AgenteTI.Agent.ps1), e aí a tela diz que ele abre com o Windows, e não "ligado".
    $seen = 0

    for ($i = 0; $i -lt ($script:AgenteTIAgentStartWaitSeconds * 2); $i++) {
        if (@(Get-AgenteTIAgentProcesses).Count -gt 0) { $seen++ } else { $seen = 0 }
        if ($seen -ge 4) { return $true }
        Start-Sleep -Milliseconds 500
    }

    return $false
}


function Stop-AgenteTIAgent {
    # Pede ao monitor que feche (pelo evento que ele escuta) e, se ele não fechar em alguns segundos, encerra o processo.
    try {
        $signal = [System.Threading.EventWaitHandle]::OpenExisting($script:AgenteTIAgentStopEvent)
        [void]$signal.Set()
        $signal.Dispose()
    }
    catch {
        Write-Verbose "O monitor não estava escutando: $($_.Exception.Message)"
    }

    for ($i = 0; $i -lt 10; $i++) {
        if (@(Get-AgenteTIAgentProcesses).Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 500
    }

    foreach ($process in @(Get-AgenteTIAgentProcesses)) {
        Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
    }

    # Um monitor aberto como Administrador não fecha a pedido de uma janela sem elevação: quem chama diz isso.
    return (@(Get-AgenteTIAgentProcesses).Count -eq 0)
}


function Enable-AgenteTIAgent {
    <#
    Grava a entrada em Run (e tira a marca de "desativado" do Gerenciador de Tarefas, se houver) e abre o monitor. Devolve
    "Open" (aberto agora, ou já estava), "Later" (pedido, mas o ícone não apareceu em alguns segundos: abre com o Windows),
    "Blocked" (com a conta de outro Administrador: só fica configurado) ou "StartFailed" (configurado, mas o Windows não
    deixou abrir agora). Sem conseguir gravar a entrada, lança um erro em português e nada muda.
    #>
    if (-not (Test-Path -LiteralPath (Get-AgenteTIAgentScriptPath) -PathType Leaf)) {
        throw "o arquivo AgenteTI.Agent.ps1 não está na pasta do AgenteTI"
    }

    # O Windows não roda uma entrada de Run com 260 caracteres ou mais.
    $line = Get-AgenteTIAgentCommandLine

    if ($line.Length -ge 260) {
        throw "o caminho da pasta do AgenteTI é longo demais para o Windows abrir o monitor sozinho; mova a pasta do AgenteTI para um caminho mais curto"
    }

    # -ErrorAction Stop nos dois: sem ele, uma chave que não pode ser criada só escrevia um erro do Windows (em inglês) na
    # tela, e a gravação seguinte falhava com outro.
    try {
        if (-not (Test-Path -LiteralPath $script:AgenteTIAgentRunKey)) {
            [void](New-Item -Path $script:AgenteTIAgentRunKey -Force -ErrorAction Stop)
        }

        Set-ItemProperty -LiteralPath $script:AgenteTIAgentRunKey -Name $script:AgenteTIAgentRunName -Value $line -Type String -ErrorAction Stop
    }
    catch {
        throw "o Windows não deixou gravar a entrada que faz o monitor abrir com o Windows"
    }

    # Desativado antes no Gerenciador de Tarefas, o Windows continuaria sem rodar a entrada.
    try { Remove-AgenteTIRegistryValue -Path $script:AgenteTIAgentApprovedKey -Name $script:AgenteTIAgentRunName } catch { Write-Verbose "Marca de inicialização: $($_.Exception.Message)" }

    # Um monitor aberto de outra pasta do AgenteTI (a cópia antiga) seguiria abrindo a janela antiga até sair do Windows.
    $running = @(Get-AgenteTIAgentProcesses)
    $script = Get-AgenteTIAgentScriptPath

    if ($running.Count -gt 0 -and @($running | Where-Object { ([string]$_.CommandLine).IndexOf($script, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0) { return "Open" }
    if (Test-AgenteTIAgentStartBlocked) { return "Blocked" }
    if ($running.Count -gt 0) { [void](Stop-AgenteTIAgent) }

    try {
        if (Start-AgenteTIAgent) { return "Open" }
    }
    catch {
        return "StartFailed"
    }

    return "Later"
}


function Remove-AgenteTIAgentStaleEntry {
    # Tira a entrada de início quando ela aponta para o script dado (a pasta antiga, que não existe mais). Devolve se tirou.
    param ([Parameter(Mandatory)][string]$ScriptPath)

    $value = [string](Get-AgenteTIRegistryValueOrNull -Path $script:AgenteTIAgentRunKey -Name $script:AgenteTIAgentRunName)

    if ([string]::IsNullOrWhiteSpace($value) -or $value.IndexOf($ScriptPath, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }

    Remove-AgenteTIRegistryValue -Path $script:AgenteTIAgentRunKey -Name $script:AgenteTIAgentRunName
    return $true
}


function Disable-AgenteTIAgent {
    # Devolve se o monitor fechou (ele pode ter sido aberto como Administrador e não aceitar o pedido desta janela). Sem
    # conseguir remover a entrada em Run, lança um erro em português e não fecha o ícone.
    try {
        Remove-AgenteTIRegistryValue -Path $script:AgenteTIAgentRunKey -Name $script:AgenteTIAgentRunName
    }
    catch {
        throw "o Windows não deixou remover a entrada que faz o monitor abrir com o Windows"
    }

    try { Remove-AgenteTIRegistryValue -Path $script:AgenteTIAgentApprovedKey -Name $script:AgenteTIAgentRunName } catch { Write-Verbose "Marca de inicialização: $($_.Exception.Message)" }

    return (Stop-AgenteTIAgent)
}


# ---------------------------------------------------------------------------
# Regras dos avisos
# ---------------------------------------------------------------------------

function Get-AgenteTIAgentChecks {
    # O que o monitor confere, de quanto em quanto tempo (minutos) e o intervalo mínimo entre dois avisos iguais (horas).
    # Heavy = leitura demorada, feita em segundo plano.
    return @(
        @{ Id = "disk"; EveryMinutes = 15; RepeatHours = 24; Heavy = $false },
        @{ Id = "reboot"; EveryMinutes = 60; RepeatHours = 24; Heavy = $false },
        @{ Id = "maintenance"; EveryMinutes = 360; RepeatHours = 168; Heavy = $false },
        @{ Id = "protection"; EveryMinutes = 60; RepeatHours = 12; Heavy = $true },
        @{ Id = "windows"; EveryMinutes = 1440; RepeatHours = 168; Heavy = $false },
        @{ Id = "programs"; EveryMinutes = 1440; RepeatHours = 72; Heavy = $true },
        @{ Id = "catalog"; EveryMinutes = 1440; RepeatHours = 0; Heavy = $true }
    )
}


function Get-AgenteTIAgentStatePath {
    return (Join-Path (Get-AgenteTIDataPath) "agent.json")
}


function Read-AgenteTIAgentState {
    # Quando cada conferência rodou e cada aviso apareceu pela última vez ({ Checked = @{id=data}; Shown = @{id=data} }).
    $state = @{ Checked = @{}; Shown = @{} }

    try {
        $document = (Read-AgenteTIStateFile -Path (Get-AgenteTIAgentStatePath)).Document
        if ($null -eq $document) { return $state }

        foreach ($section in @("Checked", "Shown")) {
            $values = Get-AgenteTIJsonValue -Object $document -Name $section -Default $null
            if ($null -eq $values) { continue }

            foreach ($property in $values.PSObject.Properties) {
                $at = [datetime]::MinValue
                if ([datetime]::TryParse([string]$property.Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$at)) {
                    $state[$section][$property.Name] = $at
                }
            }
        }
    }
    catch {
        Write-Verbose "Estado do monitor ilegível: $($_.Exception.Message)"
    }

    return $state
}


function Save-AgenteTIAgentState {
    param ([Parameter(Mandatory)][hashtable]$State)

    try {
        $document = [ordered]@{}

        foreach ($section in @("Checked", "Shown")) {
            $values = [ordered]@{}
            foreach ($key in @($State[$section].Keys | Sort-Object)) { $values[$key] = ([datetime]$State[$section][$key]).ToString("o", [System.Globalization.CultureInfo]::InvariantCulture) }
            $document[$section] = $values
        }

        Write-AgenteTIStateJson -Path (Get-AgenteTIAgentStatePath) -InputObject $document -Depth 4
    }
    catch {
        Write-Verbose "Não foi possível salvar o estado do monitor: $($_.Exception.Message)"
    }
}


function Test-AgenteTIAgentDue {
    # Se já passou o tempo desde a última vez (Last ausente = nunca). Uma data mais de um dia no futuro (o relógio estava
    # adiantado quando ela foi gravada) também conta como "na hora": senão o monitor ficaria calado até lá.
    param (
        $Last,
        [double]$Minutes,
        [datetime]$Now = (Get-Date)
    )

    if ($null -eq $Last -or [datetime]$Last -gt $Now.AddDays(1)) { return $true }

    return (($Now - [datetime]$Last).TotalMinutes -ge $Minutes)
}


function Get-AgenteTIAgentPausedUntil {
    # Até quando os avisos estão pausados, ou $null. A pausa é de 24 horas: um fim mais longe que isso (gravado com o
    # relógio adiantado) não vale, para o monitor não ficar calado por anos.
    param ([datetime]$Now = (Get-Date))

    $until = [string](Get-AgenteTISetting -Name "AgentPausedUntil" -Default "")
    $at = [datetime]::MinValue

    if ([string]::IsNullOrWhiteSpace($until) -or -not [datetime]::TryParse($until, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$at)) { return $null }

    if ($at -le $Now -or $at -gt $Now.AddHours(25)) { return $null }

    return $at
}


function Test-AgenteTIAgentPaused {
    param ([datetime]$Now = (Get-Date))

    return ($null -ne (Get-AgenteTIAgentPausedUntil -Now $Now))
}


function Set-AgenteTIAgentPause {
    # Pausa os avisos por algumas horas; Hours = 0 retoma.
    param ([int]$Hours = 24)

    $value = $(if ($Hours -gt 0) { (Get-Date).AddHours($Hours).ToString("o", [System.Globalization.CultureInfo]::InvariantCulture) } else { "" })
    [void](Set-AgenteTISetting -Name "AgentPausedUntil" -Value $value)
}


function Format-AgenteTIAgentPauseEnd {
    # Até quando a pausa vai, como a pessoa diz: "hoje, às 18:40", "amanhã, às 14:30" (uma pausa de 24 horas sempre
    # termina amanhã; "até 14:30" sozinho parecia hoje). Mais longe que isso, com a data: "09/11, às 08:00".
    param (
        [Parameter(Mandatory)][datetime]$Until,
        [datetime]$Now = (Get-Date)
    )

    $time = Format-AgenteTIDateTime -When $Until -Pattern 'HH:mm'

    if ($Until.Date -eq $Now.Date) { return "hoje, às $time" }
    if ($Until.Date -eq $Now.Date.AddDays(1)) { return "amanhã, às $time" }

    return "$(Format-AgenteTIDateTime -When $Until -Pattern 'dd/MM'), às $time"
}


function Get-AgenteTIAgentSortedAlerts {
    # Os avisos abertos na ordem em que o monitor os mostra: os mais graves (Warning) primeiro.
    param ([AllowEmptyCollection()][object[]]$Alerts = @())

    return @(@($Alerts | Where-Object { $null -ne $_ }) | Sort-Object @{ Expression = { if ($_.Level -eq "Warning") { 0 } else { 1 } } })
}


function Get-AgenteTIAgentTooltip {
    <#
    O texto do ícone ao passar o mouse. O Windows corta em 63 caracteres: um texto maior termina em "...".
    Antes da primeira leitura, "conferindo o PC"; com avisos, o mais grave pelo nome e quantos mais há; pausado, até quando.
    #>
    param (
        [AllowEmptyCollection()][object[]]$Alerts = @(),
        [bool]$FirstReading = $true,
        $PausedUntil = $null,
        [datetime]$Now = (Get-Date)
    )

    $sorted = @(Get-AgenteTIAgentSortedAlerts -Alerts $Alerts)

    $text = $(
        if ($null -ne $PausedUntil) { "AgenteTI: avisos pausados até $(Format-AgenteTIAgentPauseEnd -Until ([datetime]$PausedUntil) -Now $Now)" }
        elseif (-not $FirstReading) { "AgenteTI: conferindo o PC..." }
        elseif ($sorted.Count -eq 0) { "AgenteTI: nada pedindo atenção" }
        elseif ($sorted.Count -eq 1) { "AgenteTI: $($sorted[0].Title)" }
        else { "AgenteTI: $($sorted[0].Title) e mais $(Format-AgenteTICount -Count ($sorted.Count - 1) -One 'aviso' -Many 'avisos')" }
    )

    if ($text.Length -gt 63) { $text = $text.Substring(0, 60).TrimEnd() + "..." }

    return $text
}


function Get-AgenteTIAgentPauseNotice {
    # O balão que confirma a pausa: até quando e como retomar antes.
    param (
        [Parameter(Mandatory)][datetime]$Until,
        [datetime]$Now = (Get-Date)
    )

    return "O AgenteTI volta a avisar $(Format-AgenteTIAgentPauseEnd -Until $Until -Now $Now). Para retomar antes, use o menu do ícone."
}


function New-AgenteTIAgentAlert {
    param (
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Text,
        [string]$Action = "",
        [ValidateSet("Info", "Warning")][string]$Level = "Warning"
    )

    return [PSCustomObject]@{ Id = $Id; Title = $Title; Text = $Text; Action = $Action; Level = $Level }
}


function Get-AgenteTIAgentReading {
    <#
    Lê uma das conferências e devolve o aviso que ela pede, ou $null se está tudo bem. Nunca lança erro: uma leitura que
    falha não avisa nada (o monitor não pode virar uma fonte de alarmes falsos).
    #>
    param ([Parameter(Mandatory)][string]$Id)

    try {
        switch ($Id) {
            "disk" {
                $space = Get-AgenteTISystemDriveSpace
                if ($null -eq $space) { return $null }

                $level = Get-AgenteTIDiskSpaceLevel -FreeBytes $space.FreeBytes -TotalBytes $space.TotalBytes
                if ($level -notin @("Low", "Critical")) { return $null }

                # O disco pelo nome que a pessoa vê no Explorador (C:), e qual é: o do Windows.
                $drive = $(if ([string]$env:SystemRoot -match '^([A-Za-z]:)') { $Matches[1].ToUpperInvariant() } else { "C:" })

                return (New-AgenteTIAgentAlert -Id "disk" -Title "Pouco espaço no disco $drive" -Text "Restam $(Format-AgenteTIBytes -Bytes $space.FreeBytes) livres no disco do Windows ($drive). Clique para fazer uma limpeza rápida." -Action "cleanup.quick")
            }
            "reboot" {
                if (-not (Test-AgenteTIPendingReboot)) { return $null }

                return (New-AgenteTIAgentAlert -Id "reboot" -Title "Reinício pendente" -Text "O Windows espera o PC reiniciar para terminar uma atualização ou mudança. Clique para ver o motivo." -Action "diagnostics.pending-reboot" -Level Info)
            }
            "maintenance" {
                # A mesma conta do Início (Get-AgenteTILastCare): uma data no futuro não cala o lembrete. Registros que
                # existem, mas não puderam ser lidos, não viram "ainda não verificou": sem leitura, sem aviso.
                $latest = $null

                try { $latest = (Get-AgenteTILastCare -Strict).Latest }
                catch { return $null }

                if ($null -ne $latest -and ((Get-Date) - $latest).TotalDays -lt 30) { return $null }

                # Sem nenhuma verificação ainda, "faz mais de um mês" não seria verdade (como no Início: "ainda não verificado").
                $text = $(if ($null -eq $latest) { "O AgenteTI ainda não verificou este PC. Clique para verificar." } else { "Faz mais de um mês sem verificação. Clique para verificar o PC." })

                return (New-AgenteTIAgentAlert -Id "maintenance" -Title "Hora de cuidar do PC" -Text $text -Action "maintenance.checkup" -Level Info)
            }
            "protection" {
                $protection = Get-AgenteTISecurityStatus
                if ($null -eq $protection) { return $null }

                $antivirus = $protection.Antivirus

                if ($null -ne $protection.Threats -and @($protection.Threats).Count -gt 0) {
                    return (New-AgenteTIAgentAlert -Id "protection" -Title "Ameaça encontrada" -Text "O antivírus encontrou uma ameaça que ainda está ativa. Clique para ver." -Action "security.status")
                }

                if ($antivirus.Mode -eq "Off") {
                    return (New-AgenteTIAgentAlert -Id "protection" -Title "PC sem antivírus ativo" -Text "Nenhum antivírus está protegendo o PC. Clique para ver." -Action "security.status")
                }

                if ($antivirus.Mode -eq "Active" -and $antivirus.RealTime -eq $false) {
                    return (New-AgenteTIAgentAlert -Id "protection" -Title "Proteção em tempo real desligada" -Text "O Windows Defender não está vigiando os arquivos abertos. Clique para ver." -Action "security.status")
                }

                return $null
            }
            "windows" {
                $support = Get-AgenteTIWindowsSupportStatus
                $issue = Get-AgenteTIWindowsSupportIssue -Status $support

                if ($null -eq $issue -or $support.State -eq "Esu") { return $null }

                # Uma leitura que não confirmou o ESU não vira aviso: o monitor só avisa do que sabe.
                if ($support.State -eq "EsuAvailable" -and -not [bool](Get-AgenteTIJsonValue -Object $support -Name "EsuChecked" -Default $true)) { return $null }

                # Sem atualizações de segurança (o ponto grave da nota) o título diz isso; perto do fim, só "Suporte do Windows".
                $title = $(if ([int]$issue.Weight -ge 20) { "Windows sem atualizações de segurança" } else { "Suporte do Windows" })

                return (New-AgenteTIAgentAlert -Id "windows" -Title $title -Text "$($issue.Text). Clique para ver o que fazer." -Action "diagnostics.windows-support")
            }
            "programs" {
                # Numa conexão limitada (plano de dados) ou na bateria, o monitor não consulta a internet por conta própria.
                if ((Test-AgenteTIMeteredConnection) -or (Test-AgenteTIOnBattery)) { return $null }
                if (-not (Test-AgenteTIWinget)) { return $null }

                $upgrade = Invoke-AgenteTICapture -FilePath "winget" -Arguments @("upgrade", "--accept-source-agreements")

                if (Test-AgenteTIWingetNoUpgradeOutput -OutputText $upgrade.Text -ExitCode $upgrade.ExitCode) { return $null }

                $count = @(ConvertFrom-AgenteTIWingetTable -Lines $upgrade.Lines).Count
                if ($count -lt 3) { return $null }

                return (New-AgenteTIAgentAlert -Id "programs" -Title "Programas desatualizados" -Text "$(Format-AgenteTICount -Count $count -One 'programa tem' -Many 'programas têm') versão nova. Clique para atualizar." -Action "updates.winget" -Level Info)
            }
            "catalog" {
                if ((Test-AgenteTIMeteredConnection) -or (Test-AgenteTIOnBattery)) { return $null }
                if (Test-AgenteTICatalogStale -Days 7) { [void](Update-AgenteTICatalog) }
                return $null
            }
        }
    }
    catch {
        Write-Verbose "Monitor, ${Id}: $($_.Exception.Message)"
    }

    return $null
}


function Get-AgenteTIAgentDueChecks {
    # As conferências que já passaram da hora, separadas em leves (rodam na hora) e pesadas (em segundo plano).
    param (
        [Parameter(Mandatory)][hashtable]$State,
        [datetime]$Now = (Get-Date)
    )

    return @(Get-AgenteTIAgentChecks | Where-Object { Test-AgenteTIAgentDue -Last $State.Checked[$_.Id] -Minutes $_.EveryMinutes -Now $Now })
}


function Select-AgenteTIAgentAlerts {
    # Dos avisos lidos, os que podem aparecer agora: não pausados e não repetidos antes do intervalo da conferência.
    param (
        [AllowEmptyCollection()][object[]]$Alerts = @(),
        [Parameter(Mandatory)][hashtable]$State,
        [datetime]$Now = (Get-Date),
        [bool]$Paused = $false
    )

    if ($Paused) { return @() }

    $checks = @{}
    foreach ($check in (Get-AgenteTIAgentChecks)) { $checks[$check.Id] = $check }

    return @(
        foreach ($alert in @($Alerts | Where-Object { $null -ne $_ })) {
            $repeat = $(if ($checks.ContainsKey($alert.Id)) { [double]$checks[$alert.Id].RepeatHours } else { 24 })
            if (Test-AgenteTIAgentDue -Last $State.Shown[$alert.Id] -Minutes ($repeat * 60) -Now $Now) { $alert }
        }
    )
}


# ---------------------------------------------------------------------------
# Tela (Sobre o AgenteTI > Monitor na bandeja)
# ---------------------------------------------------------------------------

function Set-AgenteTIMonitor {
    $title = "Monitor na bandeja"

    Enter-AgenteTIAction -Title $title

    $final = New-AgenteTIResult -Kind Ok -Title $title

    try {
        $runState = Get-AgenteTIAgentRunState
        $enabled = ($runState -eq "On")
        $running = (@(Get-AgenteTIAgentProcesses).Count -gt 0)
        $mismatch = Test-AgenteTIAgentStartBlocked
        $pausedUntil = Get-AgenteTIAgentPausedUntil

        $startText = switch ($runState) {
            "On" { "sim" }
            "Elsewhere" { "não: foi ligado de outra pasta do AgenteTI; Ligar o monitor passa a usar esta" }
            "Disabled" { "não: desligado em Configurações, Aplicativos, Inicialização (ou no Gerenciador de Tarefas); Ligar o monitor religa" }
            default { "não" }
        }

        Write-AgenteTIKeyValue -Label "Começa com o Windows" -Value $startText
        Write-AgenteTIKeyValue -Label "Aberto agora" -Value $(if ($running) { "sim" } else { "não" })
        if ($null -ne $pausedUntil) { Write-AgenteTIKeyValue -Label "Avisos" -Value "pausados até $(Format-AgenteTIAgentPauseEnd -Until $pausedUntil)" }
        Write-Host ""

        # Os avisos: disco enchendo, proteção desligada, reinício ou manutenção faltando, Windows sem suporte e programas
        # desatualizados. Pelo menu do ícone dá para ver os avisos, verificar, acelerar e limpar o PC, ou pausar os avisos.
        Write-AgenteTIStatus -Type Info -Message "O monitor fica perto do relógio e avisa quando o PC precisa de cuidado; nada muda sem você clicar."

        # Com a conta de outro Administrador, ligar gravaria o monitor no perfil dele: não oferece.
        if ($mismatch) {
            Write-AgenteTIStatus -Type Warning -Message "O AgenteTI está aberto com a conta de outro Administrador. Para ligar ou desligar o monitor na sua conta, $(Get-AgenteTIUnelevatedHint)."
        }

        Write-Host ""

        $options = @()

        if ($mismatch) {
            # Só informa.
        }
        elseif ($enabled) {
            $options += @{ Key = "D"; Label = "Desligar o monitor"; Description = "Fecha o ícone e não abre mais com o Windows" }
            if (-not $running) { $options += @{ Key = "A"; Label = "Abrir agora"; Description = "Ele está configurado, mas não está aberto" } }
        }
        else {
            $options += @{ Key = "L"; Label = "Ligar o monitor"; Description = "Abre agora e passa a abrir com o Windows"; Accent = $true }
            if ($running -or $runState -ne "Off") { $options += @{ Key = "D"; Label = "Desligar o monitor"; Description = "Fecha o ícone e tira a entrada que sobrou" } }
        }

        # A pausa (do menu do ícone) também se desfaz daqui.
        if ($null -ne $pausedUntil -and -not $mismatch) {
            $options += @{ Key = "R"; Label = "Retomar os avisos"; Description = "Os avisos voltam na próxima conferência" }
        }

        $options += @{ Key = "X"; Label = "Voltar"; Exit = $true }

        $answer = Read-AgenteTIChoice -Message "O que deseja fazer?" -Options $options -DefaultKey "X" -ShowMenu -TextPrompt "Opção (0 ou Enter = voltar)"

        switch ($answer) {
            "L" {
                $open = Enable-AgenteTIAgent
                [void](Add-AgenteTIChange -Action "Monitor na bandeja" -Text "ligado (abre com o Windows)")

                if ($open -eq "Open") {
                    Write-AgenteTIStatus -Type Success -Message "Monitor ligado; se o ícone não aparecer, ele está na setinha (^) ao lado do relógio."
                    $final = Set-AgenteTIResultView -Result (New-AgenteTIResult -Kind Ok -Detail "monitor ligado" -Title $title) `
                        -Headline "Monitor ligado" -Note "Se o ícone não aparecer, ele está na setinha (^) ao lado do relógio."
                }
                elseif ($open -eq "Later") {
                    Write-AgenteTIStatus -Type Success -Message "Monitor ligado; o ícone aparece em instantes ou na próxima entrada no Windows."
                    $final = Set-AgenteTIResultView -Result (New-AgenteTIResult -Kind Ok -Detail "monitor ligado; o ícone aparece em instantes ou na próxima entrada no Windows" -Title $title) `
                        -Headline "Monitor ligado" -Note "O ícone aparece em instantes ou na próxima entrada no Windows."
                }
                else {
                    Write-AgenteTIStatus -Type Warning -Message "Monitor ligado, mas o Windows não deixou abri-lo agora: ele abre sozinho na próxima vez que você entrar no Windows."
                    $final = Set-AgenteTIResultView -Result (New-AgenteTIResult -Kind Warning -Detail "monitor ligado, mas não abriu agora; abre na próxima entrada no Windows" -Title $title) `
                        -Headline "Monitor ligado, mas não abriu agora" -Note "Ele abre sozinho na próxima vez que você entrar no Windows."
                }
            }
            "D" {
                $closed = Disable-AgenteTIAgent
                [void](Add-AgenteTIChange -Action "Monitor na bandeja" -Text "desligado")

                if ($closed) {
                    Write-AgenteTIStatus -Type Success -Message "Monitor desligado."
                    $final = Set-AgenteTIResultView -Result (New-AgenteTIResult -Kind Ok -Detail "monitor desligado" -Title $title) `
                        -Headline "Monitor desligado" -Note $(if ($running) { "O ícone fechou e não abre mais com o Windows." } else { "Ele não abre mais com o Windows." })
                }
                else {
                    Write-AgenteTIStatus -Type Warning -Message "O monitor não abre mais com o Windows, mas o ícone aberto não fechou: feche pelo menu dele, em Fechar o monitor."
                    $final = Set-AgenteTIResultView -Result (New-AgenteTIResult -Kind Warning -Detail "o ícone aberto não fechou; feche pelo menu dele" -Title $title) `
                        -Headline "O ícone do monitor não fechou" -Note "Ele não abre mais com o Windows; feche o ícone pelo menu dele, em Fechar o monitor."
                }
            }
            "A" {
                if (Start-AgenteTIAgent) {
                    Write-AgenteTIStatus -Type Success -Message "Monitor aberto; se o ícone não aparecer, ele está na setinha (^) ao lado do relógio."
                    $final = Set-AgenteTIResultView -Result (New-AgenteTIResult -Kind Ok -Detail "monitor aberto" -Title $title) `
                        -Headline "Monitor aberto" -Note "Se o ícone não aparecer, ele está na setinha (^) ao lado do relógio."
                }
                else {
                    Write-AgenteTIStatus -Type Warning -Message "O ícone não apareceu agora; ele abre sozinho na próxima entrada no Windows."
                    $final = Set-AgenteTIResultView -Result (New-AgenteTIResult -Kind Warning -Detail "o ícone não apareceu agora; abre na próxima entrada no Windows" -Title $title) `
                        -Headline "O ícone não apareceu agora" -Note "Ele abre sozinho na próxima vez que você entrar no Windows."
                }
            }
            "R" {
                Set-AgenteTIAgentPause -Hours 0
                Write-AgenteTIStatus -Type Success -Message "Avisos retomados."
                $final = Set-AgenteTIResultView -Result (New-AgenteTIResult -Kind Ok -Detail "avisos retomados" -Title $title) `
                    -Headline "Avisos retomados" -Note "Eles voltam na próxima conferência do monitor."
            }
            default {
                # Voltar sem mudar nada é "Cancelado", como nas outras telas de escolha; com a conta de outro Administrador não
                # havia o que escolher, então é "Nada a fazer", com o motivo.
                if ($mismatch) {
                    $final = New-AgenteTIResult -Kind Skipped -Detail "com a conta de outro Administrador, o monitor só muda com o AgenteTI aberto sem Administrador" -Title $title
                }
                else {
                    $final = New-AgenteTIResult -Kind Skipped -Detail "cancelado pelo usuário" -Title $title
                }
            }
        }
    }
    catch {
        Write-AgenteTIStatus -Type Error -Message "Não foi possível mudar o monitor: $($_.Exception.Message.TrimEnd('.'))."
        $final = New-AgenteTIResult -Kind Failed -Detail $_.Exception.Message.TrimEnd('.') -Title $title
    }

    Exit-AgenteTIAction -Result $final
}


Export-ModuleMember -Function *
