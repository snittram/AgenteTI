# Console: cabeçalhos, mensagens padronizadas e perguntas.
# Na interface gráfica as perguntas viram botões e listas de marcação; no console, o texto de sempre.

# Respostas inválidas seguidas que uma pergunta do console aceita antes de desistir. Com a entrada redirecionada (um
# script, uma tarefa) o limite é curto: a entrada pode ter acabado. Com alguém digitando, errar não fecha nada; o teto
# alto só impede um laço sem fim.
$script:AgenteTIMaxInvalidAnswers = 10
$script:AgenteTIMaxTypedAnswers = 1000

# Resultado da ação em andamento: o que as ações registraram de forma explícita (Set-AgenteTIOutcome) e a contagem das
# mensagens de estado (Write-AgenteTIStatus). A janela e o modo de linha de comando leem isto quando a ação termina.
$script:AgenteTIOutcomeState = $null

# Ações inteiras que rodam dentro de um fluxo (Invoke-AgenteTINestedAction), como as etapas com você do Otimizar:
# quantas estão abertas agora e o resultado com que a mais recente terminou.
$script:AgenteTINestedDepth = 0
$script:AgenteTINestedResult = $null


# ---------------------------------------------------------------------------
# Aparência do console
# ---------------------------------------------------------------------------

function Get-AgenteTIConsoleWidth {
    try {
        if (Test-AgenteTIGuiMode) {
            # Na interface gráfica a largura vem do painel de saída (o host personalizado).
            $width = $Host.UI.RawUI.WindowSize.Width - 1
        }
        else {
            $width = [Console]::WindowWidth - 1
        }
    }
    catch {
        $width = 72
    }

    return [Math]::Min(96, [Math]::Max(60, $width))
}


function Get-AgenteTIWrapWidth {
    # Até que coluna uma linha do console pode ir antes de continuar embaixo, com recuo (o Windows continuaria na coluna 0,
    # embaixo dos números do menu). 0 = não quebrar: na janela (o resumo quebra sozinho), com a saída indo para um arquivo
    # ou quando a largura não pode ser lida.
    if (Test-AgenteTIGuiMode) {
        return 0
    }

    try {
        if ([Console]::IsOutputRedirected) {
            return 0
        }

        $width = [Console]::WindowWidth
        $buffer = [Console]::BufferWidth

        if ($buffer -gt 0 -and $buffer -lt $width) {
            $width = $buffer
        }

        if ($width -lt 40) {
            return 0
        }

        # Uma linha que ocupa a largura inteira já leva o cursor para a linha de baixo.
        return ($width - 1)
    }
    catch {
        return 0
    }
}


