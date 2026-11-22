@echo off
rem AgenteTI - abre a janela (interface grafica). Para o menu de texto, use AgenteTI-Console.cmd.
setlocal
cd /d "%~dp0"

rem Aberto de dentro do zip (o Explorador extrai so este arquivo), com a pasta extraida pela metade ou com um arquivo
rem posto em quarentena pelo antivirus, o PowerShell abriria escondido e nada apareceria: avisa e para.
if not exist "%~dp0AgenteTI.Gui.ps1" goto faltam
if not exist "%~dp0modules\Modules.psd1" goto faltam

rem Remove a marca de "baixado da internet" dos arquivos extraidos (evita avisos de seguranca).
rem O caminho vai por variavel de ambiente para funcionar mesmo com aspas simples no nome da pasta.
set "AGENTETI_ROOT=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath $env:AGENTETI_ROOT -Recurse -File | Unblock-File" >nul 2>&1

rem O PowerShell de 64 bits: aberto por um programa de 32 bits, o System32 seria trocado pelo SysWOW64 e o
rem PowerShell de 32 bits leria outra parte do registro (inicializacao e ajustes errados). O Sysnative so existe
rem para processos de 32 bits e leva ao System32 de verdade.
set "AGENTETI_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "AGENTETI_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

rem A janela abre sem Administrador (sem o aviso do Windows); pede a permissao so quando uma acao precisar. Nenhum
rem console fica visivel.
start "" "%AGENTETI_PS%" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0AgenteTI.Gui.ps1"

endlocal
exit /b 0

:faltam
echo.
echo   Faltam arquivos do AgenteTI nesta pasta.
echo.
echo   Abra o AgenteTI.zip, clique em "Extrair tudo" e depois abra
echo   o AgenteTI.cmd que estiver na pasta nova.
echo.
pause
endlocal & exit /b 1
