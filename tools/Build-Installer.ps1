#requires -Version 5.1
<#
.SYNOPSIS
    Gera o instalador do AgenteTI: dist\AgenteTI-Setup-<versão>.exe e o arquivo .sha256 ao lado.

.DESCRIPTION
    1. Lê a versão de modules\Core.psm1 ($script:AgenteTIBuild).
    2. Monta build\installer\payload com os arquivos que o AgenteTI precisa para rodar.
    3. Compila tools\installer\Launcher.cs em payload\AgenteTI.exe (abre a janela sem console).
    4. Compacta o payload em build\installer\payload.zip.
    5. Compila tools\installer\Setup.cs com o payload.zip embutido, o ícone e o manifesto que pede Administrador.
    6. Grava o SHA-256 do instalador em dist\AgenteTI-Setup-<versão>.exe.sha256.

    Usa o compilador C# do .NET Framework 4 (csc.exe), presente no Windows 10 e 11; não precisa de Visual Studio.
    As pastas build\ e dist\ são recriadas a cada execução e ficam fora do Git.

.PARAMETER Certificate
    Opcional: certificado de assinatura de código. Assina os scripts do payload, o AgenteTI.exe e o instalador.

.PARAMETER TimestampServer
    Servidor de carimbo de tempo usado com -Certificate.

.EXAMPLE
    .\tools\Build-Installer.ps1

.EXAMPLE
    $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Select-Object -First 1
    .\tools\Build-Installer.ps1 -Certificate $cert