function Split-AgenteTIWrappedText {
    # Quebra um texto em linhas de no máximo -Width caracteres, nos espaços (uma palavra maior que a linha é cortada).
    param (
        [AllowEmptyString()]
        [string]$Text,

        [int]$Width
    )

    if ($Width -lt 1 -or $Text.Length -le $Width) {
        return $Text
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $current = ""

    foreach ($word in ($Text -split ' ')) {
        if ($word.Length -eq 0) { continue }

        while ($word.Length -gt $Width) {
            if ($current.Length -gt 0) { $lines.Add($current); $current = "" }
            $lines.Add($word.Substring(0, $Width))
            $word = $word.Substring($Width)
        }

        if ($current.Length -eq 0) {
            $current = $word
        }
        elseif ($current.Length + 1 + $word.Length -le $Width) {
            $current += " " + $word
        }
        else {
            $lines.Add($current)
            $current = $word
        }
    }

    if ($current.Length -gt 0 -or $lines.Count -eq 0) {
        $lines.Add($current)
    }

    return $lines.ToArray()
}


function Write-AgenteTIWrappedLine {
    <#
    Uma linha de texto com recuo. No console, o que passa da largura da janela continua na linha de baixo com o mesmo
    recuo (depois do -Prefix, como "[OK] "), em vez de voltar para a coluna 0. Na janela, sai igual, numa linha só.
    #>
    param (
        [AllowEmptyString()]
        [string]$Text,

        [int]$Indent = 2,

        [string]$Color = "Gray",

        [string]$Prefix = "",

        [string]$PrefixColor = "Gray"
    )

    $lead = " " * $Indent
    $hang = " " * ($Indent + $Prefix.Length)
    $width = Get-AgenteTIWrapWidth
    $lines = @($Text)

    if ($width -gt 0 -and ($hang.Length + $Text.Length) -gt $width) {
        $lines = @(Split-AgenteTIWrappedText -Text $Text -Width ([Math]::Max(20, $width - $hang.Length)))
    }

    if ($Prefix.Length -gt 0) {
        Write-Host ($lead + $Prefix) -ForegroundColor $PrefixColor -NoNewline
        Write-Host $lines[0] -ForegroundColor $Color
    }
    else {
        Write-Host ($lead + $lines[0]) -ForegroundColor $Color
    }

    for ($i = 1; $i -lt $lines.Count; $i++) {
        Write-Host ($hang + $lines[$i]) -ForegroundColor $Color
    }
}


function Test-AgenteTIUnicodeConsole {
    # Defina AGENTETI_ASCII=1 para forçar o modo ASCII em fontes/consoles sem caracteres de moldura.
    if ($env:AGENTETI_ASCII -eq "1") {
        return $false
    }

    if (Test-AgenteTIGuiMode) {
        return $true
    }

    try {
        return ([Console]::OutputEncoding.CodePage -eq 65001)
    }
    catch {
        return $false
    }
}


function Get-AgenteTIGlyphs {
    if (Test-AgenteTIUnicodeConsole) {
        return @{
            TL = [string][char]0x250C; TR = [string][char]0x2510
            BL = [string][char]0x2514; BR = [string][char]0x2518
            H  = [string][char]0x2500; V  = [string][char]0x2502
            Dot = [string][char]0x25CF; Sep = [string][char]0x203A
            Full = [string][char]0x2588; Empty = [string][char]0x2591
        }
    }

    return @{
        TL = "+"; TR = "+"; BL = "+"; BR = "+"
        H = "-"; V = "|"; Dot = "*"; Sep = ">"
        Full = "#"; Empty = "."
    }
}


function Show-AgenteTIHeader {
    param (
        [string]$Title
    )

    $glyphs = Get-AgenteTIGlyphs
    $width = Get-AgenteTIConsoleWidth
    # Cada linha ocupa $width colunas: o traço tem 2 de recuo; a caixa, 2 de recuo e as 2 bordas.
    $rule = $width - 2
    $inner = $width - 4

    if (Test-AgenteTIGuiMode) {
        # A janela já mostra o título da ação; aqui entra apenas um separador discreto, sem limpar a saída.
        if ($Title -ne "AgenteTI") {
            Write-Host ""
            Write-Host "  $Title" -ForegroundColor Cyan
            Write-Host ("  " + ($glyphs.H * $rule)) -ForegroundColor DarkCyan
            Write-Host ""
        }

        return
    }

    Clear-Host
    Write-Host ""

    if ($Title -eq "AgenteTI") {
        $titleText = "AgenteTI  $($glyphs.Dot)  Build $(Get-AgenteTIBuild)"
        $subtitleText = "Manutenção, diagnóstico e ajustes do Windows"

        Write-Host ("  " + $glyphs.TL + ($glyphs.H * $inner) + $glyphs.TR) -ForegroundColor DarkCyan
        Write-Host ("  " + $glyphs.V) -ForegroundColor DarkCyan -NoNewline
        Write-Host (("  " + $titleText).PadRight($inner)) -ForegroundColor Cyan -NoNewline
        Write-Host $glyphs.V -ForegroundColor DarkCyan
        Write-Host ("  " + $glyphs.V) -ForegroundColor DarkCyan -NoNewline
        Write-Host (("  " + $subtitleText).PadRight($inner)) -ForegroundColor DarkGray -NoNewline
        Write-Host $glyphs.V -ForegroundColor DarkCyan
        Write-Host ("  " + $glyphs.BL + ($glyphs.H * $inner) + $glyphs.BR) -ForegroundColor DarkCyan

        Write-AgenteTIStatusBar
    }
    else {
        Write-Host "  AgenteTI " -ForegroundColor DarkGray -NoNewline
        Write-Host "$($glyphs.Sep) " -ForegroundColor DarkCyan -NoNewline
        Write-Host $Title -ForegroundColor Cyan
        Write-Host ("  " + ($glyphs.H * $rule)) -ForegroundColor DarkCyan
    }

    Write-Host ""
}


function Write-AgenteTIStatusBar {
    $glyphs = Get-AgenteTIGlyphs
    $session = Get-AgenteTISessionInfo

    # O menu de texto só abre como Administrador: a marca aparece quando falta, e não o tempo todo.
    # O usuário e o Windows saem como no cartão do Início ("ana", "Windows 11 Home 24H2").
    $user = [string]$session.User
    $computer = $env:COMPUTERNAME
    if ([string]::IsNullOrWhiteSpace($computer)) { $computer = [Environment]::MachineName }

    if (Get-Command Get-AgenteTIUserDisplayName -ErrorAction SilentlyContinue) {
        $user = Get-AgenteTIUserDisplayName -Name $user -Computer $computer
    }

    $windows = [string](Get-AgenteTIJsonValue -Object $session -Name "WindowsName" -Default "")
    if ([string]::IsNullOrWhiteSpace($windows)) { $windows = [string]$session.WindowsLabel }

    $version = [string](Get-AgenteTIJsonValue -Object $session -Name "WindowsVersion" -Default "")
    if (-not [string]::IsNullOrWhiteSpace($version)) { $windows += " $version" }

    $items = @()

    if (-not $session.IsAdmin) {
        $items += [PSCustomObject]@{ Text = "Sem Administrador"; Color = "Yellow" }
    }

    $items += [PSCustomObject]@{ Text = $user; Color = $(if ($session.UserMismatch) { "Yellow" } else { "Gray" }) }
    $items += [PSCustomObject]@{ Text = $(if ($session.IsLaptop) { "Notebook" } else { "Desktop" }); Color = "Gray" }
    $items += [PSCustomObject]@{ Text = $windows; Color = "Gray" }

    if ((Get-Command Test-AgenteTIPendingReboot -ErrorAction SilentlyContinue) -and (Test-AgenteTIPendingReboot)) {
        $items += [PSCustomObject]@{ Text = "Reinício pendente"; Color = "Yellow" }
    }

    Write-Host "  " -NoNewline

    for ($i = 0; $i -lt $items.Count; $i++) {
        if ($i -gt 0) { Write-Host "   " -NoNewline }
        Write-Host "$($glyphs.Dot) " -ForegroundColor DarkGray -NoNewline
        Write-Host $items[$i].Text -ForegroundColor $items[$i].Color -NoNewline
    }

    Write-Host ""

    if ($session.UserMismatch) {
        Write-Host "  [!] Elevado com outra conta: ajustes de usuário e Downloads afetam este perfil, não o usuário logado." -ForegroundColor Yellow
    }
}


# ---------------------------------------------------------------------------
# Mensagens
# ---------------------------------------------------------------------------

function Write-AgenteTIMenuItem {
    # -Recommended: escreve "(recomendado)" depois do nome, como a marca "Recomendado" do cartão na janela (a cor sozinha
    # não diz nada a quem não a distingue). Uma descrição que não cabe na linha vai para baixo do nome, com o mesmo recuo.
    param (
        [string]$Key,
        [string]$Label,
        [string]$Description = "",
        [switch]$Accent,
        [switch]$Exit,
        [switch]$Recommended
    )

    $keyColor = "Cyan"
    $labelColor = "Gray"

    if ($Accent) {
        $keyColor = "Green"
        $labelColor = "White"
    }
    elseif ($Exit) {
        $keyColor = "DarkGray"
        $labelColor = "DarkGray"
    }

    $keyText = $Key.PadLeft(2)
    $tag = $(if ($Recommended -and $Label -notmatch '(?i)recomendad') { " (recomendado)" } else { "" })

    Write-Host "  [" -ForegroundColor DarkGray -NoNewline
    Write-Host $keyText -ForegroundColor $keyColor -NoNewline
    Write-Host "] " -ForegroundColor DarkGray -NoNewline
    Write-Host $Label -ForegroundColor $labelColor -NoNewline

    if ($tag) {
        Write-Host $tag -ForegroundColor Green -NoNewline
    }

    if (-not [string]::IsNullOrWhiteSpace($Description)) {
        $indent = 4 + $keyText.Length + 1
        $width = Get-AgenteTIWrapWidth

        if ($width -gt 0 -and ($indent + $Label.Length + $tag.Length + 2 + $Description.Length) -gt $width) {
            Write-Host ""

            foreach ($line in @(Split-AgenteTIWrappedText -Text $Description -Width ([Math]::Max(20, $width - $indent)))) {
                Write-Host ((" " * $indent) + $line) -ForegroundColor DarkGray
            }

            return
        }

        Write-Host "  $Description" -ForegroundColor DarkGray -NoNewline
    }

    Write-Host ""
}


function Write-AgenteTISection {
    param (
        [string]$Title
    )

    $glyphs = Get-AgenteTIGlyphs
    $ruleLength = [Math]::Min((Get-AgenteTIConsoleWidth) - 4, [Math]::Max(12, $Title.Length + 4))

    Write-Host ""
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ("  " + ($glyphs.H * $ruleLength)) -ForegroundColor DarkGray
}


function Write-AgenteTIKeyValue {
    # Level pinta o valor: Ok verde, Warn amarelo, Bad vermelho. O resumo da janela lê a cor e pinta o valor também, para
    # o que pede atenção saltar aos olhos numa lista de dados.
    param (
        [string]$Label,
        [object]$Value,
        [int]$LabelWidth = 24,
        [ValidateSet("Normal", "Ok", "Warn", "Bad")][string]$Level = "Normal"
    )

    $valueText = if ($null -eq $Value) {
        "Não disponível"
    }
    elseif ($Value -is [System.Array]) {
        ($Value | ForEach-Object { $_.ToString() }) -join ", "
    }
    elseif ([string]::IsNullOrWhiteSpace($Value.ToString())) {
        "Não disponível"
    }
    else {
        $Value.ToString()
    }

    Write-Host "  " -NoNewline
    Write-Host ($Label.PadRight($LabelWidth)) -ForegroundColor DarkGray -NoNewline
    Write-Host " : " -ForegroundColor DarkGray -NoNewline
    Write-Host $valueText -ForegroundColor $(switch ($Level) { "Ok" { "Green" } "Warn" { "Yellow" } "Bad" { "Red" } default { "Gray" } })
}


function ConvertTo-AgenteTIReadableError {
    <#
    Um texto de erro do jeito que a pessoa deve ler, numa linha: sem o embrulho do PowerShell em volta da mensagem do
    Windows ('Exception calling "Search" with "1" argument(s): "..."', ou 'Exceção ao chamar ... com ... argumento(s)'),
    e com um comando que não existe neste Windows dito em português, sem as duas linhas de "verifique a grafia" que o
    PowerShell acrescenta. Texto sem nada disso volta igual.
    #>
    param ([AllowEmptyString()][AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return [string]$Text }

    $result = $Text
    $wrapper = '(?s)(Exception calling|Exceção ao chamar) "[^"]+" (with|com) "[0-9]+" argument[o]?\(s\): "(?<inner>.*)"(?<tail>[.\s]*)\z'

    for ($i = 0; $i -lt 5 -and $result -match $wrapper; $i++) {
        $result = $result.Substring(0, $result.Length - $Matches[0].Length) + $Matches['inner'] + $Matches['tail']
    }

    $missing = "(?s)(The term|O termo) '(?<name>[^']+)' (is not recognized as|não é reconhecido como).*\z"

    if ($result -match $missing) {
        $result = $result.Substring(0, $result.Length - $Matches[0].Length) + "o comando '$($Matches['name'])' não está disponível neste Windows"
    }

    # As recusas de acesso do .NET chegam em inglês na maioria dos Windows em português (sem o pacote de idioma do .NET).
    $denied = @{
        "Attempted to perform an unauthorized operation."   = "o Windows negou a alteração (acesso negado)"
        "Tentativa de executar uma operação não autorizada." = "o Windows negou a alteração (acesso negado)"
        "Requested registry access is not allowed."          = "o Windows negou o acesso ao registro"
        "O acesso ao Registro solicitado não é permitido."   = "o Windows negou o acesso ao registro"
    }

    foreach ($english in $denied.Keys) {
        $result = $result.Replace($english, $denied[$english])
    }

    # Uma mensagem do Windows com quebras de linha vira uma linha só (o resumo e a faixa de resultado são de uma linha).
    return ([regex]::Replace($result, '\s*\r?\n\s*', ' ')).TrimEnd()
}


function Write-AgenteTIStatus {
    param (
        [ValidateSet("Success", "Warning", "Error", "Info", "Running")]
        [string]$Type,
        [string]$Message,

        # Um aviso ANTES de uma pergunta ("os itens serão removidos permanentemente"): aparece com o ícone do tipo, na
        # saída e no resumo da janela, mas não é um resultado e não conta no desfecho da ação.
        [switch]$Notice
    )

    $Message = ConvertTo-AgenteTIReadableError -Text $Message

    if (-not $Notice) {
        Add-AgenteTIOutcomeMessage -Type $Type -Message $Message
    }

    $badge = switch ($Type) {
        "Success" { "[OK]" }
        "Warning" { "[!]" }
        "Error"   { "[X]" }
        "Running" { "[..]" }
        default   { "[i]" }
    }

    $color = switch ($Type) {
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error"   { "Red" }
        "Running" { "Cyan" }
        default   { "Cyan" }
    }

    # Uma mensagem longa continua embaixo do texto, depois do "[OK] ", e não embaixo do ícone.
    Write-AgenteTIWrappedLine -Prefix "$badge " -PrefixColor $color -Text $Message -Color Gray
}


function Write-AgenteTICommand {
    param (
        [string]$Command
    )

    Write-Host "  > " -ForegroundColor DarkGray -NoNewline
    Write-Host $Command -ForegroundColor DarkCyan
}


function Write-AgenteTISubStep {
    param (
        [string]$Title,
        [string]$Message = ""
    )

    Write-Host ""
    Write-Host "  [>] " -ForegroundColor Cyan -NoNewline
    Write-Host $Title -ForegroundColor White

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        Write-Host "      $Message" -ForegroundColor DarkGray
    }
}


function Write-AgenteTIProgress {
    param (
        [int]$Current,
        [int]$Total,
        [string]$Label = "",
        [int]$BarWidth = 24
    )

    $glyphs = Get-AgenteTIGlyphs

    if ($Total -le 0) { $Total = 1 }

    $ratio = [Math]::Min(1.0, [Math]::Max(0.0, $Current / $Total))
    $filled = [int][Math]::Round($ratio * $BarWidth)
    $bar = ($glyphs.Full * $filled) + ($glyphs.Empty * ($BarWidth - $filled))
    $percent = [int][Math]::Round($ratio * 100)

    Write-Host "  " -NoNewline
    Write-Host $bar -ForegroundColor Cyan -NoNewline
    Write-Host ("  {0,3}%  ({1}/{2})  " -f $percent, $Current, $Total) -ForegroundColor DarkGray -NoNewline
    Write-Host $Label -ForegroundColor Gray
}


function Write-AgenteTIResultTable {
    # Resumo de etapas: objetos com Etapa, Status, Duracao e (opcional) Kind = Ok | Skipped | Warning | Failed.
    param (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results
    )

    if (@($Results).Count -eq 0) {
        Write-Host "  Nenhuma etapa foi executada." -ForegroundColor DarkGray
        return
    }

    $nameWidth = 20

    foreach ($result in $Results) {
        $nameValue = [string]$result.Etapa
        if ($nameValue.Length -gt $nameWidth) { $nameWidth = $nameValue.Length }
    }

    foreach ($result in $Results) {
        $kind = [string]$result.Kind

        if ([string]::IsNullOrEmpty($kind)) {
            $kind = switch -Wildcard ([string]$result.Status) {
                "OK*"      { "Ok" }
                "Falhou*"  { "Failed" }
                "Ignorad*" { "Skipped" }
                default    { "Warning" }
            }
        }

        switch ($kind) {
            "Ok"      { $badge = "[OK]"; $color = "Green" }
            "Failed"  { $badge = "[X] "; $color = "Red" }
            "Skipped" { $badge = "[-] "; $color = "DarkGray" }
            default   { $badge = "[!] "; $color = "Yellow" }
        }

        if (Test-AgenteTIGuiMode) {
            # Na janela, cada linha vira uma linha do resumo da execução (com o ícone do desfecho): sem as colunas
            # alinhadas, que lá só deixariam espaços no meio do texto, e sem repetir "OK" ao lado do ícone verde.
            $parts = @([string]$result.Etapa)
            if ($kind -ne "Ok") { $parts += [string]$result.Status }
            if (-not [string]::IsNullOrWhiteSpace([string]$result.Duracao)) { $parts += [string]$result.Duracao }

            Write-Host "  $($badge.Trim()) " -ForegroundColor $color -NoNewline
            Write-Host ($parts -join " · ") -ForegroundColor Gray
            continue
        }

        $duration = ""
        if (-not [string]::IsNullOrWhiteSpace([string]$result.Duracao)) {
            $duration = "  " + [string]$result.Duracao
        }

        Write-Host "  $badge " -ForegroundColor $color -NoNewline
        Write-Host ([string]$result.Etapa).PadRight($nameWidth) -ForegroundColor Gray -NoNewline
        Write-Host "  $($result.Status)" -ForegroundColor $color -NoNewline
        Write-Host $duration -ForegroundColor DarkGray
    }
}


# ---------------------------------------------------------------------------
# Moldura padrão das ações e resultado de etapa
# ---------------------------------------------------------------------------

function Enter-AgenteTIAction {
    # Abertura de uma ação: cabeçalho completo quando ela é chamada sozinha, apenas uma seção quando faz parte de um fluxo.
    # Na janela gráfica o título da ação já aparece acima da saída (é o nome do botão clicado, igual a este), então
    # repeti-lo na saída só gastaria espaço.
    param (
        [Parameter(Mandatory)]
        [string]$Title,

        [switch]$Embedded
    )

    if ($Embedded -or $script:AgenteTINestedDepth -gt 0) {
        Write-AgenteTISection -Title $Title
    }
    elseif (-not (Test-AgenteTIGuiMode)) {
        # No console, a ação que começa sozinha começa um desfecho novo (a linha final de Exit-AgenteTIAction). Na janela
        # quem zera é o executor, antes de a ação começar.
        Reset-AgenteTIOutcome
        Show-AgenteTIHeader $Title
    }
}


function Exit-AgenteTIAction {
    # Encerramento de uma ação chamada sozinha. Na interface gráfica o botão Voltar já faz esse papel.
    # -Result: o AgenteTI.Result da ação; quando ela roda sozinha (sem -Embedded) o resultado vira o desfecho que a janela
    # mostra. Dentro de um fluxo (Manutenção) quem decide o desfecho é o fluxo.
    param (
        [switch]$Embedded,

        $Result = $null
    )

    if (-not $Embedded -and $script:AgenteTINestedDepth -gt 0) {
        # Uma ação que roda dentro de um fluxo (Invoke-AgenteTINestedAction): o resultado dela vai para o fluxo, sem mudar
        # o desfecho dele e sem a pausa do fim.
        if ($null -ne $Result -and -not ($Result -is [System.Array])) {
            $script:AgenteTINestedResult = $Result
        }

        return
    }

    if (-not $Embedded) {
        if ($null -ne $Result -and -not ($Result -is [System.Array])) {
            Set-AgenteTIOutcome -Result $Result
        }

        # No console, a última linha diz como a ação terminou, como a faixa de resultado da janela. Depois de Voltar ou
        # Cancelar não há o que ler: o menu volta sem pedir mais uma tecla.
        if (-not (Test-AgenteTIGuiMode)) {
            $outcome = Get-AgenteTIOutcome

            if ($outcome.Kind -eq "Skipped" -and $outcome.Detail -match "(?i)cancelad") {
                return
            }

            Write-AgenteTIOutcomeLine -Outcome $outcome
        }

        Write-Host ""
        Wait-AgenteTIKey
    }
}


function Invoke-AgenteTINestedAction {
    <#
    Roda uma ação inteira, com as perguntas dela, dentro de um fluxo (as etapas com você do Otimizar): o título vira uma
    seção, sem o cabeçalho e sem a pausa do fim, e o desfecho do fluxo não muda. Devolve o AgenteTI.Result com que a
    ação terminou (o de Exit-AgenteTIAction ou o último que ela devolveu), ou um Ok sem detalhe se ela não disse nada.
    -Arguments: os parâmetros da ação, por nome.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$Command,

        [hashtable]$Arguments = @{}
    )

    $previous = $script:AgenteTINestedResult
    $script:AgenteTINestedResult = $null
    $script:AgenteTINestedDepth++
    $result = $null

    try {
        $output = @(& $Command @Arguments)
        $result = $script:AgenteTINestedResult
    }
    finally {
        $script:AgenteTINestedDepth--
        $script:AgenteTINestedResult = $previous
    }

    $returned = @($output | Where-Object { $null -ne $_ -and $_.PSObject.TypeNames -contains "AgenteTI.Result" })
    $others = @($output | Where-Object { $null -ne $_ -and -not ($_.PSObject.TypeNames -contains "AgenteTI.Result") })

    # Texto ou objetos soltos da ação aparecem na tela, mas não viram o resultado.
    if ($others.Count -gt 0) {
        $others | Out-Host
    }

    if ($null -eq $result -and $returned.Count -gt 0) {
        $result = $returned[$returned.Count - 1]
    }

    if ($null -eq $result) {
        $result = New-AgenteTIResult -Kind Ok
    }

    return $result
}


