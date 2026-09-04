# Arranque, apagado y estado del server nativo. No se ejecuta: se hace dot-source.
#
# El comando de java se arma leyendo el StartServer64.bat que instala SteamCMD, en vez de
# hardcodear el classpath: asi el lanzador sigue siendo valido cuando el juego se actualiza.
# Ver docs/windows.md, seccion "Starting the server".

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'I18n.ps1')
. (Join-Path $PSScriptRoot 'Ui.ps1')
. (Join-Path $PSScriptRoot 'Render.ps1')
. (Join-Path $PSScriptRoot 'Rcon.ps1')
. (Join-Path $PSScriptRoot 'SteamCmd.ps1')

$script:ZsStartedMarker = 'SERVER STARTED'

function Get-ZsPidFilePath {
    <#
        .SYNOPSIS
        Ruta del archivo con el PID del proceso de java en curso.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    return (Join-Path (Join-Path $RepoRoot 'data') 'server.pid')
}

function Get-ZsLogFilePath {
    <#
        .SYNOPSIS
        Ruta del log del server (stdout y stderr combinados).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    return (Join-Path (Join-Path $RepoRoot 'data') (Join-Path 'logs' 'server.log'))
}

function Get-ZsCacheDir {
    <#
        .SYNOPSIS
        Ruta absoluta de -cachedir: data\zomboid, igual en Windows y en Linux.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    return (Join-Path (Join-Path $RepoRoot 'data') 'zomboid')
}

function Get-ZsStartServerBatPath {
    <#
        .SYNOPSIS
        Ruta del StartServer64.bat instalado por SteamCMD.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    return (Join-Path (Get-ZsServerDir -RepoRoot $RepoRoot) 'StartServer64.bat')
}

function Split-ZsCommandLine {
    <#
        .SYNOPSIS
        Separa una linea de comando en tokens, respetando segmentos entre comillas dobles.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Line
    )

    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($match in [regex]::Matches($Line, '"[^"]*"|\S+')) {
        $token = $match.Value
        if ($token.Length -ge 2 -and $token.StartsWith('"') -and $token.EndsWith('"')) {
            $token = $token.Substring(1, $token.Length - 2)
        }
        $tokens.Add($token)
    }
    return $tokens.ToArray()
}

function ConvertTo-ZsCommandLine {
    <#
        .SYNOPSIS
        Arma una linea de comando a partir de una lista de argumentos, entrecomillando los que
        tengan espacios. Se usa solo para mostrar y para pasarle el comando a cmd.exe.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    $parts = foreach ($argument in $Arguments) {
        if ($argument -match '\s') {
            '"{0}"' -f $argument
        }
        else {
            $argument
        }
    }
    return ($parts -join ' ')
}

function Find-ZsJavaLine {
    <#
        .SYNOPSIS
        Busca, en el texto de StartServer64.bat, la linea que invoca jre64\bin\java.exe.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter()]
        [string]$SourceName = 'StartServer64.bat'
    )

    foreach ($line in ($Text -split "\r?\n")) {
        if ($line -match '(?i)jre64[\\/]bin[\\/]java\.exe') {
            return $line.Trim()
        }
    }

    throw (Get-ZsText 'server.no_java_line' $SourceName)
}

