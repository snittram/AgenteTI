# Histórico de mudanças: o diário do que o AgenteTI mudou no PC, com o desfazer de cada mudança que dá para desfazer.
#
# Cada ação que muda o Windows anota uma linha (o que foi feito, quando e, quando existe, como desfazer) com
# Add-AgenteTIChange, que fica no Core: assim qualquer módulo anota sem depender deste. Aqui ficam o desfazer de cada
# tipo de mudança e a tela do histórico. O diário fica em %LOCALAPPDATA%\AgenteTI\changes.json (as 200 mais recentes).


# ---------------------------------------------------------------------------
# Desfazer
# ---------------------------------------------------------------------------

function Test-AgenteTIStartupUndoItem {
    <#
    Se um item guardado no diário pode ser ligado ou desligado pelo desfazer: tarefas agendadas só se forem uma das que
    a tela Gerenciar inicialização mostra hoje (de outros fabricantes, que rodam ao entrar no Windows ou ao ligar o PC);
    os demais só se o liga/desliga for numa das chaves StartupApproved que o Windows usa para isso.
    #>
    param (
        [Parameter(Mandatory)]$Item,

        # As tarefas de inicialização já lidas (Get-AgenteTIStartupTasks percorre o Agendador inteiro e leva segundos):
        # quem confere vários itens lê uma vez só.
        $Tasks = $null
    )

    $name = [string](Get-AgenteTIJsonValue -Object $Item -Name "Name" -Default "")
    $source = [string](Get-AgenteTIJsonValue -Object $Item -Name "Source" -Default "")

    if ([string]::IsNullOrWhiteSpace($name)) { return $false }

    if ($source -eq "Tarefa agendada") {
        $taskPath = [string](Get-AgenteTIJsonValue -Object $Item -Name "TaskPath" -Default "")
        $taskName = [string](Get-AgenteTIJsonValue -Object $Item -Name "TaskName" -Default "")

        if ([string]::IsNullOrWhiteSpace($taskName) -or $taskPath -like "\Microsoft\*") { return $false }

        if ($null -eq $Tasks) { $Tasks = @(Get-AgenteTIStartupTasks) }

        return (@($Tasks | Where-Object { [string]$_.TaskPath -eq $taskPath -and [string]$_.TaskName -eq $taskName }).Count -gt 0)
    }

    # Aplicativo da Store: o liga/desliga é o State da tarefa de inicialização dele, numa chave SystemAppData da conta.
    if ($source -eq "Aplicativo da Store") {
        return (Test-AgenteTIStartupAppPath -Path ([string](Get-AgenteTIJsonValue -Object $Item -Name "ApprovedPath" -Default "")))
    }

    $approvedRoot = "Microsoft\Windows\CurrentVersion\Explorer\StartupApproved"
    $known = @(
        "HKCU:\Software\$approvedRoot\Run",
        "HKCU:\Software\$approvedRoot\StartupFolder",
        "HKLM:\SOFTWARE\$approvedRoot\Run",
        "HKLM:\SOFTWARE\$approvedRoot\Run32",
        "HKLM:\SOFTWARE\$approvedRoot\StartupFolder"
    )

    return ($known -contains [string](Get-AgenteTIJsonValue -Object $Item -Name "ApprovedPath" -Default ""))
}