function Get-AgenteTIRebootSentence {
    <#
    O que dizer do reinício no fim do resultado: "Reinicie o PC para concluir." quando a ação terminou e falta reiniciar;
    "Reinicie o PC e tente de novo." quando ela não foi concluída por causa de um reinício pendente (nada termina sozinho
    ao reiniciar: é preciso rodar de novo). Nada quando o detalhe da ação já diz para reiniciar ("depois de reiniciar, rode o
    SFC de novo"); quando ele só fala do reinício ("termina na próxima reinicialização"), o pedido continua.
    #>
    param (
        [string]$Kind,
        [string]$Detail = ""
    )

    if ($Detail -match '(?i)\breinicie\b|(depois|antes|ao) de reiniciar|\bao reiniciar') { return "" }
    if ($Kind -eq "Failed") { return " Reinicie o PC e tente de novo." }

    return " Reinicie o PC para concluir."
}


function Write-AgenteTIOutcomeLine {
    # A linha final de uma ação no console: "[OK] Concluído: ...", "[!] Concluído com ressalvas: ..." e, se o Windows
    # precisa reiniciar, o lembrete. Uma tela que só mostrou informações (Done) não ganha linha.
    param (
        [Parameter(Mandatory)]
        $Outcome
    )

    if ($Outcome.Kind -eq "Done") {
        return
    }

    switch ($Outcome.Kind) {
        "Ok"      { $badge = "[OK]"; $color = "Green" }
        "Warning" { $badge = "[!]"; $color = "Yellow" }
        "Failed"  { $badge = "[X]"; $color = "Red" }
        default   { $badge = "[-]"; $color = "DarkGray" }
    }

    Write-Host ""
    Write-AgenteTIWrappedLine -Prefix "$badge " -PrefixColor $color -Text ([string]$Outcome.Summary) -Color $color

    # O mesmo pedido de reinício da janela (Get-AgenteTIRebootSentence): nada quando o detalhe já manda reiniciar.
    if ($Outcome.RebootRequired) {
        $reboot = (Get-AgenteTIRebootSentence -Kind ([string]$Outcome.Kind) -Detail ([string]$Outcome.Summary)).Trim()
        if ($reboot) { Write-Host "  $reboot" -ForegroundColor Yellow }
    }
}


function New-AgenteTIResult {
    <#
    Resultado de uma etapa de fluxo (Otimizar). Só aparece no pipeline quando a ação recebe -PassThru.
    Status é o texto para a pessoa ("OK", "Atenção (...)"). Quem toma decisões (pedir reinício, oferecer uma nova
    tentativa) lê Kind e Data, nunca o texto do Status: Data leva fatos como RebootRequired = $true.
    #>
    param (
        [ValidateSet("Ok", "Skipped", "Warning", "Failed")]
        [string]$Kind = "Ok",

        [string]$Detail = "",

        [string]$Title = "",

        [hashtable]$Data = @{}
    )

    $Detail = ConvertTo-AgenteTIReadableError -Text $Detail

    $status = switch ($Kind) {
        "Ok"      { "OK" }
        "Skipped" { "Ignorado" }
        "Warning" { "Atenção" }
        "Failed"  { "Falhou" }
    }

    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        $status += " ($Detail)"
    }

    return [PSCustomObject]@{
        PSTypeName = "AgenteTI.Result"
        Kind       = $Kind
        Etapa      = $Title
        Status     = $status
        Detail     = $Detail
        Duracao    = ""
        Data       = $Data
    }
}