function Get-ZsJavaCommand {
    <#
        .SYNOPSIS
        Arma el comando de java a partir del StartServer64.bat instalado: mantiene el classpath
        y los flags de la JVM, reemplaza -Xms/-Xmx y agrega los argumentos del server.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
        Justification = 'La contrasena va como argumento de linea de comando de java.exe (-adminpassword): un SecureString habria que desarmarlo igual para pasarselo al proceso.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '',
        Justification = 'AdminUsername/AdminPassword son los argumentos -adminusername/-adminpassword del server, no credenciales de autenticacion de este script.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$BatPath,

        [Parameter(Mandatory)]
        [string]$MinMemory,

        [Parameter(Mandatory)]
        [string]$MaxMemory,

        [Parameter(Mandatory)]
        [string]$AdminUsername,

        [Parameter(Mandatory)]
        [string]$AdminPassword,

        [Parameter(Mandatory)]
        [string]$CacheDir,

        [Parameter(Mandatory)]
        [int]$Port,

        [Parameter()]
        [string]$ServerName = 'servertest'
    )

    if (-not (Test-Path -LiteralPath $BatPath)) {
        throw (Get-ZsText 'server.no_bat' $BatPath)
    }

    $text = Read-ZsTextFile -Path $BatPath
    $line = Find-ZsJavaLine -Text $text -SourceName $BatPath
    $tokens = Split-ZsCommandLine -Line $line

    if ($tokens.Count -lt 1) {
        throw (Get-ZsText 'server.no_java_line' $BatPath)
    }

    $exeToken = $tokens[0]
    $kept = New-Object System.Collections.Generic.List[string]

    for ($i = 1; $i -lt $tokens.Count; $i++) {
        $token = $tokens[$i]
        if ($token -eq '%*') {
            # %* son los argumentos extra que StartServer64.bat le pasaria a mano: no aplica
            # cuando el comando lo arma este script.
            continue
        }
        if ($token -match '^(?i)-Xms') {
            $kept.Add("-Xms$MinMemory")
            continue
        }
        if ($token -match '^(?i)-Xmx') {
            $kept.Add("-Xmx$MaxMemory")
            continue
        }
        $kept.Add($token)
    }

    $kept.Add('-servername')
    $kept.Add($ServerName)
    $kept.Add('-adminusername')
    $kept.Add($AdminUsername)
    $kept.Add('-adminpassword')
    $kept.Add($AdminPassword)
    $kept.Add("-cachedir=$CacheDir")
    $kept.Add('-port')
    $kept.Add([string]$Port)

    $serverDir = Split-Path -Parent $BatPath
    $exeRelative = $exeToken -replace '^\.[\\/]', ''
    $exeRelative = $exeRelative -replace '/', '\'
    $exePath = Join-Path $serverDir $exeRelative

    return [pscustomobject]@{
        Executable       = $exePath
        Arguments        = $kept.ToArray()
        WorkingDirectory = $serverDir
    }
}

function Get-ZsLauncherPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepoRoot)
    return (Join-Path (Join-Path $RepoRoot 'data') 'zs-launch.cmd')
}

function ConvertTo-ZsBatchArgument {
    <#
        .SYNOPSIS
        Un argumento listo para una linea de un archivo .cmd: el % se duplica (cmd lo expande
        incluso entre comillas) y se entrecomilla si trae espacios o caracteres que cmd
        interpreta (& | < > ( ) ^ %). Las contrasenas del .env pueden traer varios de esos.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Argument)

    $escaped = $Argument.Replace('%', '%%')
    if ($escaped -match '[\s&|<>()^%"]' -or $escaped.Length -eq 0) {
        return '"{0}"' -f $escaped.Replace('"', '\"')
    }
    return $escaped
}

function Write-ZsLauncherScript {
    <#
        .SYNOPSIS
        Escribe el .cmd que arranca java.exe con stdout y stderr al log. Se regenera en cada
        arranque; es ASCII/ANSI a proposito (cmd no lee UTF-8 con BOM).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
        [Parameter(Mandatory)][string]$LogPath
    )

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add(('"{0}"' -f $Executable))
    foreach ($argument in $Arguments) {
        $parts.Add((ConvertTo-ZsBatchArgument -Argument $argument))
    }
    $lines = @(
        '@echo off',
        ('cd /D "{0}"' -f $WorkingDirectory),
        ('{0} >> "{1}" 2>&1' -f ($parts -join ' '), $LogPath)
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        [void](New-Item -ItemType Directory -Path $dir -Force)
    }
    [System.IO.File]::WriteAllText($Path, (($lines -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
}

function Get-ZsJavaChildProcessId {
    <#
        .SYNOPSIS
        El pid del java.exe hijo del cmd.exe lanzador (el pid file guarda el del cmd). Devuelve
        $null fuera de Windows o si no hay hijo.
    #>
    [CmdletBinding()]
    [OutputType([System.Nullable[int]])]
    param([Parameter(Mandatory)][int]$ParentProcessId)

    if (-not (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue)) {
        return $null
    }
    $children = @(Get-CimInstance -ClassName Win32_Process -Filter ("ParentProcessId = {0}" -f $ParentProcessId) -ErrorAction SilentlyContinue)
    foreach ($child in $children) {
        if ($child.Name -ieq 'java.exe') {
            return [int]$child.ProcessId
        }
    }
    return $null
}

function Test-ZsServerRunning {
    <#
        .SYNOPSIS
        Si el proceso del server sigue vivo, segun el pid file.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    $pidPath = Get-ZsPidFilePath -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $pidPath)) {
        return [pscustomobject]@{ Running = $false; ProcessId = $null }
    }

    $raw = (Get-Content -LiteralPath $pidPath -Raw).Trim()
    $processId = 0
    if (-not [int]::TryParse($raw, [ref]$processId)) {
        return [pscustomobject]@{ Running = $false; ProcessId = $null }
    }

    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        return [pscustomobject]@{ Running = $false; ProcessId = $processId }
    }

    return [pscustomobject]@{ Running = $true; ProcessId = $processId }
}

