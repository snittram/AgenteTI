# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Visão geral

AgenteTI é uma ferramenta de manutenção/diagnóstico do Windows escrita inteiramente em **Windows PowerShell 5.1** (não PowerShell 7), com duas interfaces sobre os mesmos módulos: janela WPF (`AgenteTI.Gui.ps1` + `gui/MainWindow.xaml`) e menu de terminal (`AgenteTI.Console.ps1`). Textos de interface, comentários e mensagens são em português do Brasil.

## Executar

Não há linter nem suíte de testes no repositório (comentários como "um teste confere" citam testes que não existem). Para executar a partir do checkout:

```powershell
.\AgenteTI.cmd                                   # janela (abre sem Administrador)
.\AgenteTI-Console.cmd                           # menu de terminal
.\AgenteTI-Console.cmd -Action Check [-Json]     # verificação rápida, só leitura; exit 0/1/2/3 = ok/atenção/crítico/não avaliado
.\AgenteTI-Console.cmd -Action Report [-ReportDirectory <pasta>]
```

Ações válidas do console: `Menu`, `Report`, `Shortcut`, `ScheduledMaintenance`, `Check` (validadas manualmente em `AgenteTI.Console.ps1`, não com `ValidateSet`).

Os `.cmd` sempre usam o `powershell.exe` de 64 bits (via `Sysnative` quando chamados de processo 32 bits) — rodar com `pwsh` não reproduz o ambiente real.

Verificação rápida de sintaxe de um arquivo (substitui um linter):

```powershell
$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\modules\Core.psm1), [ref]$null, [ref]$e); $e
```

Para testar funções isoladamente, importe os módulos como os pontos de entrada fazem (lista `Common` do `Modules.psd1`, `Import-Module -Force -DisableNameChecking -Global`) num `powershell.exe` 5.1.

Armadilhas ao testar:
- Chamado a partir do PowerShell 7 ou de um shell que herdou o ambiente dele, o `powershell.exe` 5.1 recebe o `PSModulePath` do 7 e falha com "`Import-PowerShellDataFile` não é reconhecido". Limpe a variável antes (`env -u PSModulePath powershell.exe ...` no Bash, `$env:PSModulePath = $null` no PowerShell).
- Só pode haver uma janela do AgenteTI por usuário (trava `Local\AgenteTI.Window.<SID>`, em `GuiHost.psm1`). Uma segunda abertura só traz a janela existente para a frente; para testar a janela do repositório, a instalada precisa estar fechada (peça ao usuário).
- A janela grava tamanho, posição e se estava maximizada em `%LOCALAPPDATA%\AgenteTI\settings.json` (chave `Window`) ao fechar. Testes que maximizam ou redimensionam mudam a preferência do usuário; restaure-a depois (`Get-AgenteTISetting`/`Set-AgenteTISetting -Name Window`).
- `AgenteTI.Gui.ps1 -Page <id>` abre direto numa página da navegação (`home`, `app`, `diagnostics`...).

## Arquitetura

- **`modules/Modules.psd1`** é a única lista de módulos. Grupos: `Common` (importado em todos os contextos, inclusive no runspace das ações e no monitor da bandeja), `Console` (só `Menus`) e `Gui` (`GuiHost`, `GuiDesign`, só na thread da janela). Módulo novo precisa entrar aqui; os pontos de entrada o importam com `-Global -DisableNameChecking`.
- **`modules/Navigation.psm1`** é a tabela única de páginas e ações (`New-AgenteTINavPage` / `New-AgenteTINavItem`). A barra lateral da janela, os menus do console e a busca leem dela. Convenções documentadas no topo do arquivo: o `Label` de uma ação deve ser idêntico ao título que a ação exibe ao abrir; ordem dentro da página vai do mais seguro ao mais invasivo; `-Admin` marca ações que exigem elevação; `Command` é o nome da função a executar.
- **`modules/GuiHost.psm1`** contém um `PSHost` customizado em C# (compilado via `Add-Type`). Na janela, cada ação roda num runspace separado: `Write-Host`/progresso viram itens numa fila lida pela UI, e `Read-Host`/prompts viram pedidos com botões ou caixa de texto. Por isso os módulos de funcionalidade escrevem como se fossem console; perguntas devem passar pelas funções de `modules/Console.psm1` (que detectam o modo GUI com `Test-AgenteTIGuiPrompts`), não por `Read-Host` direto.
- **`AgenteTI.Gui.ps1`** (~240 KB) monta toda a UI WPF em código (helpers `New-Gui*`, temas claro/escuro, painel de atividade/resumo da execução). `GuiDesign.psm1` guarda tokens de design e ícones (`fact.<id>`, `<id do item>`).
  - Grade de cartões: `Update-GuiContentWidth` calcula colunas (até 4) e a largura dos cartões (recursos `CardWidth`/`WideCardWidth`, de 252 a 300) a partir do `ActualWidth` do `PageScroll`, **sempre reservando a largura da barra de rolagem**. Não use o `ViewportWidth`: ele muda quando a barra aparece, e a janela maximizada entrava em ciclo, alternando entre 4 e 3 cartões por linha.
