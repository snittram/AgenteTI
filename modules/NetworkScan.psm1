# Rede: escaneamento da rede local (aparelhos conectados, fabricante, tipo provável) e acompanhamento do que entra e
# sai entre um escaneamento e outro, no estilo dos aplicativos de varredura de rede. Só lê: não muda nada no PC nem nos
# aparelhos.

# Redes maiores que isto (máscara abaixo de /22) são escaneadas só no /24 do PC: mil endereços já levam alguns segundos.
$script:AgenteTINetworkScanMinPrefix = 22

# Portas consultadas em cada aparelho para adivinhar o tipo (só a abertura da conexão TCP, nada é enviado).
$script:AgenteTINetworkScanPorts = @(22, 80, 443, 445, 554, 631, 3389, 8080, 9100)

# A lista de fabricantes (prefixo do MAC) vem do projeto Wireshark e fica guardada; é renovada depois destes dias.
$script:AgenteTIVendorListUrl = "https://www.wireshark.org/download/automated/data/manuf"
$script:AgenteTIVendorListMaxAgeDays = 90

# Aparelhos que não aparecem há mais que isto saem do histórico da rede.
$script:AgenteTINetworkHistoryDays = 90


# ---------------------------------------------------------------------------
# Endereços
# ---------------------------------------------------------------------------

function ConvertTo-AgenteTIIpNumber {
    # IPv4 em texto para número (Int64, para as contas de máscara não esbarrarem no sinal).
    param ([Parameter(Mandatory)][string]$Address)

    $bytes = ([System.Net.IPAddress]::Parse($Address)).GetAddressBytes()
    return ([int64]$bytes[0] * 16777216) + ([int64]$bytes[1] * 65536) + ([int64]$bytes[2] * 256) + [int64]$bytes[3]
}


function ConvertFrom-AgenteTIIpNumber {
    param ([Parameter(Mandatory)][int64]$Number)

    return "{0}.{1}.{2}.{3}" -f (($Number -shr 24) -band 255), (($Number -shr 16) -band 255), (($Number -shr 8) -band 255), ($Number -band 255)
}


function Get-AgenteTIScanRange {
    <#
    Faixa a escanear a partir do IP e da máscara do PC. Devolve Network (texto "rede/prefixo"), First e Last (números dos
    endereços de aparelhos) e Reduced ($true quando a rede era grande demais e só o /24 do PC entra).
    #>
    param (
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][int]$PrefixLength
    )

    $reduced = $false
    $prefix = $PrefixLength

    if ($prefix -lt $script:AgenteTINetworkScanMinPrefix) {
        $prefix = 24
        $reduced = $true
    }

    if ($prefix -gt 30) { return $null }

    $size = [int64][Math]::Pow(2, 32 - $prefix)
    $ipNumber = ConvertTo-AgenteTIIpNumber -Address $Address
    $network = [int64]([Math]::Floor($ipNumber / $size) * $size)

    return [PSCustomObject]@{
        Network = "$(ConvertFrom-AgenteTIIpNumber -Number $network)/$prefix"
        First   = $network + 1
        Last    = $network + $size - 2
        Reduced = $reduced
    }
}


function ConvertTo-AgenteTIMacKey {
    # MAC em qualquer formato ("aa-bb-cc...", "AA:BB:...") para 12 dígitos hexadecimais maiúsculos; "" se não for um MAC.
    param ([AllowNull()][string]$Mac)

    $hex = ([string]$Mac).ToUpperInvariant() -replace "[^0-9A-F]", ""
    if ($hex.Length -ne 12) { return "" }

    return $hex
}


function Format-AgenteTIMac {
    param ([string]$Key)

    if ($Key.Length -ne 12) { return $Key }
    return (($Key -split "(..)" | Where-Object { $_ }) -join ":")
}


function Test-AgenteTIRandomMac {
    # MAC "administrado localmente" (2º bit do 1º byte): é o endereço privado/aleatório que celulares e o próprio Windows
    # usam no Wi-Fi. Não tem fabricante.
    param ([string]$Key)

    if ($Key.Length -ne 12) { return $false }
    return (([Convert]::ToInt32($Key.Substring(0, 2), 16) -band 2) -ne 0)
}


function Get-AgenteTIScanInterface {
    <#
    A conexão usada para a internet (a rota padrão de menor métrica) com IPv4: InterfaceIndex, Alias, Address, PrefixLength,
    Gateway e Mac (deste PC). $null se o PC não estiver numa rede com gateway.
    #>
    $routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -and $_.NextHop -ne "0.0.0.0" } |
        Sort-Object -Property @{ Expression = { [int]$_.RouteMetric + [int]$_.InterfaceMetric } })

    foreach ($route in $routes) {
        $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
        if ($null -eq $adapter -or $adapter.Status -ne "Up") { continue }

        $ip = @(Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike "169.254.*" -and $_.AddressState -eq "Preferred" }) | Select-Object -First 1
        if ($null -eq $ip) { continue }

        return [PSCustomObject]@{
            InterfaceIndex = [int]$route.InterfaceIndex
            Alias          = [string]$adapter.Name
            Address        = [string]$ip.IPAddress
            PrefixLength   = [int]$ip.PrefixLength
            Gateway        = [string]$route.NextHop
            Mac            = ConvertTo-AgenteTIMacKey -Mac ([string]$adapter.MacAddress)
        }
    }

    return $null
}


# ---------------------------------------------------------------------------
# Descoberta
# ---------------------------------------------------------------------------

function Wait-AgenteTITaskList {
    # Espera uma lista de tarefas .NET até o tempo dado, sem lançar erro pelas que falharam ou não terminaram.
    param (
        [AllowEmptyCollection()][object[]]$Tasks,
        [int]$TimeoutMs
    )

    if (@($Tasks).Count -eq 0) { return }

    try {
        [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($Tasks), $TimeoutMs)
    }
    catch {
        # Uma tarefa com erro (aparelho que recusou, nome sem registro) não interessa: quem lê olha o estado de cada uma.
        Write-Verbose "Tarefas com erro: $($_.Exception.Message)"
    }
}