function Start-ZsServer {
    <#
        .SYNOPSIS
        Renderiza la config, arranca java.exe en segundo plano y espera "SERVER STARTED".
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Funcion interna de zs.ps1/setup.ps1, no un cmdlet interactivo: siempre arranca el server.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [System.Collections.Specialized.OrderedDictionary]$EnvValues,

        [Parameter()]
        [int]$TimeoutSeconds = 600
    )

    $running = Test-ZsServerRunning -RepoRoot $RepoRoot
    if ($running.Running) {
        throw (Get-ZsText 'server.already_running' $running.ProcessId)
    }

    Write-ZsStep (Get-ZsText 'server.rendering')
    [void](Invoke-ZsRender -RepoRoot $RepoRoot -Quiet)

    $batPath = Get-ZsStartServerBatPath -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $batPath)) {
        throw (Get-ZsText 'server.not_installed' $batPath)
    }

    $port = 16261
    if ($EnvValues.Contains('GAME_PORT') -and -not [string]::IsNullOrEmpty([string]$EnvValues['GAME_PORT'])) {
        $port = [int]$EnvValues['GAME_PORT']
    }

    $command = Get-ZsJavaCommand -BatPath $batPath `
        -MinMemory ([string]$EnvValues['MIN_MEMORY']) `
        -MaxMemory ([string]$EnvValues['MAX_MEMORY']) `
        -AdminUsername ([string]$EnvValues['ADMINUSERNAME']) `
        -AdminPassword ([string]$EnvValues['ADMINPASSWORD']) `
        -CacheDir (Get-ZsCacheDir -RepoRoot $RepoRoot) `
        -Port $port

    $logPath = Get-ZsLogFilePath -RepoRoot $RepoRoot
    $logDir = Split-Path -Parent $logPath
    if (-not (Test-Path -LiteralPath $logDir)) {
        [void](New-Item -ItemType Directory -Path $logDir -Force)
    }
    if (Test-Path -LiteralPath $logPath) {
        Remove-Item -LiteralPath $logPath -Force
    }

    # El comando se escribe en un .cmd propio y se lanza ese archivo. Pasarle a cmd.exe /c una
    # linea larga con comillas adentro (ruta del java, redireccion al log) cae en la regla de cmd
    # que pela la primera y la ultima comilla de la linea y rompe la redireccion. Un batch no
    # tiene ese problema y ademas deja ver exactamente que se ejecuto.
    $launcherPath = Get-ZsLauncherPath -RepoRoot $RepoRoot
    Write-ZsLauncherScript -Path $launcherPath -WorkingDirectory $command.WorkingDirectory `
        -Executable $command.Executable -Arguments $command.Arguments -LogPath $logPath

    Write-ZsStep (Get-ZsText 'server.starting')
    $process = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', ('"{0}"' -f $launcherPath)) `
        -WorkingDirectory $command.WorkingDirectory -WindowStyle Hidden -PassThru

    $pidPath = Get-ZsPidFilePath -RepoRoot $RepoRoot
    $pidDir = Split-Path -Parent $pidPath
    if (-not (Test-Path -LiteralPath $pidDir)) {
        [void](New-Item -ItemType Directory -Path $pidDir -Force)
    }
    Set-Content -LiteralPath $pidPath -Value ([string]$process.Id) -NoNewline

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path -LiteralPath $logPath) -and
            (Select-String -LiteralPath $logPath -Pattern $script:ZsStartedMarker -SimpleMatch -Quiet)) {
            Write-ZsOk (Get-ZsText 'server.started' $process.Id)
            return [pscustomobject]@{ ProcessId = $process.Id; LogPath = $logPath }
        }
        if ($null -eq (Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) {
            $tail = Get-ZsLogTail -LogPath $logPath
            throw (Get-ZsText 'server.exited_early' $tail)
        }
        Start-Sleep -Seconds 2
    }

    $tail = Get-ZsLogTail -LogPath $logPath
    throw (Get-ZsText 'server.start_timeout' $TimeoutSeconds $tail)
}

