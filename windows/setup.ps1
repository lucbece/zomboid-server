# Asistente de configuracion del server nativo de Windows.
#
#   windows\setup.ps1                  modo normal: pregunta y explica
#   windows\setup.ps1 -NonInteractive  no pregunta nada: usa las variables ZS_*
#
# Es el equivalente de setup.sh para el motor de Windows: escribe el mismo .env (mas UPNP),
# instala el server con SteamCMD, abre el firewall y arranca. Se puede volver a correr las
# veces que haga falta: usa lo que ya habia como valor por defecto.
#
# Variables ZS_* en modo -NonInteractive:
#   ZS_LANG            es o en
#   ZS_PUBLIC_NAME      ZS_SERVER_PASSWORD  ZS_MAX_PLAYERS  ZS_MAX_MEMORY (ej. "8g")
#   ZS_UPNP             ZS_FIREWALL         (1/0, true/false, s/n, y/n)
#   ZS_ADMIN_PASSWORD   ZS_RCON_PASSWORD    (si faltan, se generan)

[CmdletBinding()]
param(
    [Parameter()]
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ZsRepoRoot = Split-Path -Parent $PSScriptRoot
$libDir = Join-Path $PSScriptRoot 'lib'

. (Join-Path $libDir 'I18n.ps1')
. (Join-Path $libDir 'Ui.ps1')
. (Join-Path $libDir 'Env.ps1')
. (Join-Path $libDir 'Words.ps1')
. (Join-Path $libDir 'Mods.ps1')
. (Join-Path $libDir 'Render.ps1')
. (Join-Path $libDir 'Rcon.ps1')
. (Join-Path $libDir 'SteamCmd.ps1')
. (Join-Path $libDir 'Server.ps1')
. (Join-Path $libDir 'Firewall.ps1')
. (Join-Path $libDir 'Backup.ps1')

function ConvertTo-ZsBool {
    <#
        .SYNOPSIS
        Interpreta una respuesta si/no en varios formatos. Vacio devuelve el default.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value,

        [Parameter(Position = 1)]
        [bool]$Default = $true
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Default
    }
    return ($Value.Trim() -match '^(?i)(1|true|s|si|y|yes)$')
}

function Get-ZsDefaultMaxMemory {
    <#
        .SYNOPSIS
        8g por defecto, con un piso de 4g y un techo de la mitad de la RAM de la maquina.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [Nullable[long]]$TotalPhysicalMemoryBytes
    )

    $defaultGb = 8
    if ($null -ne $TotalPhysicalMemoryBytes -and $TotalPhysicalMemoryBytes -gt 0) {
        $totalGb = [math]::Floor($TotalPhysicalMemoryBytes / 1GB)
        $half = [math]::Floor($totalGb / 2)
        if ($half -lt 4) {
            $half = 4
        }
        if ($defaultGb -gt $half) {
            $defaultGb = $half
        }
    }
    return "${defaultGb}g"
}

function Get-ZsTotalPhysicalMemory {
    <#
        .SYNOPSIS
        RAM total de la maquina en bytes, o $null si no se puede averiguar.
    #>
    [CmdletBinding()]
    [OutputType([System.Nullable[long]])]
    param()

    try {
        if (Get-Command -Name Get-CimInstance -ErrorAction SilentlyContinue) {
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
            return [long]$cs.TotalPhysicalMemory
        }
    }
    catch {
        Write-Verbose "no se pudo leer la RAM de la maquina: $($_.Exception.Message)"
    }
    return $null
}

function Get-ZsEnvOrDefault {
    <#
        .SYNOPSIS
        Valor por defecto de una pregunta: la variable ZS_*, si no el .env existente, si no
        el valor fijo que se le pasa.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$EnvVar,

        [Parameter(Mandatory)]
        [string]$Key,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Specialized.OrderedDictionary]$Existing,

        [Parameter(Mandatory)]
        [string]$Fallback
    )

    $fromEnvironment = [System.Environment]::GetEnvironmentVariable($EnvVar)
    if (-not [string]::IsNullOrWhiteSpace($fromEnvironment)) {
        return $fromEnvironment
    }
    if ($Existing.Contains($Key) -and -not [string]::IsNullOrEmpty([string]$Existing[$Key])) {
        return [string]$Existing[$Key]
    }
    return $Fallback
}