function Invoke-AgenteTIPingSweep {
    # Manda um ping para cada endereço da faixa, em lotes paralelos. Devolve os IPs que responderam. O ping também faz o
    # Windows perguntar o MAC de cada endereço (ARP), e é isso que revela os aparelhos que bloqueiam o ping.
    param (
        [Parameter(Mandatory)][int64]$First,
        [Parameter(Mandatory)][int64]$Last,
        [int]$TimeoutMs = 1000,
        [int]$BatchSize = 128
    )

    $alive = New-Object System.Collections.Generic.List[string]
    $total = $Last - $First + 1
    $done = 0

    for ($start = $First; $start -le $Last; $start += $BatchSize) {
        $end = [Math]::Min($Last, $start + $BatchSize - 1)
        Write-Progress -Activity "Escaneando a rede" -Status "Procurando aparelhos: $done de $total endereços" -PercentComplete ([int]($done * 60 / $total))

        $pending = @()

        for ($n = $start; $n -le $end; $n++) {
            $address = ConvertFrom-AgenteTIIpNumber -Number $n
            $ping = New-Object System.Net.NetworkInformation.Ping

            try {
                $pending += [PSCustomObject]@{ Address = $address; Ping = $ping; Task = $ping.SendPingAsync($address, $TimeoutMs) }
            }
            catch {
                $ping.Dispose()
            }
        }

        Wait-AgenteTITaskList -Tasks @($pending | ForEach-Object { $_.Task }) -TimeoutMs ($TimeoutMs + 1500)

        foreach ($item in $pending) {
            if ($item.Task.Status -eq "RanToCompletion" -and $item.Task.Result.Status -eq "Success") {
                $alive.Add($item.Address)
            }

            $item.Ping.Dispose()
        }

        $done += ($end - $start + 1)
    }

    return @($alive)
}


function Get-AgenteTINeighborMacs {
    # Tabela ARP da conexão: IP -> MAC. Só entram as entradas confirmadas agora (Reachable); uma "Stale" pode ser de um
    # aparelho que já saiu. Quem respondeu ao ping entra mesmo com a entrada ainda em outro estado.
    param (
        [Parameter(Mandatory)][int]$InterfaceIndex,
        [string[]]$PingReplies = @()
    )

    $map = @{}
    $replied = @{}
    foreach ($address in $PingReplies) { $replied[$address] = $true }

    foreach ($entry in @(Get-NetNeighbor -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        $key = ConvertTo-AgenteTIMacKey -Mac ([string]$entry.LinkLayerAddress)
        if (-not $key -or $key -eq "000000000000" -or $key -eq "FFFFFFFFFFFF") { continue }

        $state = [string]$entry.State
        if ($state -eq "Reachable" -or ($replied.ContainsKey([string]$entry.IPAddress) -and $state -ne "Unreachable" -and $state -ne "Incomplete")) {
            $map[[string]$entry.IPAddress] = $key
        }
    }

    return $map
}


function Resolve-AgenteTIHostNames {
    # Nome de cada IP pelo DNS reverso (o Windows também tenta NetBIOS/LLMNR). Devolve IP -> nome curto, só dos que
    # responderam dentro do tempo.
    param (
        [string[]]$Addresses,
        [int]$TimeoutMs = 3000
    )

    $names = @{}
    $pending = @()

    foreach ($address in $Addresses) {
        try {
            $pending += [PSCustomObject]@{ Address = $address; Task = [System.Net.Dns]::GetHostEntryAsync($address) }
        }
        catch {
            Write-Verbose "Nome de $($address): $($_.Exception.Message)"
        }
    }

    Wait-AgenteTITaskList -Tasks @($pending | ForEach-Object { $_.Task }) -TimeoutMs $TimeoutMs

    foreach ($item in $pending) {
        if ($item.Task.Status -ne "RanToCompletion") { continue }

        $hostName = [string]$item.Task.Result.HostName
        if ([string]::IsNullOrWhiteSpace($hostName) -or $hostName -eq $item.Address) { continue }

        # Sem o sufixo da rede local (".lan", ".home", o domínio da empresa): o nome curto é o que a pessoa reconhece.
        $short = ($hostName -split "\.")[0]
        if ($short -and $short -notmatch "^\d+$") { $names[$item.Address] = $short }
    }

    return $names
}


function Get-AgenteTIOpenPorts {
    # Tenta abrir uma conexão TCP em cada porta comum de cada aparelho (sem enviar nada). Devolve IP -> lista de portas
    # abertas. Lotes pequenos, para não abrir centenas de conexões de uma vez.
    param (
        [string[]]$Addresses,
        [int[]]$Ports = $script:AgenteTINetworkScanPorts,
        [int]$TimeoutMs = 800,
        [int]$BatchSize = 16
    )

    $open = @{}
    $list = @($Addresses)

    for ($i = 0; $i -lt $list.Count; $i += $BatchSize) {
        Write-Progress -Activity "Escaneando a rede" -Status "Identificando os aparelhos: $i de $($list.Count)" -PercentComplete (75 + [int]($i * 20 / [Math]::Max(1, $list.Count)))

        $pending = @()

        foreach ($address in @($list | Select-Object -Skip $i -First $BatchSize)) {
            foreach ($port in $Ports) {
                $client = New-Object System.Net.Sockets.TcpClient

                try {
                    $pending += [PSCustomObject]@{ Address = $address; Port = $port; Client = $client; Task = $client.ConnectAsync($address, $port) }
                }
                catch {
                    $client.Close()
                }
            }
        }

        Wait-AgenteTITaskList -Tasks @($pending | ForEach-Object { $_.Task }) -TimeoutMs $TimeoutMs

        foreach ($item in $pending) {
            if ($item.Task.Status -eq "RanToCompletion" -and $item.Client.Connected) {
                if (-not $open.ContainsKey($item.Address)) { $open[$item.Address] = @() }
                $open[$item.Address] += $item.Port
            }

            # Fechar a conexão que ainda não terminou faz a tarefa dela falhar depois, sem efeito para o AgenteTI.
            try { $item.Client.Close() } catch { Write-Verbose "Conexão já fechada." }
        }
    }

    return $open
}


# ---------------------------------------------------------------------------
# Fabricantes (prefixo do MAC)
# ---------------------------------------------------------------------------

function Get-AgenteTIVendorListPath {
    $folder = Join-Path (Get-AgenteTIDataPath) "cache"
    if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -Path $folder -ItemType Directory -Force) }

    return (Join-Path $folder "manuf.txt")
}


