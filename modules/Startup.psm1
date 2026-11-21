# Gerenciar o que abre junto com o Windows, sem sair do AgenteTI. Desativar aqui é exatamente o que o Gerenciador de
# Tarefas e as Configurações fazem, então o item continua listado neles e pode ser reativado em qualquer lugar:
# - chaves Run e pastas Inicializar: o valor binário de 12 bytes em StartupApproved (a entrada Run e o atalho ficam
#   intactos; nada é apagado);
# - aplicativos da Store (Teams, Spotify, WhatsApp...): o State da tarefa de inicialização do pacote (1 = desativado
#   pela pessoa, 2 = ativado), como as Configurações gravam;
# - tarefas agendadas de outros fabricantes que só rodam ao entrar no Windows ou ao ligar o PC: desativadas no
#   Agendador de Tarefas, de onde também podem ser reativadas.
# Depois de cada mudança, o estado é lido de novo no Windows: só conta como feito o que o Windows manteve. A lista mostra
# só o que o AgenteTI consegue mudar agora (veja Set-AgenteTIStartupItems); o texto na tela fica curto de propósito.

$script:AgenteTIStartupTaskSource = "Tarefa agendada"
$script:AgenteTIStartupAppSource = "Aplicativo da Store"


function New-AgenteTIStartupApprovedValue {
    # Os 12 bytes de StartupApproved: primeiro byte 02 = ativado; 03 = desativado, seguido da hora (FILETIME, 8 bytes)
    # em que foi desativado.
    param (
        [Parameter(Mandatory)]
        [bool]$Enabled,

        [datetime]$At = [datetime]::UtcNow
    )

    $bytes = New-Object byte[] 12

    if ($Enabled) {
        $bytes[0] = 2
        return , $bytes
    }

    $bytes[0] = 3
    $stamp = [BitConverter]::GetBytes([int64]$At.ToUniversalTime().ToFileTimeUtc())

    for ($i = 0; $i -lt 8; $i++) {
        $bytes[4 + $i] = $stamp[$i]
    }

    return , $bytes
}