function Test-ZsPrerequisite {
    <#
        .SYNOPSIS
        Chequeos de la maquina: SO, PowerShell, disco, RAM y la ruta del repositorio.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    Write-ZsTitle (Get-ZsText 'setup.checks.title')

    if ($PSVersionTable.PSVersion -ge [version]'5.1') {
        Write-ZsOk (Get-ZsText 'setup.checks.powershell_ok' ([string]$PSVersionTable.PSVersion))
    }
    else {
        Write-ZsMiss (Get-ZsText 'setup.checks.powershell_old' ([string]$PSVersionTable.PSVersion))
    }

    try {
        if (Get-Command -Name Get-CimInstance -ErrorAction SilentlyContinue) {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            $version = [version]$os.Version
            if ($version -ge [version]'10.0.17763' -and [Environment]::Is64BitOperatingSystem) {
                Write-ZsOk (Get-ZsText 'setup.checks.os_ok' $os.Caption)
            }
            else {
                Write-ZsWarn (Get-ZsText 'setup.checks.os_old' $os.Caption)
            }
        }
    }
    catch {
        Write-Verbose "no se pudo leer la version de Windows: $($_.Exception.Message)"
    }

    try {
        $drive = (Get-Item -LiteralPath $RepoRoot).PSDrive
        if ($null -ne $drive -and $drive.Free -gt 0) {
            $freeGb = [math]::Round($drive.Free / 1GB, 1)
            if ($freeGb -ge 20) {
                Write-ZsOk (Get-ZsText 'setup.checks.disk_ok' $freeGb)
            }
            else {
                Write-ZsWarn (Get-ZsText 'setup.checks.disk_low' $freeGb)
            }
        }
    }
    catch {
        Write-Verbose "no se pudo leer el espacio libre en disco: $($_.Exception.Message)"
    }

    $totalMemory = Get-ZsTotalPhysicalMemory
    if ($null -ne $totalMemory) {
        $totalGb = [math]::Round($totalMemory / 1GB, 1)
        if ($totalGb -ge 8) {
            Write-ZsOk (Get-ZsText 'setup.checks.ram_ok' $totalGb)
        }
        else {
            Write-ZsWarn (Get-ZsText 'setup.checks.ram_low' $totalGb)
        }
    }

    if ($RepoRoot -match '\s' -or $RepoRoot -match '[^\x00-\x7F]') {
        Write-ZsWarn (Get-ZsText 'setup.checks.path_bad' $RepoRoot)
    }
    else {
        Write-ZsOk (Get-ZsText 'setup.checks.path_ok' $RepoRoot)
    }
}

# =================================================================================================
# 1. Idioma
# =================================================================================================

$envFile = Join-Path $script:ZsRepoRoot '.env'
$existing = [ordered]@{}
if (Test-Path -LiteralPath $envFile) {
    $existing = Read-ZsEnvFile -Path $envFile
}

$defaultLang = Get-ZsLanguage -EnvFile $envFile
$langDefault = Get-ZsEnvOrDefault -EnvVar 'ZS_LANG' -Key 'ZS_LANG' -Existing $existing -Fallback $defaultLang
$lang = Read-ZsAnswer -Question 'Idioma / Language [es/en]' -Default $langDefault -NonInteractive:$NonInteractive
if ($lang -ne 'es' -and $lang -ne 'en') {
    $lang = 'en'
}
Initialize-ZsI18n -Language $lang -EnvFile $envFile

Write-ZsTitle (Get-ZsText 'setup.title')
Test-ZsPrerequisite -RepoRoot $script:ZsRepoRoot

# =================================================================================================
# 2. Preguntas
# =================================================================================================

Write-ZsTitle (Get-ZsText 'setup.questions.title')

$publicNameDefault = Get-ZsEnvOrDefault -EnvVar 'ZS_PUBLIC_NAME' -Key 'PUBLIC_NAME' -Existing $existing -Fallback 'My Zomboid Server'
$publicName = Read-ZsAnswer -Question (Get-ZsText 'setup.q.public_name') -Default $publicNameDefault -NonInteractive:$NonInteractive
if (-not (Test-ZsPublicName $publicName)) {
    throw (Get-ZsText 'setup.err.public_name')
}

