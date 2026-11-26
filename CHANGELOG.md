# Changelog

Numeração: começa em 1.0 e sobe +1 depois do ponto a cada alteração (1.0 → 1.1 → 1.2 … 1.9 → 1.10 → 1.11).
A versão fica em `modules\Core.psm1` (`$script:AgenteTIBuild`).

## 1.6 (26/11/2026)

- **Escanear a rede** ganhou tela própria na janela, no lugar do texto: tabela de aparelhos com ícone por tipo (celular, computador, impressora, câmera, roteador, TV, casa inteligente, servidor), situação **Online** ou **Fora do ar** (os que saíram ficam esmaecidos), "visto por último", fabricante, IP e MAC. Filtros por tipo (com a contagem de cada um) e por situação (online, fora do ar, novos), busca por nome, IP, MAC ou fabricante e ordenação clicando no título da coluna. Clicar num aparelho abre os detalhes: primeira e última vez visto, portas abertas e o que cada uma indica, e botões para abrir a página do aparelho e copiar o IP ou o MAC. O cartão **Segurança da rede** aponta aparelhos novos nas últimas 24 horas, Área de Trabalho Remota aberta e aparelhos sem tipo; cada item filtra a tabela. **Exportar CSV** salva a lista para o Excel.
- O escaneamento só roda quando você clica em **Escanear agora**; ao abrir, a tela mostra o último escaneamento guardado. Ele roda em segundo plano: a janela continua respondendo. No menu de terminal, a ação continua em texto.

## 1.5 (26/11/2026)

- Rede: nova ação **Escanear a rede**, no grupo "Ver e testar". Encontra os aparelhos ligados à rede local (ping em paralelo e tabela ARP, o que acha também os que bloqueiam o ping) e mostra IP, nome, fabricante (pela lista de prefixos MAC do Wireshark, baixada uma vez e renovada a cada 90 dias), MAC e o tipo provável (roteador, impressora, câmera, computador, celular...), adivinhado pelo fabricante e por algumas portas comuns. Guarda o histórico de cada rede e mostra os aparelhos que entraram (marcados como NOVO) e os que saíram desde o escaneamento anterior; o botão **Escanear de novo** repete a varredura para acompanhar a rede. Redes maiores que /22 são escaneadas só no /24 do PC.

## 1.4 (22/11/2026)

- Ajustes do Windows: nova ação **Limite de anexos do Outlook**, a primeira da página. Mostra o limite de agora e grava o tamanho máximo de anexo do Outlook clássico (`MaximumAttachmentSize`, em KB, em `HKCU\Software\Microsoft\Office\<versão>\Outlook\Preferences`): 25, 50, 100 ou 150 MB, outro valor de 1 a 2048 MB, ou a volta ao padrão do Outlook (20 MB). Avisa que o servidor de e-mail tem limite próprio e que o Outlook precisa ser reaberto.

## 1.3 (22/11/2026)

- Janela maximizada: os cartões não ficam mais trocando de lugar sem parar (alternavam entre 4 e 3 por linha quando a barra de rolagem aparecia e sumia). A largura da grade agora reserva sempre o espaço da barra de rolagem.

## 1.2 (22/11/2026)

- Início: o cartão **Espaço livre nos discos** (antes "Disco do sistema") mostra o espaço livre de todos os discos internos, com o do Windows primeiro (por exemplo, `C: 41,4 GB · B: 94,3 GB`). A nota de saúde continua avaliando só o disco do Windows; outro disco quase cheio deixa o cartão em amarelo e aparece no complemento.
- `tools\Build-Installer.ps1` deixa em `dist\` só o instalador da versão gerada.

## 1.1 (22/11/2026)

- **Atualizar o AgenteTI** (antes "Verificar nova versão", em Sobre o AgenteTI): numa cópia instalada pelo instalador, baixa o `AgenteTI-Setup` da nova versão, confere o SHA-256, fecha o AgenteTI, instala por cima e o reabre, sem desinstalar. Cópias extraídas do zip continuam com o download do zip e a cópia manual.
- Instalador: novos parâmetros `/CLOSE=<pid>` (fecha o AgenteTI aberto antes de gravar) e `/RUN` (abre o AgenteTI ao terminar).
- A janela abre sem Administrador, sem o aviso do Windows; quando uma ação precisa, o AgenteTI pergunta e se reabre elevado na mesma página. Novo link **Reabrir como Administrador** no pé da barra lateral.
- Os atalhos criados pelo AgenteTI usam o `AgenteTI.exe` quando ele está na pasta (sem a janela preta do Terminal do Windows 11).
- Ícone do AgenteTI atualizado.

## 1.0 (22/11/2026)

- Primeira versão publicada do AgenteTI; as versões foram reiniciadas em 1.0 (antes, Build 3.69).
- Instalador `AgenteTI-Setup-<versão>.exe`, gerado por `tools\Build-Installer.ps1`, com ícone e todos os arquivos compactados; instalação silenciosa com `/S`.
- `AgenteTI.exe`: abre a janela sem a janela preta do Terminal do Windows 11; os atalhos criados pelo instalador o usam.