function Set-AgenteTIStartupItemEnabled {
    # Liga ou desliga um item (objeto de Get-AgenteTIStartupItems). Itens de todos os usuários pedem Administrador.
    param (
        [Parameter(Mandatory)]
        $Item,

        [Parameter(Mandatory)]
        [bool]$Enabled
    )

    if ($Item.Scope -eq "Machine" -and -not (Test-AgenteTIAdministrator)) {
        throw "este item vale para todos os usuários e exige Administrador"
    }

    # Elevado com outra conta, o HKCU, a pasta Inicializar e as tarefas "da própria conta" são os dessa conta, não os da
    # pessoa logada: mudar ali seria mexer no perfil errado.
    if ($Item.Scope -eq "User" -and (Test-AgenteTIStartupOtherAccount)) {
        throw "este item vale só para uma conta, e o AgenteTI está elevado com outra conta"
    }

    if ([string]$Item.Source -eq $script:AgenteTIStartupTaskSource) {
        $taskPath = [string](Get-AgenteTIJsonValue -Object $Item -Name "TaskPath" -Default "\")
        $taskName = [string](Get-AgenteTIJsonValue -Object $Item -Name "TaskName" -Default $Item.Name)

        if ($Enabled) { [void](Enable-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop) }
        else { [void](Disable-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop) }

        return
    }

    if ([string]$Item.Source -eq $script:AgenteTIStartupAppSource) {
        $path = [string]$Item.ApprovedPath

        if (-not (Test-AgenteTIStartupAppPath -Path $path)) {
            throw "não foi possível localizar onde o Windows guarda o estado deste item"
        }

        # Confere antes de gravar: a tarefa pode ter sumido (o aplicativo foi desinstalado) ou passado para uma política
        # (3 e 4), que só o administrador muda; gravar por cima disso seria um ajuste de mentira.
        $current = Get-AgenteTIRegistryValueOrNull -Path $path -Name "State"

        if ($null -eq $current) { throw "o Windows não tem mais este item" }
        if (-not ($current -is [int]) -or @(0, 1, 2) -notcontains [int]$current) { throw "uma política do Windows controla este item" }

        # 1 = desativado pela pessoa, o mesmo que o Gerenciador de Tarefas grava: o aplicativo não consegue se religar
        # sozinho. 2 = ativado.
        Set-AgenteTIRegistryDWord -Path $path -Name "State" -Value $(if ($Enabled) { 2 } else { 1 })

        return
    }

    if ([string]::IsNullOrWhiteSpace($Item.ApprovedPath)) {
        throw "não foi possível localizar onde o Windows guarda o estado deste item"
    }

    Set-AgenteTIRegistryBinary -Path $Item.ApprovedPath -Name $Item.Name -Value (New-AgenteTIStartupApprovedValue -Enabled $Enabled)
}


function Test-AgenteTIStartupAppPath {
    # Se o caminho é a chave de uma tarefa de inicialização de aplicativo da Store (SystemAppData\<família>\<tarefa>) da
    # conta. O Histórico de mudanças guarda o caminho num arquivo que qualquer programa da conta grava: só isto é aceito.
    param ([AllowEmptyString()][string]$Path)

    $root = "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\"
    $text = [string]$Path

    if (-not $text.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }

    return ($text.Substring($root.Length) -match '^[^\\]+\\[^\\]+$')
}


function Test-AgenteTIStartupOtherAccount {
    # Se o AgenteTI está elevado com uma conta diferente da que está logada no Windows.
    try {
        return [bool](Get-AgenteTIJsonValue -Object (Get-AgenteTISessionInfo) -Name "UserMismatch" -Default $false)
    }
    catch {
        return $false
    }
}


function Get-AgenteTIStartupItemEnabled {
    <#
    Lê no Windows se um item está ligado, procurando só ele: a tarefa pelo caminho e pelo nome (duas tarefas podem ter o
    mesmo nome em pastas diferentes), o aplicativo da Store pela chave da tarefa dele e os demais pelo valor deles em
    StartupApproved (as pastas Inicializar do usuário e de todos os usuários têm a mesma origem, "Pasta Inicializar").
    $null quando não dá para ler.
    #>
    param (
        [Parameter(Mandatory)]
        $Item
    )

    if ([string]$Item.Source -eq $script:AgenteTIStartupTaskSource) {
        $taskPath = [string](Get-AgenteTIJsonValue -Object $Item -Name "TaskPath" -Default "\")
        $taskName = [string](Get-AgenteTIJsonValue -Object $Item -Name "TaskName" -Default $Item.Name)

        try {
            $task = @(Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop) | Select-Object -First 1
        }
        catch {
            return $null
        }

        if ($null -eq $task) {
            return $null
        }

        return ([string]$task.State -ne "Disabled")
    }

    # Aplicativo da Store: o State da tarefa (2 = ativado, 4 = ativado por política; o resto não abre).
    if ([string]$Item.Source -eq $script:AgenteTIStartupAppSource) {
        if (-not (Test-AgenteTIStartupAppPath -Path ([string]$Item.ApprovedPath))) { return $null }

        $state = Get-AgenteTIRegistryValueOrNull -Path ([string]$Item.ApprovedPath) -Name "State"

        if (-not ($state -is [int])) { return $null }

        return (@(2, 4) -contains [int]$state)
    }

    if ([string]::IsNullOrWhiteSpace([string]$Item.ApprovedPath)) {
        return $null
    }

    # Sem valor em StartupApproved, o Windows considera o item ligado; primeiro byte ímpar = desligado.
    $approved = Get-AgenteTIRegistryValues -Path $Item.ApprovedPath
    $name = [string]$Item.Name

    if (-not $approved.Contains($name)) {
        return $true
    }

    $bytes = @($approved[$name])

    return -not ($bytes.Count -gt 0 -and ([int]$bytes[0] -band 1) -eq 1)
}


function Get-AgenteTIStartupAccountKind {
    <#
    De quem é uma conta de tarefa agendada (o dono da tarefa ou o usuário de um gatilho de logon): "Current" (a conta
    que roda o AgenteTI), "Other" (outra pessoa deste PC ou do domínio: SID S-1-5-21-...) ou "Shared" (vazio, SYSTEM,
    serviços, grupos como Usuários).
    #>
    param (
        [AllowEmptyString()][string]$Account,
        [AllowEmptyString()][string]$User,
        [AllowEmptyString()][string]$Sid
    )

    $text = ([string]$Account).Trim()

    if (-not $text) { return "Shared" }

    if (($Sid -and $text -eq $Sid) -or ($User -and ($text -eq $User -or $text.EndsWith("\$User", [System.StringComparison]::OrdinalIgnoreCase)))) {
        return "Current"
    }

    $accountSid = $text

    if ($text -notmatch '^S-1-[0-9-]+$') {
        try {
            $accountSid = (New-Object System.Security.Principal.NTAccount -ArgumentList $text).Translate([System.Security.Principal.SecurityIdentifier]).Value
        }
        catch {
            $accountSid = ""
        }
    }

    if ($accountSid -like "S-1-5-21-*") {
        return $(if ($Sid -and $accountSid -eq $Sid) { "Current" } else { "Other" })
    }

    return "Shared"
}


function Get-AgenteTIStartupTasks {
    <#
    As tarefas agendadas que não são do Windows e rodam ao entrar no Windows (gatilho de logon) ou ao ligar o PC (gatilho
    de inicialização), no formato dos itens de Get-AgenteTIStartupItems, com TaskPath e TaskName. Sem acesso ao
    Agendador, nenhuma. Ficam de fora:
    - as da pasta \Microsoft\: são do próprio Windows;
    - as que também rodam em outros horários (todo dia, a cada hora...), como a maioria dos atualizadores: desativar a
      tarefa pararia tudo, não só a inicialização, e o programa deixaria de se atualizar. Já desativadas, continuam na
      lista, para poderem ser reativadas (também pelo Histórico de mudanças);
    - as de outra pessoa do PC (dona da tarefa ou única conta dos gatilhos de logon): mexer seria mudar o perfil dela;
    - as que abrem um arquivo que com certeza não existe mais: não abrem nada.
    Gatilhos desligados não contam.
    #>
    try {
        $tasks = @(Get-ScheduledTask -ErrorAction Stop)
    }
    catch {
        return @()
    }

    $user = [string]$env:USERNAME
    $sid = ""

    try { $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { $sid = "" }

    $items = @()

    foreach ($task in $tasks) {
        if ($null -eq $task) { continue }

        $path = [string]$task.TaskPath

        if ($path -like "\Microsoft\*") { continue }

        $atStart = @()
        $otherTriggers = 0
        $othersOnly = $true

        foreach ($trigger in @($task.Triggers | Where-Object { $null -ne $_ })) {
            if (-not [bool](Get-AgenteTIJsonValue -Object $trigger -Name "Enabled" -Default $true)) { continue }

            $class = ""
            try { $class = [string]$trigger.CimClass.CimClassName } catch { $class = "" }

            if ($class -ne "MSFT_TaskLogonTrigger" -and $class -ne "MSFT_TaskBootTrigger") {
                $otherTriggers++
                continue
            }

            $atStart += $trigger

            # Um gatilho de logon só de outra pessoa não abre nada quando esta conta entra.
            $triggerUser = [string](Get-AgenteTIJsonValue -Object $trigger -Name "UserId" -Default "")

            if ($class -eq "MSFT_TaskBootTrigger" -or (Get-AgenteTIStartupAccountKind -Account $triggerUser -User $user -Sid $sid) -ne "Other") {
                $othersOnly = $false
            }
        }

        if ($atStart.Count -eq 0 -or $othersOnly) { continue }

        $state = [string]$task.State

        if ($otherTriggers -gt 0 -and $state -ne "Disabled") { continue }

        $owner = ""
        try { $owner = [string]$task.Principal.UserId } catch { $owner = "" }
        $ownerKind = Get-AgenteTIStartupAccountKind -Account $owner -User $user -Sid $sid

        if ($ownerKind -eq "Other") { continue }

        $action = @($task.Actions | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string](Get-AgenteTIJsonValue -Object $_ -Name "Execute" -Default "")) }) | Select-Object -First 1
        $execute = $(if ($null -ne $action) { ([string]$action.Execute).Trim() } else { "" })
        $command = $(if ($null -ne $action) { ("$execute $([string](Get-AgenteTIJsonValue -Object $action -Name 'Arguments' -Default ''))").Trim() } else { "" })

        if ($execute -and (Test-AgenteTIStartupTargetMissing -Command ('"' + $execute.Trim('"') + '"'))) { continue }

        # Tarefa da própria conta: a pessoa consegue ligar e desligar sem Administrador; as demais pedem.
        $scope = $(if ($ownerKind -eq "Current") { "User" } else { "Machine" })

        $items += [PSCustomObject]@{
            Name = [string]$task.TaskName; Source = $script:AgenteTIStartupTaskSource; Enabled = ($state -ne "Disabled")
            Command = $command; Scope = $scope; ApprovedPath = ""; TaskPath = $path; TaskName = [string]$task.TaskName
        }
    }

    return @($items)
}