$serverPasswordDefault = Get-ZsEnvOrDefault -EnvVar 'ZS_SERVER_PASSWORD' -Key 'SERVER_PASSWORD' -Existing $existing -Fallback (Get-ZsRandomPassword)
$serverPassword = Read-ZsAnswer -Question (Get-ZsText 'setup.q.password' (Get-ZsText 'setup.pass.label.server')) -Default $serverPasswordDefault -NonInteractive:$NonInteractive
if (-not (Test-ZsPassword $serverPassword)) {
    throw (Get-ZsText 'setup.err.password' (Get-ZsText 'setup.pass.label.server'))
}

$maxPlayersDefault = Get-ZsEnvOrDefault -EnvVar 'ZS_MAX_PLAYERS' -Key 'MAX_PLAYERS' -Existing $existing -Fallback '8'
$maxPlayersAnswer = Read-ZsAnswer -Question (Get-ZsText 'setup.q.max_players') -Default $maxPlayersDefault -NonInteractive:$NonInteractive
$maxPlayers = 0
if (-not [int]::TryParse($maxPlayersAnswer, [ref]$maxPlayers) -or $maxPlayers -lt 1) {
    throw (Get-ZsText 'setup.err.max_players')
}

$memoryFallback = Get-ZsDefaultMaxMemory -TotalPhysicalMemoryBytes (Get-ZsTotalPhysicalMemory)
$memoryDefault = Get-ZsEnvOrDefault -EnvVar 'ZS_MAX_MEMORY' -Key 'MAX_MEMORY' -Existing $existing -Fallback $memoryFallback
$maxMemory = Read-ZsAnswer -Question (Get-ZsText 'setup.q.max_memory') -Default $memoryDefault -NonInteractive:$NonInteractive
if ($maxMemory -notmatch '^[0-9]+[gGmM]$') {
    throw (Get-ZsText 'setup.err.max_memory')
}

$upnpDefaultRaw = Get-ZsEnvOrDefault -EnvVar 'ZS_UPNP' -Key 'UPNP' -Existing $existing -Fallback 'true'
$upnpDefault = ConvertTo-ZsBool $upnpDefaultRaw $true
$upnp = Read-ZsConfirm -Question (Get-ZsText 'setup.q.upnp') -Default $upnpDefault -NonInteractive:$NonInteractive

$firewallDefault = ConvertTo-ZsBool ([System.Environment]::GetEnvironmentVariable('ZS_FIREWALL')) $true
$firewall = Read-ZsConfirm -Question (Get-ZsText 'setup.q.firewall') -Default $firewallDefault -NonInteractive:$NonInteractive

$adminPassword = Get-ZsEnvOrDefault -EnvVar 'ZS_ADMIN_PASSWORD' -Key 'ADMINPASSWORD' -Existing $existing -Fallback (Get-ZsRandomPassword)
$rconPassword = Get-ZsEnvOrDefault -EnvVar 'ZS_RCON_PASSWORD' -Key 'RCONPASSWORD' -Existing $existing -Fallback (Get-ZsRandomPassword)
if (-not (Test-ZsPassword $adminPassword)) {
    $adminPassword = Get-ZsRandomPassword
}
if (-not (Test-ZsPassword $rconPassword)) {
    $rconPassword = Get-ZsRandomPassword
}

# =================================================================================================
# 3. Escribir .env y copiar los templates de config/
# =================================================================================================

Write-ZsTitle (Get-ZsText 'setup.write.title')

Write-ZsEnvFile -Path $envFile -AdminPassword $adminPassword -RconPassword $rconPassword `
    -ServerPassword $serverPassword -PublicName $publicName -MaxPlayers $maxPlayers `
    -MaxMemory $maxMemory -Language $lang -Upnp $upnp
Write-ZsOk (Get-ZsText 'setup.write.env')