function Update-AgenteTIVendorList {
    # Baixa a lista de fabricantes quando não há uma guardada ou ela passou da idade. Só baixa um arquivo público: nenhum
    # dado da rede sai do PC. Devolve $true se há uma lista para usar (nova ou a antiga).
    $path = Get-AgenteTIVendorListPath
    $exists = Test-Path -LiteralPath $path -PathType Leaf

    if ($exists -and ((Get-Date) - (Get-Item -LiteralPath $path).LastWriteTime).TotalDays -lt $script:AgenteTIVendorListMaxAgeDays) {
        return $true
    }

    Enable-AgenteTITls12
    $partial = "$path.partial"
    $previous = $ProgressPreference
    $ProgressPreference = "SilentlyContinue"

    try {
        Invoke-WebRequest -Uri $script:AgenteTIVendorListUrl -OutFile $partial -UseBasicParsing -TimeoutSec 60 `
            -Headers @{ "User-Agent" = "AgenteTI/$(Get-AgenteTIBuild)" } -ErrorAction Stop

        # Um arquivo pequeno demais é uma página de erro, não a lista (que tem uns 3 MB).
        if ((Get-Item -LiteralPath $partial).Length -lt 500KB) { throw "a lista de fabricantes veio incompleta" }

        Move-Item -LiteralPath $partial -Destination $path -Force
        return $true
    }
    catch {
        Write-Verbose "Lista de fabricantes não baixada: $($_.Exception.Message)"
        return $exists
    }
    finally {
        $ProgressPreference = $previous
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
    }
}


function Find-AgenteTIVendors {
    <#
    Fabricante de cada MAC pela lista guardada. A lista tem prefixos de 24 bits (6 dígitos) e blocos menores de 28 e 36
    bits; vale o prefixo mais longo. Lê o arquivo uma vez e só guarda as linhas que interessam. Devolve MAC -> nome.
    #>
    param ([string[]]$MacKeys)

    $result = @{}
    $path = Get-AgenteTIVendorListPath
    $keys = @($MacKeys | Where-Object { $_ -and -not (Test-AgenteTIRandomMac -Key $_) } | Select-Object -Unique)

    if ($keys.Count -eq 0 -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $result }

    $wanted = @{}
    foreach ($key in $keys) { $wanted[$key.Substring(0, 6)] = $true }

    $found = @{}

    try {
        foreach ($line in [System.IO.File]::ReadLines($path)) {
            if ($line.Length -lt 8 -or $line[0] -eq "#") { continue }
            if (-not $wanted.ContainsKey($line.Substring(0, 8).Replace(":", ""))) { continue }

            $fields = $line.Split("`t")
            if ($fields.Count -lt 2) { continue }

            $prefixField = $fields[0].Trim()
            $bits = 24
            if ($prefixField.Contains("/")) { $bits = [int]($prefixField.Split("/")[1]); $prefixField = $prefixField.Split("/")[0] }

            $hex = $prefixField.Replace(":", "").ToUpperInvariant()
            $digits = [int]($bits / 4)
            if ($hex.Length -lt $digits) { continue }

            $name = $(if ($fields.Count -ge 3 -and $fields[2].Trim()) { $fields[2].Trim() } else { $fields[1].Trim() })
            $found[$hex.Substring(0, $digits)] = $name
        }
    }
    catch {
        Write-Verbose "Lista de fabricantes ilegível: $($_.Exception.Message)"
        return $result
    }

    foreach ($key in $keys) {
        foreach ($length in 9, 7, 6) {
            $prefix = $key.Substring(0, $length)
            if ($found.ContainsKey($prefix)) { $result[$key] = $found[$prefix]; break }
        }
    }

    return $result
}


function Get-AgenteTIShortVendor {
    # Nome do fabricante sem a razão social ("Samsung Electronics Co.,Ltd" -> "Samsung Electronics").
    param ([string]$Vendor)

    $name = $Vendor -replace "(?i)[,\s]+(co\.?,?\s*ltd\.?|ltd\.?|inc\.?|corp(oration)?\.?|gmbh|s\.?a\.?|llc|limited|technologies|technology|ag|b\.v\.)\.?$", ""
    $name = $name -replace "(?i)[,\s]+(co\.?,?\s*ltd\.?|ltd\.?|inc\.?|corp(oration)?\.?|limited)\.?$", ""
    $name = $name.Trim(" ", ",", ".")

    if ($name.Length -gt 32) { $name = $name.Substring(0, 31) + "…" }
    return $name
}


# ---------------------------------------------------------------------------
# Tipo provável
# ---------------------------------------------------------------------------

function Get-AgenteTINetworkDeviceKind {
    # Palpite do tipo do aparelho pelas portas abertas e pelo fabricante. É um palpite: a tela diz "provável".
    param (
        [string]$Vendor = "",
        [int[]]$Ports = @(),
        [bool]$IsGateway = $false,
        [bool]$IsSelf = $false,
        [bool]$RandomMac = $false
    )

    if ($IsSelf) { return "Este PC" }
    if ($IsGateway) { return "Roteador (gateway)" }

    if ($Ports -contains 9100 -or $Ports -contains 631) { return "Impressora" }
    if ($Vendor -match "(?i)hikvision|dahua|intelbras.*(dvr|nvr)|axis comm|reolink|uniview|ezviz|foscam|wyze") { return "Câmera / gravador" }
    if ($Ports -contains 554) { return "Câmera / gravador" }
    if ($Vendor -match "(?i)hewlett|\bhp inc|epson|brother|canon|lexmark|ricoh|kyocera|xerox|konica|oki electric|sharp corp|pantum|elgin") { return "Impressora" }
    if ($Ports -contains 3389) { return "Computador Windows" }
    if ($Vendor -match "(?i)espressif|tuya|shelly|sonoff|itead|broadlink|positivo tecnologia.*casa|wiz connected|signify|philips lighting") { return "Casa inteligente" }
    if ($Vendor -match "(?i)roku|chromecast|amazon|sonos|lg electronics|tcl|hisense|philco|aoc|vizio") { return "TV / multimídia" }
    if ($Vendor -match "(?i)tp-?link|ubiquiti|mikrotik|routerboard|cisco|aruba|ruckus|netgear|d-link|tenda|mercusys|huawei tech|zte|intelbras|multilaser|asustek.*router|juniper|fortinet|meraki|cambium") {
        if ($Ports -contains 445) { return "Computador / NAS" }
        return "Equipamento de rede"
    }
    if ($Vendor -match "(?i)synology|qnap|western digital|seagate|buffalo") { return "NAS (armazenamento)" }
    if ($Vendor -match "(?i)raspberry") { return "Raspberry Pi" }
    if ($Vendor -match "(?i)apple") { return $(if ($Ports -contains 445 -or $Ports -contains 22) { "Mac" } else { "Apple (iPhone, iPad, Mac)" }) }
    if ($Vendor -match "(?i)samsung|xiaomi|motorola|oneplus|oppo|vivo mobile|realme|huawei device|honor|nokia|google") {
        return $(if ($Ports -contains 445) { "Computador" } else { "Celular / tablet" })
    }
    if ($Ports -contains 445) { return "Computador" }
    if ($Ports -contains 22) { return "Linux / servidor" }
    if ($RandomMac) { return "Celular / notebook (MAC privado)" }
    if ($Ports -contains 80 -or $Ports -contains 443 -or $Ports -contains 8080) { return "Aparelho com página web" }

    return "Desconhecido"
}


# ---------------------------------------------------------------------------
# Histórico por rede
# ---------------------------------------------------------------------------