function Get-AgenteTIStartupPublisher {
    # Quem publica o programa de um item (CompanyName do executável): "Google LLC", "Microsoft Corporation". Vazio se não
    # der para saber. Atalhos da pasta Inicializar são seguidos até o programa.
    param ([Parameter(Mandatory)]$Item)

    try {
        $command = [string]$Item.Command

        if ([string]$Item.Source -eq "Pasta Inicializar" -and $command -like "*.lnk") {
            $link = Get-AgenteTIShortcutTarget -Path $command
            $command = $(if ($null -ne $link) { [string]$link.TargetPath } else { "" })
        }

        $path = Get-AgenteTICommandTargetPath -Command $command

        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return "" }

        return ([string](Get-Item -LiteralPath $path -ErrorAction Stop).VersionInfo.CompanyName).Trim()
    }
    catch {
        return ""
    }
}


function Get-AgenteTIStartupAdvice {
    <#
    O conselho que vai na descrição de um item quando a pessoa escolhe o que desativar: "antivírus; deixe ligado", "do
    Windows; melhor deixar ligado" (o programa fica na pasta do Windows) ou "do hardware do PC; na dúvida, deixe ligado"
    (som, touchpad, vídeo: os fabricantes mais comuns). "" para os outros.
    #>
    param ([Parameter(Mandatory)]$Item)

    $publisher = [string](Get-AgenteTIJsonValue -Object $Item -Name "Publisher" -Default "")
    $name = [string](Get-AgenteTIJsonValue -Object $Item -Name "Name" -Default "")
    $who = "$publisher $name"

    if ($who -match '(?i)\b(Avast|AVG|Kaspersky|Norton|NortonLifeLock|Gen Digital|McAfee|ESET|Bitdefender|Avira|Trend Micro|Sophos|Malwarebytes|Panda Security|F-Secure|Webroot)\b') {
        return "antivírus; deixe ligado"
    }

    $windows = $(if (-not [string]::IsNullOrWhiteSpace($env:WINDIR)) { $env:WINDIR } else { [string]$env:SystemRoot })
    $command = ([Environment]::ExpandEnvironmentVariables([string](Get-AgenteTIJsonValue -Object $Item -Name "Command" -Default ""))).Trim().TrimStart('"')

    if (-not [string]::IsNullOrWhiteSpace($windows) -and $command.StartsWith($windows.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return "do Windows; melhor deixar ligado"
    }

    if ($publisher -match '(?i)\b(Realtek|Synaptics|ELAN|Intel|NVIDIA|Advanced Micro Devices|AMD|Dolby|Conexant|Cirrus Logic|Waves|Alps)\b') {
        return "do hardware do PC; na dúvida, deixe ligado"
    }

    return ""
}


function Get-AgenteTIStartupEntries {
    # Tudo o que abre com o Windows para a tela Gerenciar inicialização: os itens das chaves Run, das pastas Inicializar e
    # dos aplicativos da Store, as tarefas agendadas de logon e de inicialização e, em cada um, quem publica o programa
    # (Publisher; o dos aplicativos da Store já vem do manifesto do pacote).
    $entries = @(@(Get-AgenteTIStartupItems) + @(Get-AgenteTIStartupTasks) | Where-Object { $null -ne $_ })

    foreach ($entry in $entries) {
        if ([string](Get-AgenteTIJsonValue -Object $entry -Name "Publisher" -Default "")) { continue }

        $entry | Add-Member -NotePropertyName Publisher -NotePropertyValue (Get-AgenteTIStartupPublisher -Item $entry) -Force
    }

    return @($entries)
}


function ConvertTo-AgenteTIStartupUndoItem {
    # O que o Histórico de mudanças guarda de um item para devolvê-lo ao estado de antes (Enabled = como estava).
    param (
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][bool]$Enabled
    )

    return [ordered]@{
        Name         = [string]$Item.Name
        Source       = [string]$Item.Source
        Scope        = [string]$Item.Scope
        ApprovedPath = [string]$Item.ApprovedPath
        TaskPath     = [string](Get-AgenteTIJsonValue -Object $Item -Name "TaskPath" -Default "")
        TaskName     = [string](Get-AgenteTIJsonValue -Object $Item -Name "TaskName" -Default "")
        Enabled      = $Enabled
    }
}