function Get-AgenteTIResultData {
    # Lê um fato de Data (por exemplo FreedBytes) sem depender de a chave, ou do próprio Data, existir. Falta = $null.
    param (
        $Result,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Result -or -not ($Result.PSObject.Properties.Name -contains "Data")) {
        return $null
    }

    $data = $Result.Data

    if ($data -is [System.Collections.IDictionary] -and $data.Contains($Name)) {
        return $data[$Name]
    }

    return $null
}


function Test-AgenteTIResultFlag {
    # Fato booleano de Data (por exemplo RebootRequired); ausente conta como falso.
    param (
        $Result,

        [Parameter(Mandatory)]
        [string]$Name
    )

    return [bool](Get-AgenteTIResultData -Result $Result -Name $Name)
}


# ---------------------------------------------------------------------------
# Desfecho da ação (o que a janela mostra na faixa de resultado)
# ---------------------------------------------------------------------------

function Reset-AgenteTIOutcome {
    $script:AgenteTIOutcomeState = [ordered]@{
        Explicit    = $null
        Success     = 0
        Warning     = 0
        Error       = 0
        LastWarning = ""
        LastError   = ""
    }
}


function Add-AgenteTIOutcomeMessage {
    # Chamado por Write-AgenteTIStatus: conta as mensagens de sucesso, aviso e erro da ação em andamento.
    param (
        [string]$Type,
        [string]$Message
    )

    if ($null -eq $script:AgenteTIOutcomeState) {
        Reset-AgenteTIOutcome
    }

    $state = $script:AgenteTIOutcomeState

    switch ($Type) {
        "Success" { $state.Success++ }
        "Warning" { $state.Warning++; $state.LastWarning = $Message }
        "Error"   { $state.Error++; $state.LastError = $Message }
    }
}


