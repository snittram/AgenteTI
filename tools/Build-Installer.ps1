#requires -Version 5.1
<#
.SYNOPSIS
    Gera dist\AgenteTI-Setup-<versão>.exe: instalador único, com o ícone do AgenteTI e todos os arquivos compactados.

.DESCRIPTION
    Não depende de ferramentas externas: usa o compilador C# (csc.exe) do .NET Framework 4, presente no Windows 10/11.
    Entram no pacote os arquivos versionados no Git (na versão atual da pasta), menos a pasta tools e os arquivos de
    configuração do repositório. Também grava o SHA-256 do instalador ao lado dele.

.EXAMPLE
    .\tools\Build-Installer.ps1
#>
[CmdletBinding()]
param ()

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$installerSrc = Join-Path $PSScriptRoot "installer"
$buildDir = Join-Path $root "build\installer"
$distDir = Join-Path $root "dist"
$icon = Join-Path $root "assets\AgenteTI.ico"

# Versão do aplicativo (Core.psm1: $script:AgenteTIBuild = "1.0").
$coreText = Get-Content -LiteralPath (Join-Path $root "modules\Core.psm1") -Raw -Encoding UTF8
if ($coreText -notmatch '\$script:AgenteTIBuild\s*=\s*"([0-9.]+)"') { throw "Versão não encontrada em modules\Core.psm1." }
$version = $Matches[1]
$numericVersion = (@($version.Split(".")) + @("0", "0", "0"))[0..3] -join "."

$csc = Join-Path $env:SystemRoot "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path -LiteralPath $csc)) { $csc = Join-Path $env:SystemRoot "Microsoft.NET\Framework\v4.0.30319\csc.exe" }
if (-not (Test-Path -LiteralPath $csc)) { throw "csc.exe do .NET Framework 4 não encontrado." }
if (-not (Test-Path -LiteralPath $icon)) { throw "Ícone não encontrado: $icon" }

# Pasta de trabalho limpa.
if (Test-Path -LiteralPath $buildDir) { Remove-Item -LiteralPath $buildDir -Recurse -Force }
$payloadDir = Join-Path $buildDir "payload"
New-Item -ItemType Directory -Force -Path $payloadDir, $distDir | Out-Null

# Arquivos do pacote: os versionados no Git, exceto ferramentas de build e configuração do repositório.
Push-Location $root
try { $files = @(git ls-files) } finally { Pop-Location }
if ($LASTEXITCODE -ne 0 -or $files.Count -eq 0) { throw "Não foi possível listar os arquivos com 'git ls-files'." }

$excluded = '^(tools/|\.editorconfig$|\.gitattributes$|\.gitignore$|\.github/)'
$files = $files | Where-Object { $_ -notmatch $excluded }

foreach ($relative in $files) {
    $source = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
    $dest = Join-Path $payloadDir $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    Copy-Item -LiteralPath $source -Destination $dest
}

if (-not (Test-Path -LiteralPath (Join-Path $payloadDir "AgenteTI.Gui.ps1"))) { throw "AgenteTI.Gui.ps1 ficou fora do pacote." }

# AgenteTI.exe: abre a janela sem console (evita a janela preta do Terminal do Windows 11). Vai na raiz do pacote.
$frameworkDir = Split-Path -Parent $csc
& $csc /nologo /target:winexe /platform:anycpu /optimize+ /codepage:65001 `
    "/out:$(Join-Path $payloadDir 'AgenteTI.exe')" "/win32icon:$icon" `
    /reference:System.Windows.Forms.dll (Join-Path $installerSrc "Launcher.cs")
if ($LASTEXITCODE -ne 0) { throw "Falha ao compilar o AgenteTI.exe (csc.exe saiu com $LASTEXITCODE)." }
$files = @($files) + "AgenteTI.exe"

# Compacta (nomes com "/" para o ZipArchive do instalador).
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zipPath = Join-Path $buildDir "payload.zip"
[System.IO.Compression.ZipFile]::CreateFromDirectory($payloadDir, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)

# Versão e metadados que aparecem nas Propriedades do .exe.
$buildInfo = Join-Path $buildDir "BuildInfo.cs"
@"
using System.Reflection;
[assembly: AssemblyTitle("Instalador do AgenteTI")]
[assembly: AssemblyProduct("AgenteTI")]
[assembly: AssemblyDescription("Instalador do AgenteTI")]
[assembly: AssemblyCompany("AgenteTI")]
[assembly: AssemblyCopyright("AgenteTI - GPL-3.0")]
[assembly: AssemblyVersion("$numericVersion")]
[assembly: AssemblyFileVersion("$numericVersion")]
[assembly: AssemblyInformationalVersion("$version")]
static class BuildInfo { public const string Version = "$version"; }
"@ | Set-Content -LiteralPath $buildInfo -Encoding UTF8

$output = Join-Path $distDir "AgenteTI-Setup-$version.exe"
$frameworkDir = Split-Path -Parent $csc

$cscArgs = @(
    "/nologo", "/target:winexe", "/platform:anycpu", "/optimize+", "/codepage:65001",
    "/out:$output",
    "/win32icon:$icon",
    "/win32manifest:$(Join-Path $installerSrc 'Setup.manifest')",
    "/resource:$zipPath,payload.zip",
    "/reference:$(Join-Path $frameworkDir 'System.IO.Compression.dll')",
    "/reference:$(Join-Path $frameworkDir 'System.IO.Compression.FileSystem.dll')",
    "/reference:System.Windows.Forms.dll",
    (Join-Path $installerSrc "Setup.cs"),
    $buildInfo
)

& $csc @cscArgs
if ($LASTEXITCODE -ne 0) { throw "Falha ao compilar o instalador (csc.exe saiu com $LASTEXITCODE)." }

$hash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash
"$hash  $(Split-Path -Leaf $output)" | Set-Content -LiteralPath "$output.sha256" -Encoding ASCII

$size = [math]::Round((Get-Item -LiteralPath $output).Length / 1MB, 2)
Write-Host ""
Write-Host "Instalador gerado: $output ($size MB, $($files.Count) arquivos)" -ForegroundColor Green
Write-Host "SHA-256: $hash"