function Undo-AgenteTIChange {
    # Desfaz uma mudança anotada e devolve um AgenteTI.Result (Etapa = o nome da mudança). Não marca como desfeita: quem
    # chama marca só o que deu certo.
    param (
        [Parameter(Mandatory)]$Change
    )

    $undo = $Change.Undo
    $kind = [string](Get-AgenteTIJsonValue -Object $undo -Name "Kind" -Default "")

    # O diário fica em %LOCALAPPDATA%, onde qualquer programa da conta grava sem Administrador, e o desfazer pode rodar
    # como Administrador: o que vem dele é conferido antes de virar uma mudança no Windows (só os backups da pasta do
    # AgenteTI, só os itens de inicialização que o AgenteTI gerencia, só os recursos do catálogo).
    # Recursos do Windows e o DNS dos adaptadores só voltam com Administrador: sem ele, o motivo é dito com as palavras do
    # AgenteTI (e não com o texto cru do Windows), e a mudança continua na lista para depois.
    if ($kind -in @("feature", "dns") -and -not (Test-AgenteTIAdministrator)) {
        return (New-AgenteTIResult -Kind Failed -Detail "pede Administrador: abra o AgenteTI como Administrador e desfaça de novo")
    }

    switch ($kind) {
        "registry" {
            $file = [string](Get-AgenteTIJsonValue -Object $undo -Name "File" -Default "")
            $values = [string](Get-AgenteTIJsonValue -Object $undo -Name "Values" -Default "")

            if ([string]::IsNullOrWhiteSpace($file) -and [string]::IsNullOrWhiteSpace($values)) {
                return (New-AgenteTIResult -Kind Failed -Detail "o backup do registro não foi encontrado")
            }

            foreach ($backup in @(@{ Path = $file; Extension = ".reg" }, @{ Path = $values; Extension = ".json" })) {
                # Um arquivo que não existe mais não é lido (vira um problema logo abaixo, só na parte dele).
                if ([string]::IsNullOrWhiteSpace($backup.Path) -or -not (Test-Path -LiteralPath $backup.Path)) { continue }

                # Um caminho fora da pasta de backups do AgenteTI recusa o desfazer inteiro: o diário pode ter sido mexido.
                if (-not (Test-AgenteTIRegistryBackupFile -Path $backup.Path -Extension $backup.Extension)) {
                    return (New-AgenteTIResult -Kind Failed -Detail "o backup do registro não está na pasta de backups do AgenteTI e não foi usado")
                }
            }

            if ($file -and (Test-Path -LiteralPath $file -PathType Leaf) -and -not (Test-AgenteTIRegistryBackupKeys -Path $file)) {
                return (New-AgenteTIResult -Kind Failed -Detail "o backup do registro mexe em chaves que a limpeza não toca e não foi usado")
            }

            # As duas partes rodam sempre, cada uma por si: um arquivo que sumiu ou estragou (um corte de energia no meio
            # da gravação) não impede a outra parte de voltar. Com qualquer falha, o desfazer não é dado como feito e
            # continua na lista: repetir é seguro (o .reg volta igual e só os valores que ainda faltam são recriados).
            $kept = 0
            $done = 0
            $problems = @()
            $gone = @()
            $admin = Test-AgenteTIAdministrator

            if ($values) {
                if (-not (Test-Path -LiteralPath $values -PathType Leaf)) {
                    $gone += "os valores"
                }
                else {
                    try {
                        $restore = Restore-AgenteTIRegistryValues -Path $values
                        $kept = [int]$restore.Kept
                        $done++

                        if (@($restore.Failed).Count -gt 0) {
                            $total = @($restore.Failed).Count + [int]$restore.Restored + $kept
                            $problems += "$(@($restore.Failed).Count) de $total valores não voltaram ($(Join-AgenteTIList -Items @($restore.Failed)))"
                        }
                    }
                    catch {
                        $problems += "o backup dos valores não pôde ser lido ($(([string]$_.Exception.Message).TrimEnd('.')))"
                    }
                }
            }

            if ($file) {
                if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
                    $gone += "as chaves"
                }
                else {
                    $run = Invoke-AgenteTICapture -FilePath "reg" -Arguments @("import", $file)

                    if ($run.ExitCode -ne 0) {
                        $problems += $(if ($admin) { "o reg import terminou com o código $($run.ExitCode)" } else { "as chaves do backup não voltaram" })
                    }
                    else {
                        $done++
                    }
                }
            }

            # Um backup que não existe mais não volta tentando de novo: sem nenhuma parte restaurada, é falha; com a outra
            # parte de volta, a mudança é dada como desfeita, com o aviso do que não tinha como voltar.
            $goneText = $(if ($gone.Count -gt 0) { "o backup d$(if ($gone.Count -eq 2) { 'o registro' } elseif ($gone[0] -eq 'os valores') { 'os valores' } else { 'as chaves' }) não existe mais" } else { "" })

            if ($problems.Count -gt 0 -or $done -eq 0) {
                $all = @($problems) + @($(if ($goneText) { $goneText }))
                $detail = (Join-AgenteTIList -Items $all) + $(if ($problems.Count -gt 0 -and -not $admin) { "; abra o AgenteTI como Administrador e tente de novo" } else { "" })
                return (New-AgenteTIResult -Kind $(if ($done -gt 0) { "Warning" } else { "Failed" }) -Detail $detail)
            }

            # Um valor que já existe de novo (o programa voltou a gravá-lo) fica como está, com o dado de hoje.
            $detail = $(if ($kept -gt 0) { "entradas do registro devolvidas; $(Format-AgenteTICount -Count $kept -One 'valor já existia de novo e ficou' -Many 'valores já existiam de novo e ficaram') como está" } else { "entradas do registro devolvidas" })
            if ($goneText) { $detail += "; $goneText, então $($gone[0]) não têm como voltar" }

            return (New-AgenteTIResult -Kind Ok -Detail $detail)
        }
        "startup" {
            $failed = 0
            $reason = ""
            $items = @(Get-AgenteTIJsonValue -Object $undo -Name "Items" -Default @())
            $tasks = $null

            foreach ($item in $items) {
                try {
                    if ($null -eq $tasks -and [string](Get-AgenteTIJsonValue -Object $item -Name "Source" -Default "") -eq "Tarefa agendada") {
                        $tasks = @(Get-AgenteTIStartupTasks)
                    }

                    if (-not (Test-AgenteTIStartupUndoItem -Item $item -Tasks $tasks)) {
                        throw "item de inicialização desconhecido"
                    }

                    Set-AgenteTIStartupItemEnabled -Item $item -Enabled ([bool](Get-AgenteTIJsonValue -Object $item -Name "Enabled" -Default $true))
                }
                catch {
                    $failed++

                    # O primeiro motivo vai junto (por exemplo, o item de todos os usuários que exige Administrador): sem
                    # ele, a pessoa não sabe o que fazer para desfazer.
                    if (-not $reason) { $reason = ([string]$_.Exception.Message).TrimEnd('.') }
                }
            }

            if ($failed -gt 0) {
                $what = $(if ($items.Count -eq 1) { "o item não voltou ao estado anterior" } elseif ($failed -eq 1) { "1 de $($items.Count) itens não voltou ao estado anterior" } else { "$failed de $($items.Count) itens não voltaram ao estado anterior" })
                return (New-AgenteTIResult -Kind $(if ($failed -lt $items.Count) { "Warning" } else { "Failed" }) -Detail $(if ($reason) { "${what}: $reason" } else { $what }))
            }

            return (New-AgenteTIResult -Kind Ok -Detail "inicialização como estava antes")
        }
        "tweak" {
            $tweak = Get-AgenteTITweakById -Id ([string](Get-AgenteTIJsonValue -Object $undo -Name "Id" -Default ""))

            if ($null -eq $tweak) {
                return (New-AgenteTIResult -Kind Failed -Detail "ajuste desconhecido")
            }

            # Com os valores originais guardados, o desfazer sempre os devolve: "não aplicado" pode ser parcial (uma atualização
            # do Windows voltou só um dos valores do ajuste), e "já estava desfeito" deixaria o resto como o AgenteTI pôs.
            $backup = Read-AgenteTITweakBackup -Status
            $saved = ($backup.Status -ne "Unreadable" -and $backup.Backup.Contains([string]$tweak.Id))

            if (-not $saved -and (Get-AgenteTITweakStatus -Tweak $tweak) -ne "Aplicado") {
                return (New-AgenteTIResult -Kind Ok -Detail "o ajuste já estava desfeito")
            }

            try {
                $original = [bool](Invoke-AgenteTITweakRevert -Tweak $tweak)
            }
            catch {
                # Uma configuração que o Windows protege (UCPD): a mesma explicação de Ajustes do Windows, com onde desfazer.
                $help = Get-AgenteTITweakProtectedHelp -Tweak $tweak -Undo

                if ($null -ne $help -and (Test-AgenteTIAccessDenied -Exception $_.Exception)) {
                    Write-AgenteTIStatus -Type Warning -Message (Get-AgenteTITweakProtectedText -Help $help)
                    return (New-AgenteTIResult -Kind Failed -Detail "o Windows protege esta configuração e não deixa o AgenteTI desfazê-la")
                }

                throw
            }

            return (New-AgenteTIResult -Kind Ok -Detail $(if ($original) { "ajuste desfeito" } else { "ajuste desfeito com os padrões do Windows (os valores de antes não estavam guardados)" }))
        }
        "dns" {
            $read = Read-AgenteTIDnsBackup -Status

            # Um backup que existe, mas não abriu agora (em uso, sem permissão), não é "nada a desfazer": fica para depois.
            if ($read.Status -eq "Unreadable") {
                return (New-AgenteTIResult -Kind Failed -Detail "o backup do DNS de antes não pôde ser lido agora; tente de novo em instantes")
            }

            $backup = @($read.Entries)

            if ($backup.Count -eq 0) {
                return (New-AgenteTIResult -Kind Ok -Detail "o DNS já estava como antes")
            }

            $undo = Restore-AgenteTIDnsFromBackup -Backup $backup -Adapters @(Get-AgenteTIDnsAdapters)
            $unknown = @(Get-AgenteTIJsonValue -Object $undo -Name "Unknown" -Default @())

            if ($undo.Failed.Count -gt 0 -or $undo.Missing.Count -gt 0 -or $unknown.Count -gt 0) {
                return (New-AgenteTIResult -Kind $(if ($undo.Restored -gt 0) { "Warning" } else { "Failed" }) -Detail "nem todos os adaptadores voltaram ao DNS de antes; use Rede > Desfazer a troca de DNS")
            }

            Remove-AgenteTIDnsBackup
            Clear-DnsClientCache -ErrorAction SilentlyContinue

            # O backup guarda o DNS de antes da primeira troca: todas as trocas anotadas foram desfeitas de uma vez (como
            # em Rede > Desfazer a troca de DNS), e nenhuma fica na lista prometendo voltar a um DNS intermediário.
            Set-AgenteTIChangesUndone -Kind "dns" -Key "Kind" -Value "dns"

            return (New-AgenteTIResult -Kind Ok -Detail "DNS de antes da primeira troca restaurado")
        }
        "feature" {
            $name = [string](Get-AgenteTIJsonValue -Object $undo -Name "Name" -Default "")
            $action = [string](Get-AgenteTIJsonValue -Object $undo -Name "Action" -Default "")

            if ($action -notin @("Enable", "Disable")) {
                return (New-AgenteTIResult -Kind Failed -Detail "mudança de recurso desconhecida")
            }

            # Só os recursos que a tela Recursos do Windows oferece: o nome vem do diário e não pode ligar qualquer recurso.
            if (@(Get-AgenteTIFeatureCatalog | Where-Object { [string]$_.Name -eq $name }).Count -eq 0) {
                return (New-AgenteTIResult -Kind Failed -Detail "recurso desconhecido")
            }

            $applied = Set-AgenteTIOptionalFeature -Name $name -Action $action

            return (New-AgenteTIResult -Kind Ok -Detail $(if ($action -eq "Enable") { "recurso ligado de novo" } else { "recurso desligado de novo" }) -Data @{ RebootRequired = [bool]$applied.RestartNeeded })
        }
    }

    return (New-AgenteTIResult -Kind Failed -Detail "esta mudança não tem como ser desfeita")
}