function Test-AgenteTIStartupUndoable {
    <#
    Se o desfazer do Histórico de mudanças sabe devolver este item (o de ConvertTo-AgenteTIStartupUndoItem). Chaves Run,
    pastas Inicializar e tarefas, sim; um aplicativo da Store só quando o desfazer (Test-AgenteTIStartupUndoItem) aceitar
    a chave dele. Perguntar ao desfazer, em vez de supor, evita anotar um desfazer que depois falharia.
    #>
    param ([Parameter(Mandatory)]$Undo)

    if ([string]$Undo["Source"] -ne $script:AgenteTIStartupAppSource) { return $true }

    try {
        return [bool](Test-AgenteTIStartupUndoItem -Item ([PSCustomObject]$Undo))
    }
    catch {
        return $false
    }
}


function Get-AgenteTIStartupJournalText {
    # O texto da linha do Histórico de mudanças (Items: Name e Enabled, o estado novo): "Chat desativado", "2 itens
    # desativados: Chat e Nuvem" ou "1 desativado (Chat) e 1 reativado (Antigo)".
    param ([object[]]$Items = @())

    $off = @($Items | Where-Object { -not $_.Enabled } | ForEach-Object { [string]$_.Name })
    $on = @($Items | Where-Object { $_.Enabled } | ForEach-Object { [string]$_.Name })
    $all = @($off) + @($on)

    if ($all.Count -eq 1) { return "$($all[0]) $(if ($on.Count -gt 0) { 'reativado' } else { 'desativado' })" }
    if ($off.Count -gt 0 -and $on.Count -gt 0) { return (Get-AgenteTIStartupChangeText -Off $off -On $on -Names) }

    return "$($all.Count) itens $(if ($on.Count -gt 0) { 'reativados' } else { 'desativados' }): $(Join-AgenteTIList -Items $all)"
}