function Get-AgenteTINetworkHistoryPath {
    # Um arquivo por rede, identificado pelo MAC do roteador (o mesmo IP 192.168.0.1 existe em quase toda casa).
    param ([Parameter(Mandatory)][string]$NetworkKey)

    $folder = Join-Path (Get-AgenteTIDataPath) "network-scan"
    if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -Path $folder -ItemType Directory -Force) }

    return (Join-Path $folder (($NetworkKey -replace "[^0-9A-Za-z_.-]", "_") + ".json"))
}


function Read-AgenteTINetworkHistory {
    param ([Parameter(Mandatory)][string]$Path)

    $read = Read-AgenteTIStateFile -Path $Path
    if ($null -eq $read.Document) { return $null }

    return $read.Document
}


function Save-AgenteTINetworkHistory {
    # Junta o escaneamento de agora ao histórico: atualiza quem apareceu, guarda quem sumiu (por até 90 dias).
    param (
        [Parameter(Mandatory)][string]$Path,
        $Previous,
        [Parameter(Mandatory)][object[]]$Devices,
        [Parameter(Mandatory)][string]$Network,
        [Parameter(Mandatory)][string]$Stamp,
        [string]$Gateway = "",
        [string]$Connection = ""
    )

    $byMac = [ordered]@{}

    if ($null -ne $Previous -and $null -ne $Previous.Devices) {
        foreach ($old in @($Previous.Devices)) {
            $lastSeen = ConvertFrom-AgenteTIScanStamp -Stamp ([string]$old.LastSeen)
            if ($null -eq $lastSeen -or ((Get-Date) - $lastSeen).TotalDays -gt $script:AgenteTINetworkHistoryDays) { continue }

            $byMac[[string]$old.Mac] = [ordered]@{
                Mac = [string]$old.Mac; Ip = [string]$old.Ip; Name = [string]$old.Name; Vendor = [string]$old.Vendor
                Kind = [string]$old.Kind; Ports = @($old.Ports | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ })
                RandomMac = [bool]$old.RandomMac; IsGateway = [bool]$old.IsGateway; IsSelf = [bool]$old.IsSelf
                FirstSeen = [string]$old.FirstSeen; LastSeen = [string]$old.LastSeen
            }
        }
    }

    foreach ($device in $Devices) {
        $firstSeen = $(if ($byMac.Contains($device.Mac)) { $byMac[$device.Mac].FirstSeen } else { $Stamp })
        $name = $(if ($device.Name) { $device.Name } elseif ($byMac.Contains($device.Mac)) { $byMac[$device.Mac].Name } else { "" })

        $byMac[$device.Mac] = [ordered]@{
            Mac = $device.Mac; Ip = $device.Ip; Name = $name; Vendor = $device.Vendor
            Kind = $device.Kind; Ports = @($device.Ports); RandomMac = [bool]$device.RandomMac
            IsGateway = [bool]$device.IsGateway; IsSelf = [bool]$device.IsSelf
            FirstSeen = $firstSeen; LastSeen = $Stamp
        }
    }

    $firstScan = $Stamp
    if ($null -ne $Previous -and [string]$Previous.FirstScan) { $firstScan = [string]$Previous.FirstScan }
    elseif ($null -ne $Previous -and [string]$Previous.LastScan) { $firstScan = [string]$Previous.LastScan }

    $document = [ordered]@{
        Network    = $Network
        Gateway    = $Gateway
        Connection = $Connection
        FirstScan  = $firstScan
        LastScan   = $Stamp
        Devices    = @($byMac.Values)
    }

    Invoke-AgenteTIStateLock -ScriptBlock { Write-AgenteTIStateJson -Path $Path -InputObject $document -Depth 5 }
}


function ConvertFrom-AgenteTIScanStamp {
    # A data guardada no histórico (ISO 8601) em [datetime] local; $null se não for uma data.
    param ([AllowNull()][string]$Stamp)

    $value = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Stamp, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$value)) {
        return $value.ToLocalTime()
    }

    return $null
}


function Format-AgenteTIScanStamp {
    param ([string]$Stamp)

    $value = ConvertFrom-AgenteTIScanStamp -Stamp $Stamp
    if ($null -ne $value) {
        return $value.ToString("dd/MM/yyyy HH:mm")
    }

    return $Stamp
}


# ---------------------------------------------------------------------------
# Escaneamento
# ---------------------------------------------------------------------------

function Invoke-AgenteTINetworkScanPass {
    <#
    Um escaneamento completo da rede da conexão. Devolve Network, Reduced e Devices (Ip, Mac, Name, Vendor, Kind, Ports,
    IsSelf, IsGateway, RandomMac), em ordem de IP.
    #>
    param ([Parameter(Mandatory)]$Interface)

    $range = Get-AgenteTIScanRange -Address $Interface.Address -PrefixLength $Interface.PrefixLength
    if ($null -eq $range) { return $null }

    try {
        $replies = @(Invoke-AgenteTIPingSweep -First $range.First -Last $range.Last)

        Write-Progress -Activity "Escaneando a rede" -Status "Lendo os endereços físicos (MAC)" -PercentComplete 62
        $macs = Get-AgenteTINeighborMacs -InterfaceIndex $Interface.InterfaceIndex -PingReplies $replies

        $first = $range.First
        $last = $range.Last
        $addresses = @(@($macs.Keys) + $replies + @($Interface.Address) | Select-Object -Unique | Where-Object {
                $number = ConvertTo-AgenteTIIpNumber -Address $_
                $number -ge $first -and $number -le $last
            })

        Write-Progress -Activity "Escaneando a rede" -Status "Procurando os nomes dos aparelhos" -PercentComplete 68
        $names = Resolve-AgenteTIHostNames -Addresses $addresses

        $others = @($addresses | Where-Object { $_ -ne $Interface.Address })
        $ports = Get-AgenteTIOpenPorts -Addresses $others

        Write-Progress -Activity "Escaneando a rede" -Status "Procurando os fabricantes" -PercentComplete 96
        $macKeys = @($addresses | ForEach-Object { if ($_ -eq $Interface.Address) { $Interface.Mac } else { [string]$macs[$_] } } | Where-Object { $_ })
        [void](Update-AgenteTIVendorList)
        $vendors = Find-AgenteTIVendors -MacKeys $macKeys
    }
    finally {
        Write-Progress -Activity "Escaneando a rede" -Completed
    }

    $devices = foreach ($address in $addresses) {
        $isSelf = ($address -eq $Interface.Address)
        $mac = $(if ($isSelf) { $Interface.Mac } else { [string]$macs[$address] })
        $randomMac = Test-AgenteTIRandomMac -Key $mac
        $vendor = $(if ($vendors.ContainsKey($mac)) { Get-AgenteTIShortVendor -Vendor $vendors[$mac] } elseif ($randomMac) { "MAC privado" } else { "" })
        $openPorts = @($(if ($ports.ContainsKey($address)) { $ports[$address] }))
        $name = $(if ($isSelf) { $env:COMPUTERNAME } elseif ($names.ContainsKey($address)) { $names[$address] } else { "" })

        [PSCustomObject]@{
            Ip        = $address
            Mac       = $(if ($mac) { $mac } else { "IP-$address" })
            Name      = $name
            Vendor    = $vendor
            Kind      = Get-AgenteTINetworkDeviceKind -Vendor $vendor -Ports $openPorts -IsGateway ($address -eq $Interface.Gateway) -IsSelf $isSelf -RandomMac $randomMac
            Ports     = $openPorts
            IsSelf    = $isSelf
            IsGateway = ($address -eq $Interface.Gateway)
            RandomMac = $randomMac
            Sort      = ConvertTo-AgenteTIIpNumber -Address $address
        }
    }

    return [PSCustomObject]@{
        Network = $range.Network
        Reduced = $range.Reduced
        Devices = @($devices | Sort-Object -Property Sort)
    }
}