# ---------------------------------------------------------------------------
# Tela
# ---------------------------------------------------------------------------

function Show-AgenteTIChangeHistory {
    $title = "Histórico de mudanças"

    Enter-AgenteTIAction -Title $title

    $final = New-AgenteTIResult -Kind Ok -Title $title

    try {
        $read = Get-AgenteTIChanges -Status
        $changes = @($read.Changes)

        # Um diário que existe, mas não abriu agora (preso por outro programa, sem permissão), não é "nada mudou": a
        # pessoa perderia de vista o que tem desfazer.
        if ($read.Status -eq "Unreadable") {
            Write-AgenteTIStatus -Type Error -Message "Não foi possível ler o Histórico de mudanças agora (arquivo em uso ou sem permissão): tente de novo em instantes."
            Exit-AgenteTIAction -Result (New-AgenteTIResult -Kind Failed -Detail "não foi possível ler o histórico agora; tente de novo em instantes" -Title $title)
            return
        }

        # Só olhar o histórico não tem veredito: a tela termina sem a faixa de resultado (sem "Tudo certo" nem "Nada a
        # fazer"); a faixa fica para o que foi desfeito.
        if ($changes.Count -eq 0) {
            Write-AgenteTIStatus -Type Info -Message "O AgenteTI ainda não mudou nada neste PC (ou o histórico foi apagado)."
            Exit-AgenteTIAction
            return
        }

        # O desfazer vale para todas as mudanças guardadas: uma mudança antiga continua com o seu desfazer (a lista de
        # marcar mostra a data de cada uma). A lista de cima traz só as outras (sem volta por aqui, ou já desfeitas), para
        # nenhuma mudança aparecer duas vezes na tela.
        $undoable = @($changes | Where-Object { Test-AgenteTIChangeUndoable -Change $_ })
        $others = @($changes | Where-Object { -not (Test-AgenteTIChangeUndoable -Change $_) })
        $shown = @($others | Select-Object -First 30)

        if ($shown.Count -gt 0) {
            Write-AgenteTISection -Title $(if ($undoable.Count -gt 0) { "Mudanças sem desfazer por aqui" } else { "Últimas mudanças" })

            foreach ($change in $shown) {
                $suffix = $(if ($change.Undone) { " (desfeita)" } else { "" })
                Write-AgenteTIKeyValue -Label (Format-AgenteTIDateTime -When $change.At -Pattern "dd/MM HH:mm") -Value "$($change.Action): $($change.Text)$suffix" -LabelWidth 12
            }

            if ($others.Count -gt $shown.Count) {
                Write-AgenteTIStatus -Type Info -Message "E mais $(Format-AgenteTICount -Count ($others.Count - $shown.Count) -One 'mudança mais antiga' -Many 'mudanças mais antigas')."
            }

            Write-Host ""
        }

        if ($undoable.Count -eq 0) {
            # Limpezas e desinstalações não têm volta.
            Write-AgenteTIStatus -Type Info -Message "Nenhuma das mudanças anotadas pode ser desfeita por aqui; os ajustes saem em Ajustes do Windows > Desfazer ajustes do AgenteTI."
            Exit-AgenteTIAction
            return
        }

        $options = @(
            foreach ($change in $undoable) {
                @{ Key = $change.Id; Label = "$($change.Action): $($change.Text)"; Description = (Format-AgenteTIDateTime -When $change.At); Selected = $false }
            }
        )

        # Direto na lista: desfazer não apaga nada (volta ao que era), então marcar e confirmar basta, sem um Sim/Não a
        # mais. Cancelar (ou não marcar nada) é só ter olhado: a tela termina sem faixa de resultado.
        # Sem "marcar todos": desfazer tudo de uma vez, sem outra pergunta, inclui recursos do Windows e programas.
        $picked = Read-AgenteTIMultiSelect -Message "O que desfazer?" -Options $options -NoSelectAll -ConfirmLabel "Desfazer"

        if ($null -eq $picked -or @($picked).Count -eq 0) {
            Write-AgenteTIStatus -Type Info -Message "Nada foi desfeito."
            Exit-AgenteTIAction
            return
        }

        $chosen = @($undoable | Where-Object { @($picked) -contains $_.Id })

        $results = @()
        $reboot = $false

        foreach ($change in $chosen) {
            try {
                $result = Undo-AgenteTIChange -Change $change
            }
            catch {
                $result = New-AgenteTIResult -Kind Failed -Detail $_.Exception.Message.TrimEnd('.')
            }

            $result.Etapa = "$($change.Action) de $(Format-AgenteTIDateTime -When $change.At -Pattern 'dd/MM HH:mm')"

            if ($result.Kind -eq "Failed") {
                Write-AgenteTIStatus -Type Error -Message "$($result.Etapa): $($result.Detail)."
            }
            elseif ($result.Kind -eq "Warning") {
                # Deu certo só em parte (um item da inicialização, um adaptador): a mudança continua na lista para tentar
                # de novo, o que é seguro (o que já voltou fica como está).
                Write-AgenteTIStatus -Type Warning -Message "$($result.Etapa): $($result.Detail); a mudança continua na lista para tentar de novo."
            }
            else {
                Set-AgenteTIChangeUndone -Id $change.Id
                [void](Add-AgenteTIChange -Action "Desfeito" -Text "$($change.Action): $($change.Text)")
                Write-AgenteTIStatus -Type Success -Message "$($result.Etapa): $($result.Detail)."
            }

            if (Test-AgenteTIResultFlag -Result $result -Name "RebootRequired") { $reboot = $true }

            $results += $result
        }

        $failed = @($results | Where-Object { $_.Kind -eq "Failed" })
        # Desfeitas só em parte: não contam como desfeitas (continuam na lista), mas também não são falha completa.
        $partial = @($results | Where-Object { $_.Kind -eq "Warning" })
        $data = @{ RebootRequired = $reboot }

        if ($failed.Count -eq 0 -and $partial.Count -eq 0) {
            $final = New-AgenteTIResult -Kind Ok -Detail (Format-AgenteTICount -Count $results.Count -One "mudança desfeita" -Many "mudanças desfeitas") -Title $title -Data $data
        }
        elseif ($failed.Count -eq $results.Count) {
            $final = New-AgenteTIResult -Kind Failed -Detail $(if ($results.Count -eq 1) { $failed[0].Detail } else { "nenhuma mudança foi desfeita" }) -Title $title
        }
        elseif ($results.Count -eq 1) {
            $final = New-AgenteTIResult -Kind Warning -Detail "$($partial[0].Detail); a mudança continua na lista para tentar de novo" -Title $title -Data $data
        }
        else {
            $final = New-AgenteTIResult -Kind Warning -Detail "$($failed.Count + $partial.Count) de $($results.Count) não foram desfeitas por completo" -Title $title -Data $data
        }
    }
    catch {
        Write-AgenteTIStatus -Type Error -Message "Não foi possível ler o histórico: $($_.Exception.Message)"
        $final = New-AgenteTIResult -Kind Failed -Detail $_.Exception.Message -Title $title
    }

    Exit-AgenteTIAction -Result $final
}


Export-ModuleMember -Function *