- **`modules/Home.psm1`** (tela Início): cartões definidos em `$script:AgenteTIHomeFactLabels`, cada um preenchido por uma etapa (`Read-AgenteTIHome<Etapa>`) que a janela lê num runspace à parte, importando só os módulos de `Get-AgenteTIHomeReaderModules`; função nova usada na leitura precisa estar num deles. Cada cartão tem uma linha de valor e uma de complemento (`Value`/`Detail`, cortadas com "…"); a frase inteira (`Text`) vai para a dica, o leitor de tela e o `-Action Check -Json`. As etapas de `$script:AgenteTIHomeScoredSteps` entram na nota de saúde.
- **`AgenteTI.Agent.ps1`** é o monitor da bandeja (WinForms): só leitura, uma instância por sessão (mutex `Local\AgenteTI.Agent`), nunca roda elevado com UAC ligado.
- **`modules/Core.psm1`**: versão (`$script:AgenteTIBuild`), log de sessão e caminho de dados (`%LOCALAPPDATA%\AgenteTI`: logs, relatórios, estado, backups).
- **`catalog/catalog.json`**: catálogo de dados (ex.: ajustes/apps); `Catalog.psm1` baixa a cópia de `raw.githubusercontent.com/<repo>/main/catalog/catalog.json` e só a usa se passar na validação, senão usa a local.
- **Repositório**: `snittram/AgenteTI`, público (`Get-AgenteTIRepository` em `AppUpdate.psm1`, também usado pelo `Catalog.psm1` e pelos links do README). As cópias instaladas consultam esse nome: renomear o repositório ou torná-lo privado quebra o botão de atualizar delas, e a API sem login responde 404.
- **`AppUpdate.psm1`** (ação "Atualizar o AgenteTI"): consulta a release mais recente na API do GitHub e compara versões como `[version]`; só aceita downloads de `github.com/<repo>/releases/download/` com o SHA-256 do `digest` do GitHub. Cópia instalada (tem `Desinstalar.exe` na pasta) + release com `AgenteTI-Setup-<versão>.exe` → baixa para `%LOCALAPPDATA%\AgenteTI\updates` e executa `/S /RUN /CLOSE=$PID /D=<pasta>`; o instalador fecha o app, grava por cima e reabre. Cópia do ZIP → baixa o `AgenteTI.zip` para Downloads e a cópia é manual. Por isso cada release deve anexar o `AgenteTI-Setup-<versão>.exe` (e, para cópias portáteis, o `AgenteTI.zip`).
- **Elevação**: a janela abre sem Administrador; ações com `-Admin` na navegação chamam `Request-GuiAdministrator`, que reabre a janela elevada na mesma página. Mensagens que pedem elevação usam `Get-AgenteTIElevateHint` (`Console.psm1`).

## Convenções de arquivo (ver `.editorconfig`)