function Set-AgenteTIOutcome {
    <#
    Registra o resultado explícito da ação (um AgenteTI.Result, ou Kind e Detail soltos). Vale mais do que a contagem
    de mensagens; o último registro vence.
    #>
    param (
        $Result = $null,

        [ValidateSet("Ok", "Skipped", "Warning", "Failed")]
        [string]$Kind = "",

        [string]$Detail = ""
    )

    if ($null -eq $script:AgenteTIOutcomeState) {
        Reset-AgenteTIOutcome
    }

    $reboot = $false
    $view = @{ Headline = ""; Note = ""; Tone = ""; Next = ""; NextLabel = ""; HideSummary = $false }

    if ($null -ne $Result) {
        $Kind = [string]$Result.Kind
        $Detail = [string]$Result.Detail
        $reboot = Test-AgenteTIResultFlag -Result $Result -Name "RebootRequired"

        # Como a janela apresenta este resultado, se a ação disse (Set-AgenteTIResultView).
        foreach ($name in @("Headline", "Note", "Tone", "Next", "NextLabel")) {
            $view[$name] = [string](Get-AgenteTIResultData -Result $Result -Name $name)
        }

        $view.HideSummary = Test-AgenteTIResultFlag -Result $Result -Name "HideSummary"
    }

    if ([string]::IsNullOrEmpty($Kind)) {
        return
    }

    $script:AgenteTIOutcomeState.Explicit = [PSCustomObject]@{
        Kind = $Kind; Detail = $Detail; RebootRequired = $reboot
        Headline = $view.Headline; Note = $view.Note; Tone = $view.Tone; Next = $view.Next; NextLabel = $view.NextLabel; HideSummary = $view.HideSummary
    }
}


