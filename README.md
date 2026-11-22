<p align="center">
  <img src="assets/AgenteTI.svg" width="96" height="96" alt="Ícone do AgenteTI">
</p>

# AgenteTI

O **AgenteTI** é uma ferramenta open-source para manutenção, diagnóstico e gerenciamento do Windows. Desenvolvido em PowerShell, reúne recursos do sistema em uma interface gráfica e em um menu de terminal.

[Baixar a versão mais recente](https://github.com/SnittraM/AgenteTI/releases/latest/download/AgenteTI.zip) · [Ver todas as versões](https://github.com/SnittraM/AgenteTI/releases)

## O que você pode fazer

- **Diagnosticar o PC:** consultar informações do Windows, hardware, discos, rede, bateria e proteção.
- **Cuidar do sistema:** usar a verificação do PC, a manutenção guiada e ferramentas de reparo como DISM, SFC e CHKDSK.
- **Liberar espaço:** analisar o armazenamento e acessar opções de limpeza, arquivos duplicados e atalhos quebrados.
- **Gerenciar programas:** instalar, atualizar e remover aplicativos com o winget e revisar itens de inicialização.
- **Atualizar o Windows:** consultar atualizações e drivers disponíveis e acompanhar a instalação pela interface.
- **Acompanhar a segurança:** consultar o estado da proteção e usar as verificações do Windows Defender.
- **Personalizar o Windows:** aplicar ajustes e desfazer os que oferecem suporte à reversão.
- **Acompanhar o histórico:** gerar relatórios, consultar mudanças e, se desejar, habilitar a manutenção agendada ou o monitor na bandeja.

O AgenteTI reúne ferramentas do Windows e ações próprias. Algumas operações alteram configurações ou removem arquivos; confira as opções apresentadas antes de executá-las.

## Requisitos

- Windows 10 ou Windows 11.
- Windows PowerShell 5.1, incluído no Windows 10 e 11.
- Permissão de administrador para funções que precisam alterar ou consultar partes protegidas do sistema.
- [winget](https://learn.microsoft.com/pt-br/windows/package-manager/winget/) para os recursos de gerenciamento de programas.
- Conexão com a internet para downloads, atualizações e demais recursos online.

## Download e primeiros passos

1. Baixe **AgenteTI.zip** pela [release mais recente](https://github.com/SnittraM/AgenteTI/releases/latest).
2. Confira se o arquivo veio do repositório oficial. Para verificar a integridade, compare o SHA-256 do ZIP com o informado junto ao arquivo na release:

   ```powershell
   Get-FileHash -LiteralPath "$env:USERPROFILE\Downloads\AgenteTI.zip" -Algorithm SHA256
   ```

   Se o arquivo estiver em outra pasta, ajuste o caminho no comando.

3. Nas propriedades do ZIP, marque **Desbloquear** se a opção aparecer e você confiar na origem do arquivo.
4. Extraia a pasta inteira. Uma opção é extrair para `C:\Program Files`, criando `C:\Program Files\AgenteTI`; o Windows pode pedir permissão para gravar nesse local.
5. Abra **AgenteTI.cmd** para a interface gráfica ou **AgenteTI-Console.cmd** para o menu de terminal.
6. A janela abre sem administrador, sem o pedido de permissão do Windows. Quando uma função precisa de elevação, o AgenteTI pergunta e se reabre como administrador na mesma página; a partir daí, todas as funções seguem liberadas até a janela ser fechada. O link **Reabrir como Administrador**, no pé da barra lateral, faz o mesmo a qualquer momento.

Não execute os arquivos de dentro do ZIP: o AgenteTI precisa da estrutura completa de pastas.

## Segurança e dados

- **Permissões:** ações de limpeza, reparo, atualização e ajustes podem alterar o sistema. Mantenha seus backups e confira o que será executado; nem toda ação pode ser desfeita.
- **Inicialização:** os lançadores `.cmd` iniciam o PowerShell com `ExecutionPolicy Bypass` para o processo e, ao abrir a janela ou o menu, removem recursivamente o bloqueio de arquivos baixados dentro da pasta do AgenteTI. Use uma pasta exclusiva para o aplicativo e confira a origem dos arquivos.
- **Assinatura:** os scripts da versão 1.1 não estão assinados digitalmente. O Windows pode apresentar avisos ao abrir arquivos baixados.
- **Dados locais:** logs, relatórios e arquivos de estado ficam principalmente em `%LOCALAPPDATA%\AgenteTI`. Relatórios e logs podem conter informações do computador; confira seu conteúdo antes de compartilhá-los.
- **Recursos online:** algumas funções acessam serviços externos, como GitHub, winget, Windows Update e serviços de rede. O monitor na bandeja e a manutenção agendada são opcionais.
- **Backup antes de formatar:** o recurso pode guardar lista de programas, drivers, ajustes e, opcionalmente, redes Wi-Fi. Ele **não copia documentos, fotos ou outros arquivos pessoais**. Se você incluir redes Wi-Fi, as senhas são armazenadas em texto puro; proteja o backup.

## Atualizar o AgenteTI

Em **Sobre o AgenteTI > Atualizar o AgenteTI**, o aplicativo consulta a release mais recente no GitHub.

- **Instalado pelo instalador** (`AgenteTI-Setup-<versão>.exe`): o AgenteTI baixa o instalador da nova versão, confere o SHA-256, pede a permissão do Windows, fecha, instala por cima e abre de novo. Não é preciso desinstalar: atalhos e dados são mantidos.
- **Cópia extraída do ZIP:** o AgenteTI baixa o ZIP conferindo o SHA-256, e a substituição dos arquivos é manual. Feche o AgenteTI e o monitor na bandeja, se estiver aberto, extraia a nova versão em outra pasta e copie o conteúdo da pasta `AgenteTI` extraída para a pasta da instalação anterior, substituindo os arquivos. Mantenha a estrutura de pastas completa.

Também é possível baixar o instalador da nova versão pela página de releases e executá-lo: ele atualiza a instalação existente sem desinstalar.

Os dados locais ficam em `%LOCALAPPDATA%\AgenteTI`; não apague essa pasta se quiser preservar logs, histórico e backups. Se você mover a pasta do programa, confira seus atalhos e o agendamento, caso estejam configurados.

## Linha de comando

No PowerShell, dentro da pasta do AgenteTI:

```powershell
.\AgenteTI-Console.cmd -Action Check        # verificação rápida
.\AgenteTI-Console.cmd -Action Check -Json  # saída em JSON
.\AgenteTI-Console.cmd -Action Report       # relatório HTML e texto
```

A ação `Check` faz consultas e não exige administrador; algumas informações podem ficar indisponíveis sem elevação.

## Como relatar um problema

[Abra uma issue](https://github.com/SnittraM/AgenteTI/issues/new)
informando:

- Versão do AgenteTI.
- Versão e build do Windows.
- Interface utilizada: gráfica ou terminal.
- Função executada e passos para reproduzir o problema.
- Resultado esperado e o que aconteceu.
- Mensagem de erro completa ou captura de tela.

Se compartilhar logs ou relatórios de
`%LOCALAPPDATA%\AgenteTI`, confira o conteúdo
e remova informações pessoais antes de enviar.

## Documentação e projeto

- [Histórico de mudanças](CHANGELOG.md) e [releases](https://github.com/SnittraM/AgenteTI/releases).
- `AgenteTI.Gui.ps1` e `gui/`: interface gráfica.
- `AgenteTI.Console.ps1`: interface de terminal.
- `modules/`: funcionalidades compartilhadas; `assets/`: ícones.

## Licença

Distribuído sob a licença [GNU GPLv3](LICENSE).

© 2026 SnittraM
