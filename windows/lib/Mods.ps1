# Parser de config/mods.txt, con la misma gramatica que scripts/render-config.sh. No se
# ejecuta: se hace dot-source.
#
# Formato, una linea por item del Workshop:
#   <workshop_id>  <mod_id>[; <mod_id>; ...]  # comentario libre
#
# - Todo lo que sigue al primer # es comentario, y las lineas vacias se ignoran.
# - El workshop_id es el primer campo y tiene que ser un numero.
# - Los Mod IDs pueden tener espacios ("Jump Jump"), asi que el campo va hasta el final de la
#   linea y los sub-mods se separan con ';'.
# - Un item del Workshop puede traer varios mods: no se repite en WorkshopItems=.
# - El orden del archivo es el orden de carga de Mods=.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'I18n.ps1')

function ConvertFrom-ZsModsText {
    <#
        .SYNOPSIS
        Convierte el texto de un mods.txt en las listas Mods= y WorkshopItems=.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter()]
        [AllowEmptyString()]
        [string]$ModIdPrefix = '',

        [Parameter()]
        [string]$SourceName = 'config/mods.txt'
    )

    $modIds = New-Object System.Collections.Generic.List[string]
    $workshopIds = New-Object System.Collections.Generic.List[string]

    $lineNumber = 0
    foreach ($rawLine in ($Text -split "\r?\n")) {
        $lineNumber++

        $line = $rawLine
        $hash = $line.IndexOf('#')
        if ($hash -ge 0) {
            $line = $line.Substring(0, $hash)
        }
        $line = $line.Trim()
        if ($line.Length -eq 0) {
            continue
        }

        $match = [regex]::Match($line, '^(\S+)(.*)$')
        $workshopId = $match.Groups[1].Value
        $idsField = $match.Groups[2].Value.Trim()

        if ($workshopId -notmatch '^[0-9]+$') {
            throw (Get-ZsText 'render.bad_workshop_id' $SourceName $lineNumber $workshopId)
        }
        if ($idsField.Length -eq 0) {
            throw (Get-ZsText 'render.missing_modid' $SourceName $lineNumber $workshopId)
        }

        foreach ($part in ($idsField -split ';')) {
            $modId = $part.Trim()
            if ($modId.Length -eq 0) {
                continue
            }
            $modIds.Add($ModIdPrefix + $modId)
        }

        if (-not $workshopIds.Contains($workshopId)) {
            $workshopIds.Add($workshopId)
        }
    }

    return [pscustomobject]@{
        Mods          = $modIds.ToArray()
        WorkshopItems = $workshopIds.ToArray()
    }
}

function ConvertFrom-ZsModsFile {
    <#
        .SYNOPSIS
        Lee config/mods.txt y devuelve las listas Mods= y WorkshopItems=.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [Parameter()]
        [AllowEmptyString()]
        [string]$ModIdPrefix = '',

        [Parameter()]
        [string]$SourceName
    )

    if ([string]::IsNullOrEmpty($SourceName)) {
        $SourceName = $Path
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes)
    if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) {
        $text = $text.Substring(1)
    }

    return (ConvertFrom-ZsModsText -Text $text -ModIdPrefix $ModIdPrefix -SourceName $SourceName)
}