function Get-AgenteTIScanHistoryPath {
    # O arquivo de histórico da rede escaneada. O roteador identifica a rede: o MAC dele, ou o IP quando o MAC não aparece
    # (o mesmo 192.168.0.1 existe em quase toda casa, o MAC não).
    param (
        [Parameter(Mandatory)]$Scan,
        [Parameter(Mandatory)]$Interface
    )

    $gatewayDevice = @($Scan.Devices | Where-Object { $_.IsGateway }) | Select-Object -First 1
    $networkKey = $(if ($null -ne $gatewayDevice -and $gatewayDevice.Mac -notlike "IP-*") { $gatewayDevice.Mac } else { "gw-$($Interface.Gateway)" })

    return (Get-AgenteTINetworkHistoryPath -NetworkKey $networkKey)
}


function Find-AgenteTINetworkHistory {
    # O histórico da rede em que o PC está agora, sem escanear: o arquivo mais recente cujo roteador tem o IP do roteador
    # atual. Devolve $null se esta rede nunca foi escaneada.
    param ([Parameter(Mandatory)][string]$Gateway)

    $folder = Join-Path (Get-AgenteTIDataPath) "network-scan"
    if (-not (Test-Path -LiteralPath $folder)) { return $null }

    $best = $null
    $bestStamp = [datetime]::MinValue

    foreach ($file in @(Get-ChildItem -LiteralPath $folder -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
        $document = Read-AgenteTINetworkHistory -Path $file.FullName
        if ($null -eq $document) { continue }

        $sameNetwork = ([string]$document.Gateway -eq $Gateway) -or
            ([string]::IsNullOrEmpty([string]$document.Gateway) -and @($document.Devices | Where-Object { [string]$_.Ip -eq $Gateway }).Count -gt 0)
        if (-not $sameNetwork) { continue }

        $stamp = ConvertFrom-AgenteTIScanStamp -Stamp ([string]$document.LastScan)
        if ($null -ne $stamp -and $stamp -gt $bestStamp) {
            $best = $document
            $bestStamp = $stamp
        }
    }

    return $best
}


function Get-AgenteTINetworkDeviceIcon {
    # O ícone (GuiDesign.psm1) de cada tipo de aparelho.
    param ([string]$Kind)

    switch -Wildcard ($Kind) {
        "Este PC" { return "laptop" }
        "Roteador*" { return "router" }
        "Equipamento de rede" { return "router" }
        "Impressora" { return "printer" }
        "Câmera*" { return "camera" }
        "Celular*" { return "phone" }
        "Apple*" { return "phone" }
        "Casa inteligente" { return "bulb" }
        "TV*" { return "tv" }
        "NAS*" { return "server" }
        "Linux*" { return "server" }
        "Raspberry*" { return "server" }
        "Computador*" { return "monitor" }
        "Mac" { return "monitor" }
        "Aparelho com página web" { return "globe" }
        default { return "help-circle" }
    }
}


function Get-AgenteTIPortMeaning {
    # O que uma porta aberta indica, em poucas palavras.
    param ([int]$Port)

    switch ($Port) {
        22 { return "acesso remoto por SSH (Linux, roteadores, NAS)" }
        80 { return "página de configuração (HTTP)" }
        443 { return "página de configuração segura (HTTPS)" }
        445 { return "compartilhamento de arquivos do Windows (SMB)" }
        554 { return "vídeo ao vivo (RTSP), comum em câmeras" }
        631 { return "impressão pela rede (IPP)" }
        3389 { return "Área de Trabalho Remota do Windows" }
        8080 { return "página web alternativa" }
        9100 { return "impressão direta (RAW)" }
        default { return "porta $Port" }
    }
}


function ConvertTo-AgenteTINetworkScanView {
    # O histórico de uma rede no formato da tela: todos os aparelhos (online e fora do ar), com datas, ícone e portas.
    param (
        [Parameter(Mandatory)]$Document,
        $Interface = $null
    )

    $lastScan = ConvertFrom-AgenteTIScanStamp -Stamp ([string]$Document.LastScan)
    $devices = @($Document.Devices)

    # O primeiro escaneamento da rede: ninguém dele é "novo". Históricos da 1.5 não têm o campo e usam o aparelho mais antigo.
    $firstScan = ConvertFrom-AgenteTIScanStamp -Stamp ([string]$Document.FirstScan)
    if ($null -eq $firstScan) {
        $firstScan = @($devices | ForEach-Object { ConvertFrom-AgenteTIScanStamp -Stamp ([string]$_.FirstSeen) } | Where-Object { $null -ne $_ } | Sort-Object) | Select-Object -First 1
    }

    $selfAddress = $(if ($null -ne $Interface) { [string]$Interface.Address } else { "" })
    $gateway = $(if ($null -ne $Interface) { [string]$Interface.Gateway } else { [string]$Document.Gateway })

    $rows = foreach ($device in $devices) {
        $mac = [string]$device.Mac
        $firstSeen = ConvertFrom-AgenteTIScanStamp -Stamp ([string]$device.FirstSeen)
        $lastSeen = ConvertFrom-AgenteTIScanStamp -Stamp ([string]$device.LastSeen)
        $online = ([string]$device.LastSeen -eq [string]$Document.LastScan)
        $isNew = ($null -ne $firstSeen -and $null -ne $firstScan -and $firstSeen -gt $firstScan.AddSeconds(1) -and ((Get-Date) - $firstSeen).TotalHours -lt 24)
        $ports = @($device.Ports | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ } | Sort-Object)
        $isSelf = [bool]$device.IsSelf -or ($selfAddress -and [string]$device.Ip -eq $selfAddress -and $online)
        $isGateway = [bool]$device.IsGateway -or ($gateway -and [string]$device.Ip -eq $gateway)
        $vendor = [string]$device.Vendor
        $name = [string]$device.Name

        $display = $(if ($name) { $name } elseif ($vendor -and $vendor -ne "MAC privado") { "Aparelho $vendor" } else { "Aparelho sem nome" })

        [PSCustomObject]@{
            Ip          = [string]$device.Ip
            Mac         = $mac
            MacText     = $(if ($mac -like "IP-*") { "Não disponível" } else { Format-AgenteTIMac -Key $mac })
            Name        = $name
            DisplayName = $display
            Vendor      = $vendor
            Kind        = [string]$device.Kind
            Icon        = Get-AgenteTINetworkDeviceIcon -Kind ([string]$device.Kind)
            Ports       = $ports
            PortsText   = @($ports | ForEach-Object { "$_ · $(Get-AgenteTIPortMeaning -Port $_)" })
            Online      = $online
            IsNew       = $isNew
            IsSelf      = $isSelf
            IsGateway   = $isGateway
            RandomMac   = [bool]$device.RandomMac -or (Test-AgenteTIRandomMac -Key $mac)
            FirstSeen   = $firstSeen
            LastSeen    = $lastSeen
            SortIp      = $(try { ConvertTo-AgenteTIIpNumber -Address ([string]$device.Ip) } catch { [int64]0 })
        }
    }

    return [PSCustomObject]@{
        Problem    = ""
        Message    = ""
        Network    = [string]$Document.Network
        Connection = $(if ($null -ne $Interface) { [string]$Interface.Alias } else { [string]$Document.Connection })
        Address    = $selfAddress
        Gateway    = $gateway
        Reduced    = $false
        LastScan   = $lastScan
        FirstScan  = $firstScan
        Scanned    = $false
        Seconds    = 0
        Devices    = @($rows | Sort-Object -Property SortIp)
    }
}


