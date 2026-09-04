# Regla de entrada del firewall de Windows para los puertos del juego. No se ejecuta: se hace
# dot-source.
#
# RCON (27015/tcp) nunca recibe una regla: en el server nativo escucha en todas las interfaces
# y la unica proteccion es que el firewall no lo deje pasar. Ver docs/windows.md,
# seccion "Security".

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'I18n.ps1')
. (Join-Path $PSScriptRoot 'Ui.ps1')

$script:ZsFirewallRuleName = 'Zomboid Server (UDP 16261-16262)'

function Get-ZsFirewallRuleName {
    <#
        .SYNOPSIS
        Nombre de la regla del firewall que abre los puertos del juego.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return $script:ZsFirewallRuleName
}

function Get-ZsFirewallElevatedScript {
    <#
        .SYNOPSIS
        Texto del script de PowerShell que crea la regla, para correrlo elevado. Idempotente:
        no hace nada si la regla ya existe.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [int]$GamePort = 16261,

        [Parameter()]
        [int]$GameUdpPort = 16262
    )

    $name = $script:ZsFirewallRuleName
    $portRange = "$GamePort-$GameUdpPort"

    return @"
if (-not (Get-NetFirewallRule -DisplayName '$name' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName '$name' -Direction Inbound -Protocol UDP -LocalPort $portRange -Action Allow | Out-Null
}
"@
}

function Test-ZsFirewallRule {
    <#
        .SYNOPSIS
        Si la regla del firewall ya existe. En un host sin Get-NetFirewallRule (no Windows)
        devuelve $false en vez de fallar.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Get-Command -Name 'Get-NetFirewallRule' -ErrorAction SilentlyContinue)) {
        return $false
    }
    $rule = Get-NetFirewallRule -DisplayName $script:ZsFirewallRuleName -ErrorAction SilentlyContinue
    return ($null -ne $rule)
}

function Install-ZsFirewallRule {
    <#
        .SYNOPSIS
        Agrega la regla de entrada UDP para los puertos del juego con una sola elevacion (UAC).
        Idempotente: si ya existe, no pide elevacion de nuevo.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter()]
        [int]$GamePort = 16261,

        [Parameter()]
        [int]$GameUdpPort = 16262
    )

    if (Test-ZsFirewallRule) {
        Write-ZsOk (Get-ZsText 'firewall.already_exists' $script:ZsFirewallRuleName)
        return
    }

    Write-ZsStep (Get-ZsText 'firewall.elevating')
    $script = Get-ZsFirewallElevatedScript -GamePort $GamePort -GameUdpPort $GameUdpPort
    $process = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $script) `
        -Verb RunAs -Wait -PassThru

    if ($process.ExitCode -ne 0) {
        throw (Get-ZsText 'firewall.failed' $process.ExitCode)
    }
    if (-not (Test-ZsFirewallRule)) {
        throw (Get-ZsText 'firewall.not_created')
    }
    Write-ZsOk (Get-ZsText 'firewall.created' $script:ZsFirewallRuleName)
}
