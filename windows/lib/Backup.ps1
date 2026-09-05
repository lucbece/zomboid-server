# Backup local: save por RCON y zip de Server\, Saves\ y db\ a backups\. No se ejecuta: se
# hace dot-source.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'I18n.ps1')
. (Join-Path $PSScriptRoot 'Ui.ps1')
. (Join-Path $PSScriptRoot 'Rcon.ps1')

$script:ZsBackupDirNames = @('Server', 'Saves', 'db')

function Get-ZsBackupTimestamp {
    <#
        .SYNOPSIS
        Marca de tiempo para el nombre del zip de backup, ordenable como texto.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [datetime]$Date = (Get-Date)
    )

    return $Date.ToString('yyyyMMdd-HHmmss')
}

function Get-ZsBackupDir {
    <#
        .SYNOPSIS
        Directorio donde se guardan los zip de backup.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    return (Join-Path $RepoRoot 'backups')
}

function Get-ZsBackupPath {
    <#
        .SYNOPSIS
        Ruta completa del zip de un backup, dada su marca de tiempo.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [string]$Timestamp
    )

    return (Join-Path (Get-ZsBackupDir -RepoRoot $RepoRoot) "$Timestamp.zip")
}

function Get-ZsBackupSourceDir {
    <#
        .SYNOPSIS
        Los subdirectorios de data\zomboid\ que van al zip (Server, Saves, db), los que existan.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    $zomboidDir = Join-Path (Join-Path $RepoRoot 'data') 'zomboid'
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($name in $script:ZsBackupDirNames) {
        $path = Join-Path $zomboidDir $name
        if (Test-Path -LiteralPath $path) {
            $found.Add($path)
        }
    }
    return $found.ToArray()
}

function Compress-ZsDirectory {
    <#
        .SYNOPSIS
        Zip de uno o mas directorios, leyendo cada archivo con FileShare ReadWrite.
        Compress-Archive abre los archivos sin compartir y falla con players.db y las demas
        bases SQLite que el server tiene abiertas ("being used by another process"); SQLite
        si permite lectores concurrentes, y el `save` por RCON que se hace antes deja el
        contenido consistente. Las entradas se nombran <carpeta>/<ruta relativa> con '/'.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Source,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Force
    }

    $zipStream = New-Object System.IO.FileStream($Destination, [System.IO.FileMode]::CreateNew)
    $archive = New-Object System.IO.Compression.ZipArchive($zipStream, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($dir in $Source) {
            $root = (Get-Item -LiteralPath $dir).FullName.TrimEnd('\', '/')
            $prefix = Split-Path -Leaf $root
            foreach ($file in (Get-ChildItem -LiteralPath $root -File -Recurse -Force)) {
                $relative = $file.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
                $entry = $archive.CreateEntry("$prefix/$relative", [System.IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $file.LastWriteTime
                $input = New-Object System.IO.FileStream($file.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
                try {
                    $output = $entry.Open()
                    try { $input.CopyTo($output) } finally { $output.Dispose() }
                }
                finally {
                    $input.Dispose()
                }
            }
        }
    }
    finally {
        $archive.Dispose()
        $zipStream.Dispose()
    }
}

function New-ZsBackup {
    <#
        .SYNOPSIS
        Guarda el mundo por RCON (si el server esta corriendo) y arma un zip de backup.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Funcion interna de la CLI de zs.ps1, no un cmdlet interactivo: siempre hace el backup, nunca pregunta.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [System.Collections.Specialized.OrderedDictionary]$EnvValues,

        [Parameter()]
        [switch]$SkipRcon
    )

    if (-not $SkipRcon) {
        try {
            Write-ZsStep (Get-ZsText 'backup.saving')
            [void](Invoke-ZsRconFromEnv -Command 'save' -EnvValues $EnvValues)
        }
        catch {
            Write-ZsWarn (Get-ZsText 'backup.save_failed' $_.Exception.Message)
        }
    }

    $sources = Get-ZsBackupSourceDir -RepoRoot $RepoRoot
    if ($sources.Count -eq 0) {
        throw (Get-ZsText 'backup.no_data')
    }

    $backupDir = Get-ZsBackupDir -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $backupDir)) {
        [void](New-Item -ItemType Directory -Path $backupDir -Force)
    }

    $timestamp = Get-ZsBackupTimestamp
    $zipPath = Get-ZsBackupPath -RepoRoot $RepoRoot -Timestamp $timestamp

    Write-ZsStep (Get-ZsText 'backup.zipping' $zipPath)
    Compress-ZsDirectory -Source $sources -Destination $zipPath

    $keepDays = 3
    if ($EnvValues.Contains('BACKUP_KEEP_LOCAL_DAYS') -and -not [string]::IsNullOrEmpty([string]$EnvValues['BACKUP_KEEP_LOCAL_DAYS'])) {
        $keepDays = [int]$EnvValues['BACKUP_KEEP_LOCAL_DAYS']
    }
    $removed = Remove-ZsOldBackup -RepoRoot $RepoRoot -KeepDays $keepDays

    Write-ZsOk (Get-ZsText 'backup.done' $zipPath)
    if ($removed.Count -gt 0) {
        Write-ZsOk (Get-ZsText 'backup.pruned' $removed.Count)
    }

    return $zipPath
}

function Remove-ZsOldBackup {
    <#
        .SYNOPSIS
        Borra los zip de backups\ mas viejos que KeepDays. Devuelve las rutas borradas.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Funcion interna de retencion de backups, no un cmdlet interactivo: siempre borra lo vencido.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [int]$KeepDays,

        [Parameter()]
        [datetime]$Now = (Get-Date)
    )

    $backupDir = Get-ZsBackupDir -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $backupDir)) {
        return @()
    }

    $threshold = $Now.AddDays(-1 * $KeepDays)
    $removed = New-Object System.Collections.Generic.List[string]

    foreach ($zip in (Get-ChildItem -LiteralPath $backupDir -Filter '*.zip' -File)) {
        if ($zip.LastWriteTime -lt $threshold) {
            Remove-Item -LiteralPath $zip.FullName -Force
            $removed.Add($zip.FullName)
        }
    }

    return $removed.ToArray()
}
