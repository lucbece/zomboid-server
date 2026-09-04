# Descarga SteamCMD e instala/actualiza el server (app 380870) en .\server\. No se ejecuta:
# se hace dot-source.
#
# Es el equivalente Windows de lo que hace la imagen de Docker en el build: SteamCMD anonimo,
# sin cuenta de Steam, descarga el ejecutable del server dedicado. El Workshop lo baja el
# propio server al arrancar, igual que en Linux.
#
# steamcmd\   ejecutable de SteamCMD (se re-descarga si falta, no se versiona)
# server\     el server dedicado instalado (StartServer64.bat, java\, jre64\, ...)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'I18n.ps1')
. (Join-Path $PSScriptRoot 'Ui.ps1')

$script:ZsSteamCmdUrl = 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip'
$script:ZsAppId = '380870'

function Get-ZsSteamCmdUrl {
    <#
        .SYNOPSIS
        URL fija de la que se descarga steamcmd.zip. Es la unica URL que no es de Steam mismo.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return $script:ZsSteamCmdUrl
}

function Get-ZsAppId {
    <#
        .SYNOPSIS
        App ID del server dedicado de Project Zomboid en Steam.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return $script:ZsAppId
}

function Get-ZsSteamCmdDir {
    <#
        .SYNOPSIS
        Directorio donde se instala SteamCMD.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    return (Join-Path $RepoRoot 'steamcmd')
}

function Get-ZsServerDir {
    <#
        .SYNOPSIS
        Directorio donde SteamCMD instala el server dedicado.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    return (Join-Path $RepoRoot 'server')
}

function Get-ZsSteamCmdExePath {
    <#
        .SYNOPSIS
        Ruta del ejecutable de SteamCMD ya instalado.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    return (Join-Path (Get-ZsSteamCmdDir -RepoRoot $RepoRoot) 'steamcmd.exe')
}

function Test-ZsSteamAppInstalled {
    <#
        .SYNOPSIS
        Si el server dedicado ya esta instalado (existe StartServer64.bat).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    $bat = Join-Path (Get-ZsServerDir -RepoRoot $RepoRoot) 'StartServer64.bat'
    return (Test-Path -LiteralPath $bat)
}

function Install-ZsSteamCmd {
    <#
        .SYNOPSIS
        Descarga y descomprime steamcmd.zip en .\steamcmd\ si no esta ya instalado.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter()]
        [switch]$Force
    )

    $dir = Get-ZsSteamCmdDir -RepoRoot $RepoRoot
    $exe = Get-ZsSteamCmdExePath -RepoRoot $RepoRoot

    if ((Test-Path -LiteralPath $exe) -and -not $Force) {
        Write-ZsOk (Get-ZsText 'steamcmd.already_installed' $exe)
        return $exe
    }

    if (-not (Test-Path -LiteralPath $dir)) {
        [void](New-Item -ItemType Directory -Path $dir -Force)
    }

    $zipPath = Join-Path $dir 'steamcmd.zip'
    Write-ZsStep (Get-ZsText 'steamcmd.downloading' $script:ZsSteamCmdUrl)
    Invoke-WebRequest -Uri $script:ZsSteamCmdUrl -OutFile $zipPath -UseBasicParsing

    Write-ZsStep (Get-ZsText 'steamcmd.extracting')
    Expand-Archive -LiteralPath $zipPath -DestinationPath $dir -Force
    Remove-Item -LiteralPath $zipPath -Force

    if (-not (Test-Path -LiteralPath $exe)) {
        throw (Get-ZsText 'steamcmd.missing_exe' $exe)
    }

    Write-ZsOk (Get-ZsText 'steamcmd.installed' $exe)
    return $exe
}

function Install-ZsSteamApp {
    <#
        .SYNOPSIS
        Instala o actualiza el server dedicado (app 380870) con SteamCMD anonimo.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    $steamCmdExe = Install-ZsSteamCmd -RepoRoot $RepoRoot
    $serverDir = Get-ZsServerDir -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $serverDir)) {
        [void](New-Item -ItemType Directory -Path $serverDir -Force)
    }

    Write-ZsStep (Get-ZsText 'steamcmd.updating' $script:ZsAppId)

    $arguments = @(
        '+force_install_dir', $serverDir,
        '+login', 'anonymous',
        '+app_update', $script:ZsAppId, 'validate',
        '+quit'
    )

    # El llamado directo (operador &) y no Start-Process: la salida de SteamCMD (progreso de
    # descarga) tiene que verse en la consola a medida que llega, no recien al terminar.
    & $steamCmdExe @arguments 2>&1 | ForEach-Object { Write-ZsLine "  $_" }
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw (Get-ZsText 'steamcmd.update_failed' $exitCode)
    }
    if (-not (Test-ZsSteamAppInstalled -RepoRoot $RepoRoot)) {
        throw (Get-ZsText 'steamcmd.no_startserver' $serverDir)
    }

    Write-ZsOk (Get-ZsText 'steamcmd.update_ok')
}