function Set-AgenteTIResultView {
    <#
    Como a janela apresenta um resultado quando o genérico ("Concluído com ressalvas: 4 ameaças encontradas; 3 ainda
    pedem ação") não basta. Headline é o título da faixa ("3 ameaças pedem ação"); Note, a frase embaixo dele; Tone, a
    cor (Ok, Warn ou Bad) quando ela não é a do Kind; Next, o próximo passo (um item da navegação ou um atalho do
    Windows), com NextLabel no botão; HideSummary esconde o resumo quando a faixa já diz tudo. Fica em Data: o console, o
    Otimizar e o histórico continuam com Kind e Detail. Devolve o próprio resultado.
    #>
    param (
        [Parameter(Mandatory)]
        $Result,

        [string]$Headline = "",
        [string]$Note = "",

        [ValidateSet("", "Ok", "Warn", "Bad")]
        [string]$Tone = "",

        [string]$Next = "",
        [string]$NextLabel = "",
        [switch]$HideSummary
    )

    if (-not ($Result.Data -is [System.Collections.IDictionary])) { $Result.Data = @{} }

    $Result.Data["Headline"] = $Headline
    $Result.Data["Note"] = $Note
    $Result.Data["Tone"] = $Tone
    $Result.Data["Next"] = $Next
    $Result.Data["NextLabel"] = $NextLabel
    $Result.Data["HideSummary"] = [bool]$HideSummary

    return $Result
}


function Format-AgenteTIOutcomeSummary {
    # Uma linha para a faixa de resultado: o que aconteceu, sem repetir o nome da ação.
    param (
        [ValidateSet("Ok", "Skipped", "Warning", "Failed", "Done")]
        [string]$Kind,

        [string]$Detail = ""
    )

    $detail = ([string]$Detail).Trim().TrimEnd(".")

    if ($detail.Length -gt 220) {
        $detail = $detail.Substring(0, 217) + "..."
    }

    switch ($Kind) {
        "Ok"      { if ($detail) { return "Concluído: $detail." } else { return "Concluído com sucesso." } }
        "Warning" { if ($detail) { return "Concluído com ressalvas: $detail." } else { return "Concluído com ressalvas; revise a saída." } }
        "Failed"  { if ($detail) { return "Não foi concluído: $detail." } else { return "Não foi concluído; revise a saída." } }
        "Skipped" {
            # "cancelado pelo usuário" e "operação cancelada" são o mesmo fato; a faixa diz sempre a mesma frase.
            if ($detail -match "(?i)cancelad") { return "Operação cancelada." }
            if ($detail) { return "Nada foi feito: $detail." } else { return "Nada a fazer." }
        }
        default   { return "Concluído." }
    }
}


function Get-AgenteTIOutcome {
    <#
    O desfecho da ação que acabou de rodar. Kind = Ok | Warning | Failed | Skipped | Done (Done: a ação só mostrou
    informações e não registrou nada). Usa o resultado explícito, se houver; senão, deduz das mensagens de estado:
    erro sem nenhum sucesso é falha, erro com sucesso e aviso são ressalvas, aviso de cancelamento é "nada feito".
    #>
    if ($null -eq $script:AgenteTIOutcomeState) {
        Reset-AgenteTIOutcome
    }

    $state = $script:AgenteTIOutcomeState
    $kind = "Done"
    $detail = ""
    $reboot = $false
    $view = @{ Headline = ""; Note = ""; Tone = ""; Next = ""; NextLabel = ""; HideSummary = $false }

    if ($null -ne $state.Explicit) {
        $kind = [string]$state.Explicit.Kind
        $detail = [string]$state.Explicit.Detail
        $reboot = [bool]$state.Explicit.RebootRequired

        foreach ($name in @("Headline", "Note", "Tone", "Next", "NextLabel")) {
            $view[$name] = [string](Get-AgenteTIJsonValue -Object $state.Explicit -Name $name -Default "")
        }

        $view.HideSummary = [bool](Get-AgenteTIJsonValue -Object $state.Explicit -Name "HideSummary" -Default $false)
    }
    elseif ($state.Error -gt 0) {
        $detail = [string]$state.LastError

        if ($state.Success -gt 0) { $kind = "Warning" } else { $kind = "Failed" }
    }
    elseif ($state.Warning -gt 0) {
        $detail = [string]$state.LastWarning

        if ($state.Success -eq 0 -and $detail -match "(?i)cancelad") {
            $kind = "Skipped"
            $detail = "operação cancelada"
        }
        else {
            $kind = "Warning"
        }
    }
    elseif ($state.Success -gt 0) {
        $kind = "Ok"
    }

    $title = switch ($kind) {
        "Ok"      { "Concluído" }
        "Warning" { "Concluído com ressalvas" }
        "Failed"  { "Não foi concluído" }
        # O PC reiniciando a pedido da pessoa (o Otimizar com um reinício pendente) não é "Nada a fazer".
        "Skipped" { $(if ($detail -match "(?i)cancelad") { "Cancelado" } elseif ($detail -match "(?i)reiniciando") { "Reiniciando" } else { "Nada a fazer" }) }
        default   { "Concluído" }
    }

    # O título que a própria ação deu ao resultado ("Nenhum vírus encontrado") vale mais que o genérico.
    if (-not [string]::IsNullOrWhiteSpace($view.Headline)) { $title = $view.Headline }

    return [PSCustomObject]@{
        PSTypeName     = "AgenteTI.Outcome"
        Kind           = $kind
        Title          = $title
        Summary        = (Format-AgenteTIOutcomeSummary -Kind $kind -Detail $detail)
        Detail         = $detail
        RebootRequired = $reboot
        Headline       = $view.Headline
        Note           = $view.Note
        Tone           = $view.Tone
        Next           = $view.Next
        NextLabel      = $view.NextLabel
        HideSummary    = $view.HideSummary
    }
}


function Test-AgenteTIElevation {
    # Verdadeiro quando o processo é Administrador; caso contrário mostra o motivo e devolve falso.
    param (
        [string]$Reason = "Esta ação exige privilégios de Administrador."
    )

    if (Test-AgenteTIAdministrator) {
        return $true
    }

    Write-AgenteTIStatus -Type Error -Message $Reason
    Write-Host "      Feche o AgenteTI e abra-o novamente como Administrador." -ForegroundColor DarkGray
    return $false
}


# ---------------------------------------------------------------------------
# Perguntas
# ---------------------------------------------------------------------------

function Test-AgenteTIGuiPrompts {
    # Verdadeiro quando a interface gráfica fornece botões e listas de marcação para as perguntas.
    $guiHost = Get-Variable -Name AgenteTIGuiHost -Scope Global -ErrorAction SilentlyContinue

    return ((Test-AgenteTIGuiMode) -and $null -ne $guiHost -and $null -ne $guiHost.Value)
}


function Wait-AgenteTIKey {
    # "Pressione qualquer tecla" do console. Na interface gráfica não há o que esperar: o botão Voltar faz esse papel.
    param (
        [string]$Message = "Pressione qualquer tecla para continuar..."
    )

    if (Test-AgenteTIGuiMode) {
        return
    }

    Write-Host "  $Message" -ForegroundColor DarkGray

    try {
        [void]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
    catch {
        # Hosts sem teclado direto (ISE, entrada redirecionada): usa ENTER.
        try { [void](Read-Host) } catch { }
    }
}


function Test-AgenteTIInputRedirected {
    # Se as respostas do console vêm de um arquivo ou de outro programa (e não de alguém digitando).
    try {
        return [bool][Console]::IsInputRedirected
    }
    catch {
        return $true
    }
}


function Get-AgenteTIAnswerLimit {
    # Quantas respostas inválidas seguidas uma pergunta do console aceita (veja $script:AgenteTIMaxInvalidAnswers).
    if ((Test-AgenteTIGuiMode) -or (Test-AgenteTIInputRedirected)) {
        return $script:AgenteTIMaxInvalidAnswers
    }

    return $script:AgenteTIMaxTypedAnswers
}


function Format-AgenteTIKeyHint {
    # O que pode ser digitado, para a mensagem de opção inválida: "um número de 0 a 11", "L, D ou 0",
    # "um número de 0 a 28, A, P ou R".
    param (
        [string[]]$Keys
    )

    $numbers = @($Keys | Where-Object { $_ -match '^[0-9]+$' } | ForEach-Object { [int]$_ } | Sort-Object -Unique)
    $letters = @($Keys | Where-Object { $_ -notmatch '^[0-9]+$' } | ForEach-Object { $_.ToUpperInvariant() })
    $parts = @()

    if ($numbers.Count -ge 3 -and ($numbers[-1] - $numbers[0] + 1) -eq $numbers.Count) {
        $parts += "um número de $($numbers[0]) a $($numbers[-1])"
    }
    else {
        $parts += @($numbers | ForEach-Object { [string]$_ })
    }

    $parts += $letters

    # A saída (0), quando há letras, vai por último: "L, D ou 0".
    if ($letters.Count -gt 0 -and $parts -contains "0") {
        $parts = @($parts | Where-Object { $_ -ne "0" }) + "0"
    }

    if ($parts.Count -le 1) {
        return ($parts -join "")
    }

    return (($parts[0..($parts.Count - 2)] -join ", ") + " ou " + $parts[-1])
}


function Get-AgenteTIUnelevatedHint {
    # Como abrir o AgenteTI sem Administrador, com a conta de quem usa o PC (quando ele está aberto com a conta de outro
    # Administrador). Na janela, recusar o aviso do Windows abre a janela assim mesmo; no menu de texto, recusar fecha.
    if (Test-AgenteTIGuiMode) {
        return "feche o AgenteTI, abra de novo e responda Não ao aviso do Windows: a janela abre sem Administrador"
    }

    return "abra a janela do AgenteTI (pelo atalho ou pelo AgenteTI.cmd) e responda Não ao aviso do Windows: ela abre sem Administrador"
}


function Confirm-AgenteTIAction {
    # Pergunta Sim/Não. DefaultKey ("S" ou "N") destaca o botão na interface gráfica e vale para ENTER no console.
    param (
        [string]$Message = "Deseja continuar?",

        [ValidateSet("", "S", "N")]
        [string]$DefaultKey = "",

        # Na janela, botões que dizem o que fazem ("Reiniciar agora" e "Depois") no lugar de Sim e Não. O do não vira a
        # saída: nunca fica em destaque, e com Não como padrão a pergunta fica sem botão em destaque (o Enter fica nele).
        # O console continua com S/N.
        [string]$YesLabel = "",
        [string]$NoLabel = ""
    )

    if (Test-AgenteTIGuiPrompts) {
        # Sem resposta padrão, a janela põe o foco do teclado no Não (um Enter a mais não confirma nada); com ela, na padrão.
        $verbs = (-not [string]::IsNullOrWhiteSpace($YesLabel) -and -not [string]::IsNullOrWhiteSpace($NoLabel))

        if ($verbs) {
            $options = @(
                @{ Key = "S"; Label = $YesLabel; Accent = ($DefaultKey -ne "N") },
                @{ Key = "N"; Label = $NoLabel; Exit = $true }
            )
        }
        else {
            $options = @(
                @{ Key = "S"; Label = "Sim"; Accent = ($DefaultKey -ne "N") },
                @{ Key = "N"; Label = "Não"; Accent = ($DefaultKey -eq "N") }
            )
        }

        $answer = Read-AgenteTIChoice -Message $Message -DefaultKey $DefaultKey -Options $options

        return ($answer -eq "S")
    }

    $hint = switch ($DefaultKey) {
        "S"     { "S/n" }
        "N"     { "s/N" }
        default { "S/N" }
    }

    $limit = Get-AgenteTIAnswerLimit
    $ended = 0

    for ($attempt = 0; $attempt -lt $limit -and $ended -lt $script:AgenteTIMaxInvalidAnswers; $attempt++) {
        Write-Host "  " -NoNewline
        $raw = Read-Host "$Message ($hint)"

        # Nulo: a entrada acabou (redirecionada, Ctrl+Z). Conta sempre para o limite curto.
        if ($null -eq $raw) { $ended++ }

        $answer = ([string]$raw).Trim().ToUpperInvariant()

        if ([string]::IsNullOrEmpty($answer) -and $DefaultKey) {
            $answer = $DefaultKey
        }

        switch ($answer) {
            { $_ -in @("S", "SIM", "Y", "YES") } { return $true }
            { $_ -in @("N", "NAO", "NÃO", "NO") } { return $false }
            "" {
                Write-Host "  Digite S ou N e tecle Enter." -ForegroundColor DarkGray
            }
            default {
                Write-Host "  Opção inválida. Digite S ou N e tecle Enter." -ForegroundColor Red
            }
        }
    }

    throw "Nenhuma resposta válida foi informada."
}


function Get-AgenteTIOptionField {
    # Lê um campo opcional de uma opção de pergunta (hashtable ou objeto). Campo ausente devolve $Default;
    # funciona também sob Set-StrictMode, que recusa "$hashtable.ChaveQueNaoExiste".
    param (
        $Option,

        [Parameter(Mandatory)]
        [string]$Name,

        $Default = $null
    )

    if ($Option -is [System.Collections.IDictionary]) {
        if ($Option.Contains($Name)) { return $Option[$Name] }

        return $Default
    }

    $property = $Option.PSObject.Properties[$Name]

    if ($null -ne $property) { return $property.Value }

    return $Default
}


function ConvertTo-AgenteTIOptionList {
    # Normaliza as opções de Read-AgenteTIChoice/Read-AgenteTIMultiSelect: todos os campos existem, com o tipo certo.
    param (
        [object[]]$Options
    )

    foreach ($option in @($Options)) {
        [PSCustomObject]@{
            Key         = [string](Get-AgenteTIOptionField $option "Key" "")
            Label       = [string](Get-AgenteTIOptionField $option "Label" "")
            Description = [string](Get-AgenteTIOptionField $option "Description" "")
            Accent      = [bool](Get-AgenteTIOptionField $option "Accent" $false)
            Exit        = [bool](Get-AgenteTIOptionField $option "Exit" $false)
            Selected    = [bool](Get-AgenteTIOptionField $option "Selected" $false)
        }
    }
}


function Read-AgenteTIChoice {
    <#
    Pergunta de escolha única. Na interface gráfica vira botões; no console, o menu de sempre.
    Options: hashtables/objetos com Key, Label e, opcionalmente, Description, Accent e Exit (opção de sair/cancelar).
    Retorna a Key escolhida.
    #>
    param (
        [string]$Message = "Selecione uma opção",
        [Parameter(Mandatory)]
        [object[]]$Options,
        [string]$DefaultKey = "",
        [string]$TextPrompt = "",
        [switch]$ShowMenu
    )

    $items = @(ConvertTo-AgenteTIOptionList -Options $Options)

    if (Test-AgenteTIGuiPrompts) {
        $converted = @(
            foreach ($option in $items) {
                $guiOption = New-Object AgenteTI.GuiOption
                $guiOption.Key = $option.Key
                $guiOption.Label = $option.Label
                $guiOption.Description = $option.Description
                $guiOption.Accent = $option.Accent
                $guiOption.Exit = $option.Exit
                $guiOption
            }
        )

        return [string]$global:AgenteTIGuiHost.GuiUI.AskChoice("", $Message, $converted, $DefaultKey)
    }

    # 0 sempre volta ou cancela: a opção de saída (Exit) aceita também o 0 quando nenhuma outra usa o 0. Ela aparece como
    # [ 0], salvo quando o texto da pergunta (-TextPrompt) cita a tecla dela ("X = cancelar").
    $exit = @($items | Where-Object { $_.Exit }) | Select-Object -First 1
    $zeroAlias = ($null -ne $exit -and $exit.Key -ne "0" -and @($items | Where-Object { $_.Key -eq "0" }).Count -eq 0)
    $showZero = ($zeroAlias -and ([string]::IsNullOrWhiteSpace($TextPrompt) -or $TextPrompt -cnotmatch ('(^|[^\p{L}\p{N}])' + [regex]::Escape($exit.Key) + '([^\p{L}\p{N}]|$)')))

    $shownKeys = @(
        foreach ($option in $items) {
            if ($showZero -and $option.Exit -and $option.Key -eq $exit.Key) { "0" } else { $option.Key }
        }
    )

    if ($ShowMenu) {
        for ($i = 0; $i -lt $items.Count; $i++) {
            $option = $items[$i]
            Write-AgenteTIMenuItem -Key $shownKeys[$i] -Label $option.Label -Description $option.Description -Accent:$option.Accent -Exit:$option.Exit
        }

        Write-Host ""
    }

    # A pergunta vai numa linha própria e o pedido é só "Opção" (o Read-Host acrescenta ": "; depois de um "?" ficava
    # "atalho?: "). Um -TextPrompt já diz tudo e fica como está.
    if (-not [string]::IsNullOrWhiteSpace($TextPrompt)) {
        $prompt = $TextPrompt
    }
    else {
        Write-AgenteTIWrappedLine -Text $Message -Color Gray
        $prompt = "Opção"
    }

    $keyHint = Format-AgenteTIKeyHint -Keys $shownKeys
    $limit = Get-AgenteTIAnswerLimit
    $ended = 0

    for ($attempt = 0; $attempt -lt $limit -and $ended -lt $script:AgenteTIMaxInvalidAnswers; $attempt++) {
        Write-Host "  " -NoNewline
        $raw = Read-Host $prompt

        # Nulo: a entrada acabou (redirecionada, Ctrl+Z). Conta sempre para o limite curto.
        if ($null -eq $raw) { $ended++ }

        $answer = ([string]$raw).Trim()

        if ([string]::IsNullOrEmpty($answer) -and -not [string]::IsNullOrEmpty($DefaultKey)) {
            return $DefaultKey
        }

        if ($zeroAlias -and $answer -eq "0") {
            return $exit.Key
        }

        $match = @($items | Where-Object { $_.Key -ieq $answer }) | Select-Object -First 1

        if ($null -ne $match) {
            return $match.Key
        }

        if ([string]::IsNullOrEmpty($answer)) {
            Write-Host "  Digite $keyHint e tecle Enter." -ForegroundColor DarkGray
        }
        else {
            Write-Host "  Opção inválida. Digite $keyHint e tecle Enter." -ForegroundColor Red
        }
    }

    throw "Nenhuma resposta válida foi informada."
}


function Read-AgenteTIMultiSelect {
    <#
    Seleção múltipla. Na interface gráfica vira uma lista de marcação; no console, uma lista numerada
    ("1,3,5-7", T = todos, ENTER = cancelar). Options: Key, Label, Description e, opcionalmente, Selected.
    Retorna as Keys marcadas, ou $null se o usuário cancelar ou não marcar nada (o PowerShell não distingue uma
    lista vazia de $null no retorno de uma função, então os chamadores tratam os dois casos como "nada escolhido").
    -NoSelectAll: sem o atalho de marcar tudo (o "T" do console, o "Marcar todos" da janela), nas listas em que marcar
    tudo de uma vez seria um estrago difícil de desfazer (desinstalar programas, remover aplicativos, recursos do Windows).
    -AllowNone: nas revisões (o que já vem marcado é o estado de agora), desmarcar tudo é uma resposta: devolve uma lista
    vazia (como @(), que o chamador distingue de $null), e o console aceita 0 para "nenhum".
    -ConfirmLabel e -CancelLabel: o que os botões da janela dizem ("Desinstalar", "Voltar"); dentro de um fluxo (o
    Otimizar), desistir da lista é pular a etapa, e o botão diz "Pular".
    #>
    param (
        [string]$Message = "Selecione os itens",
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Options,
        [switch]$NoSelectAll,
        [switch]$AllowNone,
        [string]$ConfirmLabel = "",
        [string]$CancelLabel = ""
    )

    $items = @(ConvertTo-AgenteTIOptionList -Options $Options)

    if ($items.Count -eq 0) {
        return $null
    }

    if (Test-AgenteTIGuiPrompts) {
        $converted = @(
            foreach ($option in $items) {
                $guiOption = New-Object AgenteTI.GuiOption
                $guiOption.Key = $option.Key
                $guiOption.Label = $option.Label
                $guiOption.Description = $option.Description
                $guiOption.Selected = $option.Selected
                $guiOption
            }
        )

        if ([string]::IsNullOrWhiteSpace($CancelLabel) -and $script:AgenteTINestedDepth -gt 0) { $CancelLabel = "Pular" }

        # Na janela, -NoSelectAll tira o "Marcar todos" da lista.
        $keys = $global:AgenteTIGuiHost.GuiUI.AskMulti("", $Message, $converted, [bool]$NoSelectAll, $ConfirmLabel, $CancelLabel, [bool]$AllowNone)

        if ($null -eq $keys) {
            return $null
        }

        if ($AllowNone) { return , @($keys) }

        return @($keys)
    }

    for ($i = 0; $i -lt $items.Count; $i++) {
        $mark = if ($items[$i].Selected) { "*" } else { " " }

        Write-Host "  " -NoNewline
        Write-Host ("[{0,2}]{1}" -f ($i + 1), $mark) -ForegroundColor Cyan -NoNewline
        # Um espaço depois do nome mesmo quando ele passa de 30 caracteres: sem ele, nome e descrição se colavam.
        Write-Host (" {0} " -f $items[$i].Label.PadRight(30)) -ForegroundColor Gray -NoNewline
        Write-Host $items[$i].Description -ForegroundColor DarkGray
    }

    $preselected = @($items | Where-Object { $_.Selected })

    Write-Host ""
    $allHint = $(if ($NoSelectAll) { "" } else { " T = todos." })
    $noneHint = $(if ($AllowNone) { " 0 = nenhum." } else { "" })
    Write-Host "  Informe números separados por vírgula ou intervalos (ex.: 1,3,5-7).$allHint$noneHint ENTER = cancelar." -ForegroundColor DarkCyan

    if ($preselected.Count -gt 0) {
        Write-Host "  P = usar os já marcados com * ($($preselected.Count))." -ForegroundColor DarkCyan
    }

    Write-Host ""

    $limit = Get-AgenteTIAnswerLimit

    for ($attempt = 0; $attempt -lt $limit; $attempt++) {
        Write-Host "  " -NoNewline
        $inputText = ([string](Read-Host $Message)).Trim()

        if ([string]::IsNullOrWhiteSpace($inputText)) {
            return $null
        }

        if ($inputText -ieq "T" -and -not $NoSelectAll) {
            return @($items | ForEach-Object { $_.Key })
        }

        if ($inputText -ieq "P" -and $preselected.Count -gt 0) {
            return @($preselected | ForEach-Object { $_.Key })
        }

        if ($inputText -eq "0" -and $AllowNone) {
            return , @()
        }

        try {
            $indexes = @(ConvertTo-AgenteTISelectionIndexes -InputText $inputText -Maximum $items.Count)
            return @($indexes | ForEach-Object { $items[$_ - 1].Key })
        }
        catch {
            # Um número digitado errado não é um erro da ação (não entra no desfecho).
            Write-AgenteTIStatus -Type Error -Notice -Message $_.Exception.Message
        }
    }

    throw "Nenhuma resposta válida foi informada."
}


function Read-AgenteTIText {
    # Texto livre (termo de busca, ID de pacote). Na interface gráfica usa a caixa de texto da barra de perguntas.
    # Retorna o texto sem espaços nas pontas; vazio significa que o usuário desistiu.
    param (
        [Parameter(Mandatory)]
        [string]$Message
    )

    return ([string](Read-Host $Message)).Trim()
}


Export-ModuleMember -Function *