function Get-AgenteTIStartupFileName {
    # O arquivo que um item abre ("steam.exe"), para a lista dizer o que é quando não se sabe quem publica. "" sem
    # comando e nos atalhos da pasta Inicializar (o nome do item já é o do arquivo).
    param ([Parameter(Mandatory)]$Item)

    $command = ([string](Get-AgenteTIJsonValue -Object $Item -Name "Command" -Default "")).Trim()

    if (-not $command -or [string]$Item.Source -eq "Pasta Inicializar") { return "" }

    $target = Get-AgenteTICommandTargetPath -Command $command

    if (-not $target) {
        $target = $(if ($command.StartsWith('"')) { ($command.Substring(1) -split '"', 2)[0] } else { ($command -split '\s+', 2)[0] })
    }

    return ([string]($target -split '[\\/]')[-1]).Trim()
}


function Get-AgenteTIStartupOptionText {
    # A descrição curta de um item na lista de marcar: quem publica (ou o arquivo que abre), "todos os usuários" quando
    # vale para o PC inteiro e, quando pedido (-Advice), o conselho de deixar ligado o que é do Windows, de hardware ou
    # antivírus. De onde o item abre (chave Run, pasta, tarefa) fica fora da tela: não ajuda a decidir.
    param (
        [Parameter(Mandatory)]$Item,
        [bool]$IsAdmin = $true,
        [switch]$Advice
    )

    $parts = @()
    $publisher = [string](Get-AgenteTIJsonValue -Object $Item -Name "Publisher" -Default "")

    if ($publisher) { $parts += $publisher }
    else {
        $file = Get-AgenteTIStartupFileName -Item $Item
        if ($file) { $parts += $file }
    }

    if ($Item.Scope -eq "Machine") { $parts += "todos os usuários" }
    if ($Item.Scope -eq "Machine" -and -not $IsAdmin) { $parts += "exige Administrador" }

    if ($Advice) {
        $text = Get-AgenteTIStartupAdvice -Item $Item
        if ($text) { $parts = @($text) + $parts }
    }

    return ($parts -join " · ")
}


function Get-AgenteTIStartupChangeText {
    # "2 desativados e 1 reativado" (com -Names, também os nomes: "2 desativados (A e B) e 1 reativado (C)").
    param (
        [string[]]$Off = @(),
        [string[]]$On = @(),
        [switch]$Names
    )

    $parts = @()

    foreach ($side in @(@{ Items = @($Off | Where-Object { $_ }); One = "desativado"; Many = "desativados" }, @{ Items = @($On | Where-Object { $_ }); One = "reativado"; Many = "reativados" })) {
        if ($side.Items.Count -eq 0) { continue }

        $text = Format-AgenteTICount -Count $side.Items.Count -One $side.One -Many $side.Many
        if ($Names) { $text += " ($(Join-AgenteTIList -Items $side.Items))" }
        $parts += $text
    }

    return ($parts -join " e ")
}