- `.ps1/.psm1/.psd1` **devem ser UTF-8 com BOM** — o PowerShell 5.1 lê acentos errado sem BOM. Ao criar/reescrever esses arquivos, preserve o BOM.
- `.cmd` em ASCII/latin1 sem BOM e sem acentos (os comentários `rem` são escritos sem acento de propósito).
- CRLF, indentação de 4 espaços (2 em XAML/JSON/YAML/SVG).
- Funções públicas usam o prefixo `AgenteTI` no substantivo (`Get-AgenteTIBuild`, `Start-AgenteTIGuiCommand`).

## Versão, changelog e distribuição

- A cada rodada de alterações de código, somar 1 ao número depois do ponto em `$script:AgenteTIBuild` (`modules/Core.psm1`): 1.0 → 1.1 … 1.9 → 1.10 (comparação via `[version]`), e registrar no `CHANGELOG.md` (datas DD/MM/AAAA).
- O README cita a versão na linha sobre assinatura ("os scripts da versão X"); mantenha-a igual à do `Core.psm1`.

### Publicar uma versão

Depois de subir a versão no `Core.psm1`, registrar no CHANGELOG e fazer o commit, o próprio Claude publica (pedido do usuário): `git push`, `git tag v<versão>` e `git push origin v<versão>`. Depois, acompanha a execução em Actions (`https://api.github.com/repos/snittram/AgenteTI/actions/runs`) e confere que a release mais recente tem o `AgenteTI-Setup-<versão>.exe`. Sem a tag, nada roda em Actions e o app não vê a versão nova. O fluxo `.github/workflows/release.yml` (Windows da nuvem) confere se a tag é igual a `v` + versão do `Core.psm1`, roda o `Build-Installer.ps1` e cria a release com o `AgenteTI-Setup-<versão>.exe` e o `.sha256` anexados e as notas da seção da versão no CHANGELOG. A release é criada como rascunho e só depois publicada, porque o repositório usa releases imutáveis (nada pode ser anexado ou trocado depois de publicar). O app lê a versão pelo nome da tag: uma tag sem número (ex.: "Atualizar") quebra o botão de atualizar. Uma release com erro não pode ser corrigida: a correção sai como a versão seguinte. No fluxo, os passos rodam no Windows PowerShell 5.1 (`shell: powershell`): para gravar em `$GITHUB_OUTPUT`, use UTF-8 sem BOM (`[IO.File]::AppendAllText`), porque o `Out-File -Encoding utf8` grava um BOM e a chave não é lida.

### Instalador

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-Installer.ps1 [-Certificate $cert]
```

- Lê a versão do `Core.psm1`, recria `build/installer/` (payload + `payload.zip` + `BuildInfo.cs` + manifesto gerados) e grava `dist/AgenteTI-Setup-<versão>.exe` + `.sha256`. `build/` e `dist/` estão no `.gitignore`.
- Compila com o `csc.exe` do .NET Framework 4 (só C# 5: sem interpolação, `?.`, `nameof`) e `/codepage:65001`.
- A lista do que entra no payload fica em `$payloadItems`, no script; arquivo novo na raiz precisa entrar lá.
- `tools/installer/Launcher.cs` → `AgenteTI.exe` (dentro do payload): abre `AgenteTI.Gui.ps1` com o PowerShell de 64 bits sem console (evita a janela do Terminal do Windows 11).
- `tools/installer/Setup.cs` → instalador com o payload embutido. Pede Administrador; instala em `%ProgramFiles%\AgenteTI`, cria atalhos para todos os usuários (com o AppUserModelID `AgenteTI.App`, o mesmo de `Launcher.psm1`), registra em `HKLM\...\Uninstall\AgenteTI` e copia a si mesmo como `Desinstalar.exe`. Parâmetros: `/S`, `/NODESKTOP`, `/RUN`, `/CLOSE=<pid>` (só fecha processos `powershell`), `/D=<pasta>` (último), `/UNINSTALL`. Rodar o instalador sobre uma instalação existente atualiza no lugar (não precisa desinstalar). A desinstalação apaga a pasta inteira, por isso só aceita pastas que contenham `AgenteTI.Gui.ps1`.
- `tools/Sign-AgenteTI.ps1 -Certificate <cert>` assina os scripts da pasta do projeto (Authenticode) e gera `SHA256SUMS.txt`.