#>
[CmdletBinding()]
param (
    [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,

    [string]$TimestampServer = "http://timestamp.digicert.com"
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$sourceDir = Join-Path $PSScriptRoot "installer"
$buildDir = Join-Path $root "build\installer"
$payloadDir = Join-Path $buildDir "payload"
$distDir = Join-Path $root "dist"
$iconPath = Join-Path $root "assets\AgenteTI.ico"

# O que vai para a pasta instalada. Ferramentas de desenvolvimento (tools\, configurações do Git e do editor) ficam de fora.
$payloadItems = @(
    "AgenteTI.cmd",
    "AgenteTI-Console.cmd",
    "AgenteTI.Gui.ps1",
    "AgenteTI.Console.ps1",
    "AgenteTI.Agent.ps1",
    "CHANGELOG.md",
    "LICENSE",
    "README.md",
    "assets",
    "catalog",
    "gui",
    "modules"
)


function Invoke-BuildCompiler {
    # Roda o csc.exe e para o build se a compilação falhar, mostrando os erros.
    param (
        [Parameter(Mandatory)][string]$Compiler,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $output = & $Compiler @Arguments 2>&1 | ForEach-Object { "$_" }

    if ($LASTEXITCODE -ne 0) {
        $output | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "A compilação falhou (csc.exe, código $LASTEXITCODE)."
    }

    $output | Where-Object { $_ -match "warning" } | ForEach-Object { Write-Warning $_ }
}


function Set-BuildSignature {
    # Assina os arquivos com o certificado informado (só quando -Certificate foi passado).
    param ([Parameter(Mandatory)][string[]]$Path)

    if ($null -eq $Certificate) {
        return
    }

    foreach ($file in $Path) {
        $result = Set-AuthenticodeSignature -FilePath $file -Certificate $Certificate -TimestampServer $TimestampServer -HashAlgorithm SHA256

        if ($result.Status -ne "Valid") {
            throw "Não foi possível assinar $file`: $($result.StatusMessage)"
        }
    }
}


# --- Versão ---------------------------------------------------------------------------------------------------------
$corePath = Join-Path $root "modules\Core.psm1"
$versionLine = Select-String -LiteralPath $corePath -Pattern '^\$script:AgenteTIBuild\s*=\s*"(\d+)\.(\d+)"' | Select-Object -First 1

if ($null -eq $versionLine) {
    throw "Versão não encontrada em $corePath (esperado: `$script:AgenteTIBuild = ""1.0"")."
}

$version = "{0}.{1}" -f $versionLine.Matches[0].Groups[1].Value, $versionLine.Matches[0].Groups[2].Value
$assemblyVersion = "$version.0.0"

if (-not (Select-String -LiteralPath (Join-Path $root "CHANGELOG.md") -Pattern ("^## " + [regex]::Escape($version) + "(\s|$)") -Quiet)) {
    Write-Warning "O CHANGELOG.md não tem a seção ""## $version""."
}

Write-Host "AgenteTI $version" -ForegroundColor Cyan

# --- Compilador -----------------------------------------------------------------------------------------------------
$compiler = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"

if (-not (Test-Path -LiteralPath $compiler)) {
    $compiler = Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe"
}

if (-not (Test-Path -LiteralPath $compiler)) {
    throw "Compilador C# do .NET Framework 4 não encontrado (csc.exe)."
}

# --- Pastas ---------------------------------------------------------------------------------------------------------
if (Test-Path -LiteralPath $buildDir) {
    Remove-Item -LiteralPath $buildDir -Recurse -Force
}

New-Item -ItemType Directory -Path $payloadDir -Force | Out-Null
New-Item -ItemType Directory -Path $distDir -Force | Out-Null

# --- Payload --------------------------------------------------------------------------------------------------------
foreach ($item in $payloadItems) {
    $source = Join-Path $root $item

    if (-not (Test-Path -LiteralPath $source)) {
        throw "Arquivo obrigatório não encontrado: $source"
    }

    Copy-Item -LiteralPath $source -Destination $payloadDir -Recurse -Force
}

# Versão e metadados comuns aos dois executáveis.
$buildInfoPath = Join-Path $buildDir "BuildInfo.cs"
@"
using System.Reflection;
[assembly: AssemblyProduct("AgenteTI")]
[assembly: AssemblyCompany("AgenteTI")]
[assembly: AssemblyCopyright("AgenteTI - GPL-3.0")]
[assembly: AssemblyVersion("$assemblyVersion")]
[assembly: AssemblyFileVersion("$assemblyVersion")]
[assembly: AssemblyInformationalVersion("$version")]
static class BuildInfo { public const string Version = "$version"; }
"@ | Set-Content -LiteralPath $buildInfoPath -Encoding UTF8

$commonArguments = @("/nologo", "/optimize+", "/codepage:65001", "/target:winexe", "/platform:anycpu", "/win32icon:$iconPath")

Write-Host "Compilando AgenteTI.exe..."
$launcherPath = Join-Path $payloadDir "AgenteTI.exe"
Invoke-BuildCompiler -Compiler $compiler -Arguments ($commonArguments + @(
        "/out:$launcherPath",
        "/reference:System.Windows.Forms.dll",
        (Join-Path $sourceDir "Launcher.cs"),
        $buildInfoPath
    ))

$payloadScripts = @(Get-ChildItem -LiteralPath $payloadDir -Recurse -File -Include *.ps1, *.psm1, *.psd1 | ForEach-Object { $_.FullName })
Set-BuildSignature -Path ($payloadScripts + $launcherPath)

Write-Host "Compactando os arquivos..."
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipPath = Join-Path $buildDir "payload.zip"
[System.IO.Compression.ZipFile]::CreateFromDirectory($payloadDir, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)

# --- Instalador -----------------------------------------------------------------------------------------------------
# O instalador grava em Arquivos de Programas e no HKLM: o manifesto pede Administrador ao abrir.
$manifestPath = Join-Path $buildDir "Setup.manifest"
@"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity version="$assemblyVersion" name="AgenteTI.Setup"/>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v2">
    <security>
      <requestedPrivileges xmlns="urn:schemas-microsoft-com:asm.v3">
        <requestedExecutionLevel level="requireAdministrator" uiAccess="false"/>
      </requestedPrivileges>
    </security>
  </trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
    </application>
  </compatibility>
</assembly>
"@ | Set-Content -LiteralPath $manifestPath -Encoding UTF8

$setupName = "AgenteTI-Setup-$version.exe"
$setupPath = Join-Path $distDir $setupName
$hashPath = "$setupPath.sha256"

# Só o instalador desta versão fica em dist\: os de versões anteriores (e o desta, se já existir) são apagados.
Get-ChildItem -LiteralPath $distDir -File -Filter "AgenteTI-Setup-*" |
    Where-Object { $_.Name -match '^AgenteTI-Setup-[0-9.]+\.exe(\.sha256)?$' } |
    Remove-Item -Force

Write-Host "Compilando $setupName..."
Invoke-BuildCompiler -Compiler $compiler -Arguments ($commonArguments + @(
        "/out:$setupPath",
        "/win32manifest:$manifestPath",
        "/resource:$zipPath,payload.zip",
        "/reference:System.IO.Compression.dll",
        "/reference:System.IO.Compression.FileSystem.dll",
        "/reference:System.Windows.Forms.dll",
        (Join-Path $sourceDir "Setup.cs"),
        $buildInfoPath
    ))

Set-BuildSignature -Path @($setupPath)

$hash = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash
"$hash  $setupName" | Set-Content -LiteralPath $hashPath -Encoding ASCII

$sizeMb = (Get-Item -LiteralPath $setupPath).Length / 1MB
Write-Host ("Instalador: {0} ({1:N2} MB)" -f $setupPath, $sizeMb) -ForegroundColor Green
Write-Host "SHA-256:    $hash" -ForegroundColor Green