function New-AgenteTINetworkScanProblem {
    param ([string]$Problem, [string]$Message, $Interface = $null)

    return [PSCustomObject]@{
        Problem = $Problem; Message = $Message; Network = ""; Connection = $(if ($Interface) { [string]$Interface.Alias } else { "" })
        Address = $(if ($Interface) { [string]$Interface.Address } else { "" }); Gateway = $(if ($Interface) { [string]$Interface.Gateway } else { "" })
        Reduced = $false; LastScan = $null; FirstScan = $null; Scanned = $false; Seconds = 0; Devices = @()
    }
}


function Get-AgenteTINetworkScanView {
    <#
    O que a tela "Escanear a rede" da janela mostra. Sem -Scan, só lê o último escaneamento guardado desta rede (rápido, não
    manda nada pela rede); com -Scan, escaneia, guarda no histórico e devolve o resultado. Nunca lança erro: um problema vem
    em Problem ("NoNetwork", "NoRoom", "NeverScanned", "Error") com Message em português. Roda no leitor em segundo plano.
    #>
    param ([switch]$Scan)

    try {
        $interface = Get-AgenteTIScanInterface

        if ($null -eq $interface) {
            return (New-AgenteTINetworkScanProblem -Problem "NoNetwork" -Message "O PC não está numa rede com roteador: ligue o Wi-Fi ou conecte o cabo.")
        }

        if (-not $Scan) {
            $document = Find-AgenteTINetworkHistory -Gateway $interface.Gateway

            if ($null -eq $document) {
                return (New-AgenteTINetworkScanProblem -Problem "NeverScanned" -Message "Esta rede ainda não foi escaneada." -Interface $interface)
            }

            return (ConvertTo-AgenteTINetworkScanView -Document $document -Interface $interface)
        }

        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-AgenteTINetworkScanPass -Interface $interface

        if ($null -eq $result) {
            return (New-AgenteTINetworkScanProblem -Problem "NoRoom" -Message "A máscara da rede (/$($interface.PrefixLength)) não deixa espaço para outros aparelhos." -Interface $interface)
        }

        $path = Get-AgenteTIScanHistoryPath -Scan $result -Interface $interface
        $previous = Read-AgenteTINetworkHistory -Path $path
        $stamp = (Get-Date).ToString("o", [System.Globalization.CultureInfo]::InvariantCulture)
        Save-AgenteTINetworkHistory -Path $path -Previous $previous -Devices $result.Devices -Network $result.Network -Stamp $stamp `
            -Gateway $interface.Gateway -Connection $interface.Alias

        $document = Read-AgenteTINetworkHistory -Path $path
        $view = ConvertTo-AgenteTINetworkScanView -Document $document -Interface $interface
        $view.Reduced = [bool]$result.Reduced
        $view.Scanned = $true
        $view.Seconds = [int][Math]::Round($watch.Elapsed.TotalSeconds)

        return $view
    }
    catch {
        return (New-AgenteTINetworkScanProblem -Problem "Error" -Message "Não foi possível escanear a rede: $($_.Exception.Message)")
    }
}


function Format-AgenteTIAgo {
    # "agora", "há 5 min", "há 3 h", "ontem", "há 4 dias".
    param ($When, [datetime]$Now = (Get-Date))

    if ($null -eq $When) { return "nunca" }

    $span = $Now - [datetime]$When
    if ($span.TotalSeconds -lt 60) { return "agora" }
    if ($span.TotalMinutes -lt 60) { return "há $([int][Math]::Floor($span.TotalMinutes)) min" }
    if ($span.TotalHours -lt 24) { return "há $([int][Math]::Floor($span.TotalHours)) h" }

    $days = [int][Math]::Floor($span.TotalDays)
    if ($days -eq 1) { return "ontem" }

    return "há $days dias"
}


function Select-AgenteTINetworkDevices {
    <#
    Os aparelhos que a tabela mostra: filtro de tipo (Kind vazio = todos), de situação (all, online, offline, new), busca
    (nome, IP, MAC, fabricante ou tipo; sem diferenciar maiúsculas) e ordem (ip, name, kind, status, seen).
    #>
    param (
        [AllowEmptyCollection()][object[]]$Devices = @(),
        [string]$Kind = "",
        [ValidateSet("all", "online", "offline", "new")][string]$Status = "all",
        [string]$Search = "",
        [ValidateSet("ip", "name", "kind", "status", "seen", "vendor", "mac")][string]$Sort = "ip",
        [switch]$Descending
    )

    $list = @($Devices | Where-Object { $null -ne $_ })

    if ($Kind) { $list = @($list | Where-Object { $_.Kind -eq $Kind }) }

    switch ($Status) {
        "online" { $list = @($list | Where-Object { $_.Online }) }
        "offline" { $list = @($list | Where-Object { -not $_.Online }) }
        "new" { $list = @($list | Where-Object { $_.IsNew }) }
    }

    $needle = $Search.Trim()

    if ($needle) {
        $compact = ($needle -replace "[:\-\.\s]", "").ToUpperInvariant()
        $list = @($list | Where-Object {
                $text = "$($_.DisplayName) $($_.Name) $($_.Ip) $($_.Vendor) $($_.Kind) $($_.MacText)"
                $text.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                ($compact.Length -ge 4 -and ([string]$_.Mac).Contains($compact))
            })
    }

    # Em cada ordem, o desempate é o IP (a lista não troca de lugar entre um clique e outro).
    $tieBreak = @{ Expression = { [int64]$_.SortIp } }
    $primary = switch ($Sort) {
        "name" { @{ Expression = { [string]$_.DisplayName } } }
        "kind" { @{ Expression = { [string]$_.Kind } } }
        "vendor" { @{ Expression = { [string]$_.Vendor } } }
        "mac" { @{ Expression = { [string]$_.Mac } } }
        "status" { @{ Expression = { [int](-not $_.Online) } } }
        "seen" { @{ Expression = { $(if ($_.LastSeen) { [datetime]$_.LastSeen } else { [datetime]::MinValue }) } } }
        default { $tieBreak }
    }

    $primary["Descending"] = [bool]$Descending
    return @($list | Sort-Object -Property $primary, $tieBreak)
}


function Get-AgenteTINetworkKindCounts {
    # Quantos aparelhos de cada tipo, do tipo mais comum ao menos comum. Kind, Count e Icon.
    param ([AllowEmptyCollection()][object[]]$Devices = @())

    return @(@($Devices | Where-Object { $null -ne $_ }) | Group-Object -Property Kind | Sort-Object -Property @{ Expression = "Count"; Descending = $true }, Name |
            ForEach-Object { [PSCustomObject]@{ Kind = [string]$_.Name; Count = [int]$_.Count; Icon = Get-AgenteTINetworkDeviceIcon -Kind ([string]$_.Name) } })
}


function Get-AgenteTINetworkScanAlerts {
    <#
    O que pede atenção na rede escaneada, do mais importante ao menos: aparelhos novos, Área de Trabalho Remota aberta e
    aparelhos sem tipo conhecido. Level (Warn, Muted, Ok), Text e Filter (o filtro de situação que mostra esses aparelhos,
    ou "" quando o filtro é de tipo, em Kind).
    #>
    param ([AllowEmptyCollection()][object[]]$Devices = @())

    $alerts = @()
    $list = @($Devices | Where-Object { $null -ne $_ })

    $new = @($list | Where-Object { $_.IsNew }).Count
    if ($new -gt 0) {
        $alerts += [PSCustomObject]@{ Level = "Warn"; Text = $(if ($new -eq 1) { "1 aparelho novo nas últimas 24 horas: confira se você o reconhece" } else { "$new aparelhos novos nas últimas 24 horas: confira se você os reconhece" }); Filter = "new"; Kind = "" }
    }

    $remote = @($list | Where-Object { $_.Online -and -not $_.IsSelf -and @($_.Ports) -contains 3389 }).Count
    if ($remote -gt 0) {
        $alerts += [PSCustomObject]@{ Level = "Muted"; Text = $(if ($remote -eq 1) { "1 aparelho aceita Área de Trabalho Remota (porta 3389)" } else { "$remote aparelhos aceitam Área de Trabalho Remota (porta 3389)" }); Filter = ""; Kind = "Computador Windows" }
    }

    $unknown = @($list | Where-Object { $_.Kind -eq "Desconhecido" }).Count
    if ($unknown -gt 0) {
        $alerts += [PSCustomObject]@{ Level = "Muted"; Text = $(if ($unknown -eq 1) { "1 aparelho sem tipo identificado" } else { "$unknown aparelhos sem tipo identificado" }); Filter = ""; Kind = "Desconhecido" }
    }

    if ($new -eq 0) {
        $alerts += [PSCustomObject]@{ Level = "Ok"; Text = "Nenhum aparelho novo nas últimas 24 horas"; Filter = ""; Kind = "" }
    }

    return $alerts
}


function Export-AgenteTINetworkScanCsv {
    # A lista da tela em CSV (separado por ponto e vírgula e com BOM, para o Excel em português abrir com os acentos).
    param (
        [Parameter(Mandatory)][object[]]$Devices,
        [Parameter(Mandatory)][string]$Path
    )

    $rows = foreach ($device in $Devices) {
        [PSCustomObject][ordered]@{
            "Status"          = $(if ($device.Online) { "Online" } else { "Fora do ar" })
            "Tipo"            = $device.Kind
            "Nome"            = $device.Name
            "Fabricante"      = $device.Vendor
            "IP"              = $device.Ip
            "MAC"             = $device.MacText
            "Portas abertas"  = (@($device.Ports) -join ", ")
            "Visto primeiro"  = $(if ($device.FirstSeen) { $device.FirstSeen.ToString("dd/MM/yyyy HH:mm") } else { "" })
            "Visto por último" = $(if ($device.LastSeen) { $device.LastSeen.ToString("dd/MM/yyyy HH:mm") } else { "" })
            "Novo"            = $(if ($device.IsNew) { "Sim" } else { "" })
        }
    }

    $text = (@($rows) | ConvertTo-Csv -NoTypeInformation -Delimiter ";") -join "`r`n"
    [System.IO.File]::WriteAllText($Path, $text + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
}


function Format-AgenteTIDeviceLine {
    # A linha de um aparelho: nome, tipo, fabricante e MAC, sem as partes vazias.
    param ($Device, [bool]$IsNew)

    $parts = @()
    if ($IsNew) { $parts += "NOVO" }
    $parts += $(if ($Device.Name) { $Device.Name } else { "(sem nome)" })
    $parts += $Device.Kind
    if ($Device.Vendor -and $Device.Vendor -ne "MAC privado") { $parts += $Device.Vendor }
    if ($Device.Mac -notlike "IP-*") { $parts += (Format-AgenteTIMac -Key $Device.Mac) }

    return ($parts -join " · ")
}


function Show-AgenteTINetworkScanResult {
    # Mostra a lista e as mudanças desde o escaneamento anterior. Devolve NewCount, GoneCount e FirstTime.
    param (
        [Parameter(Mandatory)]$Scan,
        $Previous
    )

    $knownMacs = @{}
    $lastScanMacs = @{}
    $firstTime = ($null -eq $Previous -or $null -eq $Previous.Devices)

    if (-not $firstTime) {
        foreach ($old in @($Previous.Devices)) {
            $knownMacs[[string]$old.Mac] = $old
            if ([string]$old.LastSeen -eq [string]$Previous.LastScan) { $lastScanMacs[[string]$old.Mac] = $old }
        }
    }

    $currentMacs = @{}
    foreach ($device in $Scan.Devices) { $currentMacs[$device.Mac] = $true }

    $newDevices = @($(if (-not $firstTime) { $Scan.Devices | Where-Object { -not $knownMacs.ContainsKey($_.Mac) } }))
    $goneDevices = @($lastScanMacs.Values | Where-Object { -not $currentMacs.ContainsKey([string]$_.Mac) })

    Write-AgenteTISection -Title "Aparelhos na rede $($Scan.Network) ($(@($Scan.Devices).Count))"

    foreach ($device in $Scan.Devices) {
        $isNew = (-not $firstTime) -and (-not $knownMacs.ContainsKey($device.Mac))
        $level = $(if ($isNew) { "Warn" } elseif ($device.IsSelf -or $device.IsGateway) { "Ok" } else { "Normal" })
        Write-AgenteTIKeyValue -Label $device.Ip -Value (Format-AgenteTIDeviceLine -Device $device -IsNew $isNew) -LabelWidth 15 -Level $level
    }

    if ($firstTime) {
        Write-Host ""
        Write-AgenteTIStatus -Type Info -Message "Primeiro escaneamento desta rede: os próximos mostram os aparelhos que entraram e os que saíram." -Notice
    }
    else {
        Write-AgenteTISection -Title "Desde o escaneamento de $(Format-AgenteTIScanStamp -Stamp ([string]$Previous.LastScan))"

        if ($newDevices.Count -eq 0 -and $goneDevices.Count -eq 0) {
            Write-Host "  Nenhum aparelho entrou ou saiu." -ForegroundColor Gray
        }

        foreach ($device in $newDevices) {
            Write-AgenteTIKeyValue -Label "Entrou" -Value "$($device.Ip) · $(Format-AgenteTIDeviceLine -Device $device -IsNew $false)" -LabelWidth 15 -Level Warn
        }

        foreach ($old in $goneDevices) {
            $label = $(if ([string]$old.Name) { [string]$old.Name } else { "(sem nome)" })
            $mac = $(if ([string]$old.Mac -notlike "IP-*") { " · $(Format-AgenteTIMac -Key ([string]$old.Mac))" } else { "" })
            Write-AgenteTIKeyValue -Label "Saiu" -Value "$($old.Ip) · $label · $($old.Kind)$mac" -LabelWidth 15
        }
    }

    Write-Host ""
    Write-Host "  O tipo é um palpite pelo fabricante e pelas portas abertas. Aparelhos em economia de energia podem não responder." -ForegroundColor DarkGray

    return [PSCustomObject]@{ NewCount = $newDevices.Count; GoneCount = $goneDevices.Count; FirstTime = $firstTime }
}


function Invoke-AgenteTINetworkScan {
    Enter-AgenteTIAction -Title "Escanear a rede"

    $final = New-AgenteTIResult -Kind Failed -Detail "o escaneamento não devolveu resultado"

    try {
        $interface = Get-AgenteTIScanInterface

        if ($null -eq $interface) {
            Write-AgenteTIStatus -Type Warning -Message "O PC não está numa rede com roteador: ligue o Wi-Fi ou conecte o cabo."
            $final = Set-AgenteTIResultView -Result (New-AgenteTIResult -Kind Warning -Detail "o PC não está numa rede local") `
                -Headline "Nenhuma rede para escanear" -Note "Ligue o Wi-Fi ou conecte o cabo." -Next "NetworkSettings" -NextLabel "Abrir as configurações de rede"
            Exit-AgenteTIAction -Result $final
            return
        }

        Write-AgenteTIKeyValue -Label "Conexão" -Value "$($interface.Alias) · este PC: $($interface.Address)/$($interface.PrefixLength) · roteador: $($interface.Gateway)" -LabelWidth 15

        $summary = $null
        $scan = $null

        while ($true) {
            $scan = Invoke-AgenteTINetworkScanPass -Interface $interface

            if ($null -eq $scan) {
                Write-AgenteTIStatus -Type Warning -Message "A máscara da rede (/$($interface.PrefixLength)) não deixa espaço para outros aparelhos."
                $final = New-AgenteTIResult -Kind Warning -Detail "rede sem outros endereços"
                break
            }

            if ($scan.Reduced) {
                Write-AgenteTIStatus -Type Info -Message "A rede é grande (/$($interface.PrefixLength)): foram escaneados só os 254 endereços vizinhos deste PC ($($scan.Network))." -Notice
            }

            $historyPath = Get-AgenteTIScanHistoryPath -Scan $scan -Interface $interface
            $previous = Read-AgenteTINetworkHistory -Path $historyPath

            $summary = Show-AgenteTINetworkScanResult -Scan $scan -Previous $previous

            try {
                $stamp = (Get-Date).ToString("o", [System.Globalization.CultureInfo]::InvariantCulture)
                Save-AgenteTINetworkHistory -Path $historyPath -Previous $previous -Devices $scan.Devices -Network $scan.Network -Stamp $stamp `
                    -Gateway $interface.Gateway -Connection $interface.Alias
            }
            catch {
                Write-AgenteTIStatus -Type Warning -Message "Não foi possível guardar o histórico da rede: $($_.Exception.Message)" -Notice
            }

            Write-Host ""
            $answer = Read-AgenteTIChoice -Message "Escanear de novo para ver o que mudou?" -DefaultKey "C" -Options @(
                @{ Key = "R"; Label = "Escanear de novo"; Description = "Mostra os aparelhos que entraram ou saíram desde agora" },
                @{ Key = "C"; Label = "Concluir"; Exit = $true }
            )

            if ($answer -ne "R") { break }
        }

        if ($null -ne $scan -and $null -ne $summary) {
            $count = @($scan.Devices).Count
            $note = $(if ($summary.FirstTime) { "Primeiro escaneamento desta rede." }
                elseif ($summary.NewCount -gt 0) { "$($summary.NewCount) aparelho(s) novo(s) na rede; confira se você os reconhece." }
                elseif ($summary.GoneCount -gt 0) { "$($summary.GoneCount) aparelho(s) saíram desde o escaneamento anterior." }
                else { "Nenhum aparelho entrou ou saiu desde o escaneamento anterior." })

            $kind = $(if ($summary.NewCount -gt 0) { "Warning" } else { "Ok" })
            $final = Set-AgenteTIResultView -Result (New-AgenteTIResult -Kind $kind -Detail "$count aparelho(s) na rede $($scan.Network)") `
                -Headline "$count aparelho(s) na rede" -Note $note
        }
    }
    catch {
        Write-AgenteTIStatus -Type Error -Message "Ocorreu um erro no escaneamento da rede: $($_.Exception.Message)"
        $final = New-AgenteTIResult -Kind Failed -Detail $_.Exception.Message
    }

    Exit-AgenteTIAction -Result $final
}


Export-ModuleMember -Function *