$configDir = Join-Path $script:ZsRepoRoot 'config'
$modsFile = Join-Path $configDir 'mods.txt'
$modsExample = Join-Path $configDir 'mods.example.txt'
if (-not (Test-Path -LiteralPath $modsFile) -and (Test-Path -LiteralPath $modsExample)) {
    Copy-Item -LiteralPath $modsExample -Destination $modsFile
    Write-ZsOk (Get-ZsText 'setup.write.mods_copied' $modsFile)
}

$sandboxFile = Join-Path $configDir 'servertest_SandboxVars.lua'
$sandboxExample = Join-Path $configDir 'servertest_SandboxVars.example.lua'
if (-not (Test-Path -LiteralPath $sandboxFile) -and (Test-Path -LiteralPath $sandboxExample)) {
    Copy-Item -LiteralPath $sandboxExample -Destination $sandboxFile
    Write-ZsOk (Get-ZsText 'setup.write.sandbox_copied' $sandboxFile)
}

# =================================================================================================
# 4. SteamCMD: instalar/actualizar el server
# =================================================================================================

Write-ZsTitle (Get-ZsText 'setup.steamcmd.title')
Install-ZsSteamApp -RepoRoot $script:ZsRepoRoot

# =================================================================================================
# 5. Firewall
# =================================================================================================

$envValues = Read-ZsEnvFile -Path $envFile

if ($firewall) {
    Write-ZsTitle (Get-ZsText 'setup.firewall.title')
    $gamePort = [int]$envValues['GAME_PORT']
    $gameUdpPort = [int]$envValues['GAME_UDP_PORT']
    Install-ZsFirewallRule -GamePort $gamePort -GameUdpPort $gameUdpPort
}
else {
    Write-ZsWarn (Get-ZsText 'setup.firewall.skipped')
}

# =================================================================================================
# 6. Render y arranque
# =================================================================================================

Write-ZsTitle (Get-ZsText 'setup.start.title')
$envValues = Read-ZsEnvFile -Path $envFile
$result = Start-ZsServer -RepoRoot $script:ZsRepoRoot -EnvValues $envValues -TimeoutSeconds 600

# =================================================================================================
# 7. Resumen para los jugadores
# =================================================================================================

Write-ZsTitle (Get-ZsText 'setup.summary.title')

$lanAddress = ''
try {
    $hostEntry = [System.Net.Dns]::GetHostEntry([System.Net.Dns]::GetHostName())
    $ipv4 = $hostEntry.AddressList |
        Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
        Select-Object -First 1
    if ($ipv4) {
        $lanAddress = $ipv4.IPAddressToString
    }
}
catch {
    Write-Verbose "no se pudo resolver la IP de LAN: $($_.Exception.Message)"
}
if ([string]::IsNullOrEmpty($lanAddress)) {
    $lanAddress = Get-ZsText 'setup.summary.unknown'
}

$publicAddress = ''
try {
    $publicAddress = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 5).Trim()
}
catch {
    Write-Verbose "no se pudo consultar la IP publica: $($_.Exception.Message)"
}
if ([string]::IsNullOrEmpty($publicAddress)) {
    $publicAddress = Get-ZsText 'setup.summary.unknown'
}

$upnpMapped = $false
if (Test-Path -LiteralPath $result.LogPath) {
    $upnpMapped = (Select-String -LiteralPath $result.LogPath -Pattern 'UPnP' -Quiet) -and
    (Select-String -LiteralPath $result.LogPath -Pattern '(?i)upnp.*(success|mapped|ok)' -Quiet)
}

Write-ZsLine ''
Write-ZsOk (Get-ZsText 'setup.summary.lan' $lanAddress)
Write-ZsOk (Get-ZsText 'setup.summary.public' $publicAddress)
Write-ZsOk (Get-ZsText 'setup.summary.port' ([string]$envValues['GAME_PORT']))
Write-ZsOk (Get-ZsText 'setup.summary.password' $serverPassword)
if ($upnp -and $upnpMapped) {
    Write-ZsOk (Get-ZsText 'setup.summary.upnp_ok')
}
else {
    Write-ZsWarn (Get-ZsText 'setup.summary.upnp_manual' ([string]$envValues['GAME_PORT']) ([string]$envValues['GAME_UDP_PORT']))
}
