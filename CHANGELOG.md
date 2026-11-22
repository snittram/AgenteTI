# Changelog

Numeração: começa em 1.0 e sobe +1 depois do ponto a cada alteração (1.0 → 1.1 → 1.2 … 1.9 → 1.10 → 1.11).
A versão fica em `modules\Core.psm1` (`$script:AgenteTIBuild`).

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
