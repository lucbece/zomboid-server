# Dispatcher de operaciones del server nativo de Windows. Lo llama zs.cmd; se puede llamar
# directo con pwsh o powershell.exe.
#
#   zs start|stop|restart|status|logs|backup|update|render
#   zs rcon <comando rcon>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('start', 'stop', 'restart', 'status', 'logs', 'backup', 'update', 'render', 'rcon')]
    [string]$Command,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ZsRepoRoot = Split-Path -Parent $PSScriptRoot
$libDir = Join-Path $PSScriptRoot 'lib'

. (Join-Path $libDir 'I18n.ps1')
. (Join-Path $libDir 'Ui.ps1')
. (Join-Path $libDir 'Env.ps1')
. (Join-Path $libDir 'Mods.ps1')
. (Join-Path $libDir 'Render.ps1')
. (Join-Path $libDir 'Rcon.ps1')
. (Join-Path $libDir 'SteamCmd.ps1')
. (Join-Path $libDir 'Server.ps1')
. (Join-Path $libDir 'Backup.ps1')

$envFilePath = Join-Path $script:ZsRepoRoot '.env'
Initialize-ZsI18n -EnvFile $envFilePath

function Get-ZsEnvValuesOrFail {
    <#
        .SYNOPSIS
        Lee el .env del repo o corta con un mensaje claro si no existe.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    if (-not (Test-Path -LiteralPath $envFilePath)) {
        throw (Get-ZsText 'render.no_env' $envFilePath)
    }
    return (Read-ZsEnvFile -Path $envFilePath)
}

function Show-ZsStatus {
    <#
        .SYNOPSIS
        Imprime el estado del server: proceso, jugadores, puertos y ultimas lineas del log.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Specialized.OrderedDictionary]$EnvValues
    )

    $status = Get-ZsServerStatus -RepoRoot $script:ZsRepoRoot -EnvValues $EnvValues

    if ($status.Running) {
        Write-ZsOk (Get-ZsText 'zs.status.running' $status.ProcessId)
    }
    else {
        Write-ZsMiss (Get-ZsText 'zs.status.stopped')
    }

    if ($null -ne $status.Players) {
        Write-ZsLine ''
        Write-ZsLine $status.Players
    }

    $gamePort = 16261
    if ($EnvValues.Contains('GAME_PORT') -and -not [string]::IsNullOrEmpty([string]$EnvValues['GAME_PORT'])) {
        $gamePort = [int]$EnvValues['GAME_PORT']
    }
    $listening = Get-ZsUdpListener | Where-Object { $_.Port -eq $gamePort }
    if ($listening) {
        Write-ZsOk (Get-ZsText 'zs.status.port_open' $gamePort)
    }
    else {
        Write-ZsWarn (Get-ZsText 'zs.status.port_closed' $gamePort)
    }

    if (-not [string]::IsNullOrEmpty($status.LastLogLines)) {
        Write-ZsLine ''
        Write-ZsLine (Get-ZsText 'zs.status.log_tail')
        Write-ZsLine $status.LastLogLines
    }
}

function Get-ZsUdpListener {
    <#
        .SYNOPSIS
        Puertos UDP en escucha en la maquina (multiplataforma via .NET, no necesita elevacion).
    #>
    [CmdletBinding()]
    [OutputType([System.Net.IPEndPoint[]])]
    param()

    try {
        return [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveUdpListeners()
    }
    catch {
        Write-Verbose "no se pudo listar los puertos UDP: $($_.Exception.Message)"
        return @()
    }
}

switch ($Command) {
    'start' {
        $envValues = Get-ZsEnvValuesOrFail
        [void](Start-ZsServer -RepoRoot $script:ZsRepoRoot -EnvValues $envValues)
    }
    'stop' {
        $envValues = Get-ZsEnvValuesOrFail
        Stop-ZsServer -RepoRoot $script:ZsRepoRoot -EnvValues $envValues
    }
    'restart' {
        $envValues = Get-ZsEnvValuesOrFail
        Stop-ZsServer -RepoRoot $script:ZsRepoRoot -EnvValues $envValues
        [void](Start-ZsServer -RepoRoot $script:ZsRepoRoot -EnvValues $envValues)
    }
    'status' {
        $envValues = Get-ZsEnvValuesOrFail
        Show-ZsStatus -EnvValues $envValues
    }
    'logs' {
        $logPath = Get-ZsLogFilePath -RepoRoot $script:ZsRepoRoot
        if (-not (Test-Path -LiteralPath $logPath)) {
            throw (Get-ZsText 'zs.logs.missing' $logPath)
        }
        Get-Content -LiteralPath $logPath -Tail 50 -Wait
    }
    'backup' {
        $envValues = Get-ZsEnvValuesOrFail
        [void](New-ZsBackup -RepoRoot $script:ZsRepoRoot -EnvValues $envValues)
    }
    'update' {
        if ((Test-ZsServerRunning -RepoRoot $script:ZsRepoRoot).Running) {
            throw (Get-ZsText 'zs.update.running')
        }
        Install-ZsSteamApp -RepoRoot $script:ZsRepoRoot
    }
    'render' {
        $result = Invoke-ZsRender -RepoRoot $script:ZsRepoRoot
        Write-ZsOk $result.Ini
        Write-ZsLine ("  Mods={0}" -f $result.Mods)
        Write-ZsLine ("  WorkshopItems={0}" -f $result.WorkshopItems)
    }
    'rcon' {
        if ($Arguments.Count -eq 0) {
            throw (Get-ZsText 'zs.rcon.usage')
        }
        $envValues = Get-ZsEnvValuesOrFail
        $rconCommand = ($Arguments -join ' ')
        $output = Invoke-ZsRconFromEnv -Command $rconCommand -EnvValues $envValues
        Write-ZsLine $output
    }
}