function Get-ZsLogTail {
    <#
        .SYNOPSIS
        Ultimas lineas del log, para mostrarlas cuando algo falla.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$LogPath,

        [Parameter()]
        [int]$Lines = 20
    )

    if (-not (Test-Path -LiteralPath $LogPath)) {
        return ''
    }
    return ((Get-Content -LiteralPath $LogPath -Tail $Lines) -join "`n")
}

function Stop-ZsServer {
    <#
        .SYNOPSIS
        Apagado limpio: aviso si hay gente, save, quit por RCON; si no sale solo, se lo mata.
        Misma secuencia que scripts/stop.sh.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Funcion interna de zs.ps1, no un cmdlet interactivo: siempre apaga el server.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [System.Collections.Specialized.OrderedDictionary]$EnvValues,

        [Parameter()]
        [int]$WarnSeconds = 60,

        [Parameter()]
        [int]$TimeoutSeconds = 120
    )

    $status = Test-ZsServerRunning -RepoRoot $RepoRoot
    if (-not $status.Running) {
        Write-ZsOk (Get-ZsText 'server.not_running')
        return
    }

    $warn = $WarnSeconds
    try {
        $players = Invoke-ZsRconFromEnv -Command 'players' -EnvValues $EnvValues
        if ($players -match 'Players connected \(0\)') {
            $warn = 0
        }
    }
    catch {
        Write-ZsWarn (Get-ZsText 'server.rcon_players_failed' $_.Exception.Message)
    }

    if ($warn -gt 0) {
        Write-ZsStep (Get-ZsText 'server.warning' $warn)
        try {
            [void](Invoke-ZsRconFromEnv -Command ('servermsg "Server shutting down in {0} seconds."' -f $warn) -EnvValues $EnvValues)
        }
        catch {
            Write-Verbose "servermsg failed: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds $warn
    }

    Write-ZsStep (Get-ZsText 'server.saving')
    try {
        [void](Invoke-ZsRconFromEnv -Command 'save' -EnvValues $EnvValues)
    }
    catch {
        Write-ZsWarn (Get-ZsText 'server.save_failed' $_.Exception.Message)
    }
    Start-Sleep -Seconds 5

    Write-ZsStep (Get-ZsText 'server.quitting')
    try {
        [void](Invoke-ZsRconFromEnv -Command 'quit' -EnvValues $EnvValues)
    }
    catch {
        Write-Verbose "quit failed (expected: rcon disconnects while the world saves): $($_.Exception.Message)"
    }

    $waited = 0
    while ($waited -lt $TimeoutSeconds) {
        $status = Test-ZsServerRunning -RepoRoot $RepoRoot
        if (-not $status.Running) {
            Remove-Item -LiteralPath (Get-ZsPidFilePath -RepoRoot $RepoRoot) -Force -ErrorAction SilentlyContinue
            Write-ZsOk (Get-ZsText 'server.stopped' $waited)
            return
        }
        Start-Sleep -Seconds 2
        $waited += 2
    }

    Write-ZsWarn (Get-ZsText 'server.forced' $TimeoutSeconds)
    $javaPid = Get-ZsJavaChildProcessId -ParentProcessId $status.ProcessId
    if ($null -ne $javaPid) {
        Stop-Process -Id $javaPid -Force -ErrorAction SilentlyContinue
    }
    Stop-Process -Id $status.ProcessId -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Get-ZsPidFilePath -RepoRoot $RepoRoot) -Force -ErrorAction SilentlyContinue
}

function Get-ZsServerStatus {
    <#
        .SYNOPSIS
        Estado del server: proceso, jugadores conectados (por RCON) y ultimas lineas del log.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [System.Collections.Specialized.OrderedDictionary]$EnvValues
    )

    $running = Test-ZsServerRunning -RepoRoot $RepoRoot
    $players = $null
    if ($running.Running) {
        try {
            $players = Invoke-ZsRconFromEnv -Command 'players' -EnvValues $EnvValues
        }
        catch {
            $players = Get-ZsText 'server.rcon_unreachable' $_.Exception.Message
        }
    }

    $logPath = Get-ZsLogFilePath -RepoRoot $RepoRoot
    return [pscustomobject]@{
        Running      = $running.Running
        ProcessId    = $running.ProcessId
        Players      = $players
        LastLogLines = Get-ZsLogTail -LogPath $logPath -Lines 10
    }
}