function Read-AgenteTIStartupSide {
    <#
    O jeito da tela Gerenciar inicialização: primeiro se é para desativar ou reativar, depois a lista daquele lado, com
    nada marcado. Devolve as mudanças (Item e Enabled, o estado pedido) ou $null quando a pessoa desiste.
    #>
    param (
        [object[]]$Enabled = @(),
        [object[]]$Disabled = @(),
        [bool]$IsAdmin = $true
    )

    $options = @()

    if ($Enabled.Count -gt 0) {
        $options += @{ Key = "D"; Label = "Desativar itens"; Description = "o que não precisa abrir com o Windows"; Accent = $true }
    }

    if ($Disabled.Count -gt 0) {
        $options += @{ Key = "R"; Label = "Reativar itens"; Description = "o que foi desativado" }
    }

    $options += @{ Key = "X"; Label = "Cancelar"; Exit = $true }

    $answer = Read-AgenteTIChoice -Message "O que deseja fazer?" -Options $options -DefaultKey "X" -ShowMenu `
        -TextPrompt "Opção (D, R ou X; ENTER = cancelar)"

    $targetEnabled = $null
    $pool = @()

    if ($answer -ieq "D" -and $Enabled.Count -gt 0) {
        $targetEnabled = $false
        $pool = @($Enabled)
    }
    elseif ($answer -ieq "R" -and $Disabled.Count -gt 0) {
        $targetEnabled = $true
        $pool = @($Disabled)
    }

    if ($null -eq $targetEnabled) {
        return $null
    }

    # Na hora de desativar, o que é do Windows, de hardware ou antivírus vem dito no próprio item: é o que faz falta.
    $choices = @(
        for ($i = 0; $i -lt $pool.Count; $i++) {
            @{ Key = [string]$i; Label = $pool[$i].Name; Description = (Get-AgenteTIStartupOptionText -Item $pool[$i] -IsAdmin $IsAdmin -Advice:(-not $targetEnabled)); Selected = $false }
        }
    )

    $message = $(if ($targetEnabled) { "Marque os itens que devem voltar a abrir com o Windows" } else { "Marque os itens que NÃO devem mais abrir com o Windows" })
    $picked = Read-AgenteTIMultiSelect -Message $message -Options $choices

    if ($null -eq $picked -or @($picked).Count -eq 0) {
        return $null
    }

    return @(foreach ($key in @($picked)) { [PSCustomObject]@{ Item = $pool[[int]$key]; Enabled = $targetEnabled } })
}


function Read-AgenteTIStartupReview {
    <#
    A revisão do Otimizar: uma lista só, com o que abre hoje já marcado. Desmarcar desativa, marcar reativa. Antes de
    mudar, a tela diz o que deixa de abrir e o que volta, e pergunta. Devolve as mudanças (Item e Enabled) ou $null
    quando nada muda (a lista cancelada, nenhuma diferença ou a pessoa disse não).
    #>
    param (
        [object[]]$Items = @(),
        [bool]$IsAdmin = $true
    )

    $pool = @($Items)

    # No menu de texto não há o que desmarcar: os números digitados são a lista inteira do que fica marcado. O conselho
    # de deixar ligado o antivírus, o que é do Windows e os drivers vem no próprio item, não numa linha à parte.
    if (Test-AgenteTIGuiPrompts) {
        Write-AgenteTIStatus -Type Info -Message "Marcado abre com o Windows. Desmarque o que não precisa abrir junto."
    }
    else {
        Write-AgenteTIStatus -Type Info -Message "Com * é o que abre hoje. Digite os números de tudo o que deve abrir com o Windows: o que ficar de fora deixa de abrir. P deixa como está."
    }

    $choices = @(
        for ($i = 0; $i -lt $pool.Count; $i++) {
            @{ Key = [string]$i; Label = $pool[$i].Name; Description = (Get-AgenteTIStartupOptionText -Item $pool[$i] -IsAdmin $IsAdmin -Advice:([bool]$pool[$i].Enabled)); Selected = [bool]$pool[$i].Enabled }
        }
    )

    # Sem "Marcar todos": reativaria de uma vez tudo o que a pessoa já tinha desativado. Desmarcar tudo é uma resposta
    # (nada abre com o Windows): a lista volta vazia, e não $null.
    $picked = Read-AgenteTIMultiSelect -Message "O que deve abrir junto com o Windows" -Options $choices -NoSelectAll -AllowNone

    if ($null -eq $picked) {
        return $null
    }

    $changes = @(
        for ($i = 0; $i -lt $pool.Count; $i++) {
            $want = (@($picked) -contains [string]$i)
            if ($want -ne [bool]$pool[$i].Enabled) { [PSCustomObject]@{ Item = $pool[$i]; Enabled = $want } }
        }
    )

    if ($changes.Count -eq 0) {
        return $null
    }

    $off = @($changes | Where-Object { -not $_.Enabled } | ForEach-Object { [string]$_.Item.Name })
    $on = @($changes | Where-Object { $_.Enabled } | ForEach-Object { [string]$_.Item.Name })

    Write-Host ""
    if ($off.Count -gt 0) { Write-AgenteTIKeyValue -Label "Deixam de abrir" -Value (Join-AgenteTIList -Items $off) }
    if ($on.Count -gt 0) { Write-AgenteTIKeyValue -Label "Voltam a abrir" -Value (Join-AgenteTIList -Items $on) }
    Write-Host ""

    # Com algo deixando de abrir, a resposta padrão é Não: um número trocado no menu de texto não desativa a lista.
    if (-not (Confirm-AgenteTIAction "Aplicar estas mudanças na inicialização?" -DefaultKey $(if ($off.Count -gt 0) { "N" } else { "S" }))) {
        return $null
    }

    return @($changes)
}


function Set-AgenteTIStartupItems {
    <#
    Desativa ou reativa o que abre com o Windows. Sozinha, pergunta primeiro se é para desativar ou reativar e lista só
    os itens daquele lado. Com -Review (a etapa do Otimizar), mostra uma lista só, com o que abre hoje já marcado: o que
    for desmarcado deixa de abrir, e o que for marcado volta a abrir.
    #>
    param (
        [switch]$Review
    )

    $title = "Gerenciar inicialização"

    if ($Review) {
        $title = "Revisar o que abre com o Windows"
    }

    Enter-AgenteTIAction -Title $title

    $final = New-AgenteTIResult -Kind Ok -Title $title

    try {
        Write-Progress -Activity $title -Status "lendo o que abre com o Windows"

        try {
            $items = @(Get-AgenteTIStartupEntries | Sort-Object -Property Name)
        }
        finally {
            Write-Progress -Activity $title -Completed
        }

        # A lista mostra só o que o AgenteTI consegue mudar agora, para nenhuma marca ser de enfeite:
        # - elevado com outra conta, os itens de uma conta só (HKCU, pasta Inicializar, tarefas e aplicativos da conta) são
        #   os dessa conta, não os da pessoa logada: mudar ali seria mexer no perfil errado;
        # - sem Administrador, os de todos os usuários (HKLM, pasta Inicializar comum, tarefas do sistema) não podem ser
        #   gravados.
        # Nos dois casos, uma linha diz o que ficou de fora.
        $isAdmin = Test-AgenteTIAdministrator
        $hidden = ""

        if (Test-AgenteTIStartupOtherAccount) {
            if (@($items | Where-Object { $_.Scope -eq "User" }).Count -gt 0) {
                $hidden = "o AgenteTI está elevado com outra conta"
                $user = [string](Get-AgenteTIJsonValue -Object (Get-AgenteTISessionInfo) -Name "User" -Default "")
                Write-AgenteTIStatus -Type Warning -Message "O AgenteTI está elevado com outra conta ($user): só aparecem os itens de todos os usuários."
            }

            $items = @($items | Where-Object { $_.Scope -ne "User" })
        }

        if (-not $isAdmin) {
            $machine = @($items | Where-Object { $_.Scope -eq "Machine" }).Count

            if ($machine -gt 0) {
                $hidden = "os itens que abrem com o Windows exigem Administrador"
                Write-AgenteTIStatus -Type Info -Message "$(Format-AgenteTICount -Count $machine -One 'item de todos os usuários só aparece' -Many 'itens de todos os usuários só aparecem') com o AgenteTI aberto como Administrador."
            }

            $items = @($items | Where-Object { $_.Scope -ne "Machine" })
        }

        if ($items.Count -eq 0) {
            if ($hidden) {
                Exit-AgenteTIAction -Result (New-AgenteTIResult -Kind Skipped -Detail $hidden -Title $title)
                return
            }

            Write-AgenteTIStatus -Type Info -Message "Nenhum programa está configurado para abrir junto com o Windows."
            Exit-AgenteTIAction -Result (New-AgenteTIResult -Kind Skipped -Detail "nenhum programa abre com o Windows" -Title $title)
            return
        }

        $enabled = @($items | Where-Object { $_.Enabled })
        $disabled = @($items | Where-Object { -not $_.Enabled })

        # Desativar não remove o programa (ele continua instalado, e o item continua no Gerenciador de Tarefas e em
        # Configurações, Aplicativos, Inicialização, de onde também pode ser reativado); a tela não precisa explicar isso.
        Write-AgenteTIKeyValue -Label "Abrem com o Windows" -Value $enabled.Count
        Write-AgenteTIKeyValue -Label "Desativados" -Value $disabled.Count
        Write-Host ""

        if ($Review) {
            $changes = Read-AgenteTIStartupReview -Items $items -IsAdmin $isAdmin

            if ($null -eq $changes) {
                Write-AgenteTIStatus -Type Info -Message "Nada foi mudado."
                Exit-AgenteTIAction -Result (New-AgenteTIResult -Kind Skipped -Detail "você não mudou nada" -Title $title)
                return
            }
        }
        else {
            $changes = Read-AgenteTIStartupSide -Enabled $enabled -Disabled $disabled -IsAdmin $isAdmin

            if ($null -eq $changes) {
                Write-AgenteTIStatus -Type Warning -Message "Operação cancelada."
                Exit-AgenteTIAction -Result (New-AgenteTIResult -Kind Skipped -Detail "cancelado pelo usuário" -Title $title)
                return
            }
        }

        $changed = 0
        $problems = @()
        $doneItems = @()
        $changedOff = @()
        $changedOn = @()

        foreach ($change in @($changes)) {
            $item = $change.Item
            $targetEnabled = [bool]$change.Enabled
            $done = $(if ($targetEnabled) { "reativado" } else { "desativado" })

            try {
                Set-AgenteTIStartupItemEnabled -Item $item -Enabled $targetEnabled

                # Confere no Windows se o estado deste item (e não de outro com o mesmo nome) mudou de fato.
                $after = Get-AgenteTIStartupItemEnabled -Item $item

                if ($null -ne $after -and [bool]$after -eq $targetEnabled) {
                    $changed++
                    $undo = ConvertTo-AgenteTIStartupUndoItem -Item $item -Enabled (-not $targetEnabled)
                    $doneItems += [PSCustomObject]@{ Name = [string]$item.Name; Enabled = $targetEnabled; Undo = $undo; Undoable = (Test-AgenteTIStartupUndoable -Undo $undo) }
                    if ($targetEnabled) { $changedOn += [string]$item.Name } else { $changedOff += [string]$item.Name }
                    Write-AgenteTIStatus -Type Success -Message "$($item.Name): $done."
                }
                else {
                    $problems += [PSCustomObject]@{ Name = [string]$item.Name; Detail = "o Windows não manteve a mudança" }
                    Write-AgenteTIStatus -Type Error -Message "$($item.Name): o Windows não manteve a mudança."
                }
            }
            catch {
                $problems += [PSCustomObject]@{ Name = [string]$item.Name; Detail = $_.Exception.Message.TrimEnd('.') }
                Write-AgenteTIStatus -Type Error -Message "$($item.Name): $($_.Exception.Message.TrimEnd('.'))."
            }
        }

        Write-Host ""

        # "desativado" ou "reativado" quando a lista foi de um lado só (sempre, sem -Review); "mudado" quando a revisão
        # desativou uns e reativou outros.
        $sides = @(@($changes) | ForEach-Object { [bool]$_.Enabled } | Select-Object -Unique)
        $done = $(if ($sides.Count -gt 1) { "mudado" } elseif ($sides.Count -eq 1 -and $sides[0]) { "reativado" } else { "desativado" })

        if ($changed -gt 0) {
            # O que o Histórico de mudanças sabe desfazer vai numa linha com o desfazer; o resto (um item que o desfazer
            # recusaria, como um aplicativo da Store fora das chaves conhecidas), numa linha só de registro: um desfazer que
            # deixasse parte para trás diria que voltou tudo sem ter voltado.
            $undoable = @($doneItems | Where-Object { $_.Undoable })
            $plain = @($doneItems | Where-Object { -not $_.Undoable })

            if ($undoable.Count -gt 0) {
                [void](Add-AgenteTIChange -Action "Inicialização" -Text (Get-AgenteTIStartupJournalText -Items $undoable) -Undo @{ Kind = "startup"; Items = @($undoable | ForEach-Object { $_.Undo }) })
            }

            if ($plain.Count -gt 0) {
                [void](Add-AgenteTIChange -Action "Inicialização" -Text (Get-AgenteTIStartupJournalText -Items $plain))
            }

            $when = "Vale a partir da próxima vez que você entrar no Windows"
            Write-AgenteTIStatus -Type Info -Message $(if ($undoable.Count -gt 0) { "$when. Para desfazer, use Manutenção > Histórico de mudanças." } else { "$when." })
        }

        $total = @($changes).Count
        $names = Join-AgenteTIList -Items @($problems | ForEach-Object { $_.Name })

        if ($problems.Count -eq 0) {
            # A faixa diz o que mudou ("2 itens desativados"), em vez de só "Concluído com sucesso". Na janela, o título
            # leva o nome quando é um item só ("Spotify desativado"), e a frase diz quando vale.
            $detail = $(if ($done -eq "mudado") { Get-AgenteTIStartupChangeText -Off $changedOff -On $changedOn } elseif ($changed -eq 1) { "1 item $done" } else { "$changed itens ${done}s" })
            $final = New-AgenteTIResult -Kind Ok -Detail $detail -Title $title
            $headline = $(if ($done -ne "mudado" -and $changed -eq 1) { "$(@($changedOff) + @($changedOn) | Select-Object -First 1) $done" } else { $detail })
            [void](Set-AgenteTIResultView -Result $final -Headline $headline -Note "Vale a partir da próxima vez que você entrar no Windows.")
        }
        elseif ($changed -eq 0) {
            $detail = $(if ($total -eq 1) { "$names não foi ${done}: $($problems[0].Detail)" } else { "nenhum item foi ${done}: $names" })
            $final = New-AgenteTIResult -Kind Failed -Detail $detail -Title $title
        }
        else {
            $verbText = $(if ($problems.Count -eq 1) { "não foi $done" } else { "não foram ${done}s" })
            $final = New-AgenteTIResult -Kind Warning -Detail "$($problems.Count) de $total ${verbText}: $names" -Title $title
        }
    }
    catch {
        Write-AgenteTIStatus -Type Error -Message "Ocorreu um erro: $($_.Exception.Message)"
        $final = New-AgenteTIResult -Kind Failed -Detail $_.Exception.Message -Title $title
    }

    Exit-AgenteTIAction -Result $final
}


Export-ModuleMember -Function *
