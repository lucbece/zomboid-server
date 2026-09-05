# Renderiza la config versionada de config/ hacia data\zomboid\Server\. No se ejecuta: se hace
# dot-source.
#
#   config\servertest.ini.tpl + .env + config\mods.txt -> data\zomboid\Server\servertest.ini
#   config\*.lua                                       -> data\zomboid\Server\
#
# Tiene que dar el MISMO resultado, byte a byte, que scripts/render-config.sh con las mismas
# entradas: es el contrato entre los dos motores y lo verifica windows\tests\Render.Tests.ps1.
# Cualquier cambio aca va acompanado del mismo cambio alla.
#
# config\mods.txt es opcional y no se versiona: sin el, la partida es vanilla (sin mods).
# Falla si falta cualquier variable que el template use, y tambien si el ini ya renderizado
# tenia mods y ahora no habria ninguno (ALLOW_VANILLA=1 lo permite): sacar todos los mods de
# un mundo existente rompe los objetos y celdas que dependen de ellos.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'I18n.ps1')
. (Join-Path $PSScriptRoot 'Env.ps1')
. (Join-Path $PSScriptRoot 'Mods.ps1')

# Estas pueden estar definidas pero vacias (placeholders opcionales). Misma lista que
# MAY_BE_EMPTY en scripts/render-config.sh.
$script:ZsMayBeEmpty = @(
    'DISCORD_TOKEN',
    'DISCORD_CHAT_CHANNEL',
    'DISCORD_LOG_CHANNEL',
    'DISCORD_COMMAND_CHANNEL',
    'MODS',
    'WORKSHOP_ITEMS'
)

# El mismo patron que busca el grep del script de bash, y el mismo que reconoce envsubst.
$script:ZsPlaceholderPattern = '\$\{([A-Za-z_][A-Za-z0-9_]*)\}'

function Get-ZsRenderVariable {
    <#
        .SYNOPSIS
        Arma el juego de variables con el que se rellena el template: el entorno del proceso
        con el .env encima, que es lo que hace `set -a; source .env` en bash.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [string]$EnvFile
    )

    $values = [ordered]@{}
    foreach ($entry in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) {
        $values[[string]$entry.Key] = [string]$entry.Value
    }

    foreach ($entry in (Read-ZsEnvFile -Path $EnvFile).GetEnumerator()) {
        $values[[string]$entry.Key] = [string]$entry.Value
    }

    # Variables agregadas despues de que existieran .env en produccion: con default, para que
    # un .env viejo siga rendereando. Las nuevas de verdad siguen siendo obligatorias.
    # Es el `export UPNP="${UPNP:-false}"` de scripts/render-config.sh.
    if (-not $values.Contains('UPNP') -or [string]::IsNullOrEmpty([string]$values['UPNP'])) {
        $values['UPNP'] = 'false'
    }

    return $values
}

function Expand-ZsTemplate {
    <#
        .SYNOPSIS
        Sustituye los ${VAR} del template en una sola pasada, como hace envsubst con una lista
        de variables. Lo sustituido no se vuelve a mirar.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Template,

        [Parameter(Mandatory)]
        [System.Collections.Specialized.OrderedDictionary]$Values
    )

    # A mano y no con un MatchEvaluator: la sustitucion tiene que ser de una sola pasada (lo
    # que se escribe no se vuelve a mirar), que es exactamente lo que hace envsubst, y asi no
    # depende de como PowerShell convierte un scriptblock en delegado.
    $builder = New-Object System.Text.StringBuilder
    $position = 0
    foreach ($match in [regex]::Matches($Template, $script:ZsPlaceholderPattern)) {
        [void]$builder.Append($Template.Substring($position, $match.Index - $position))
        $name = $match.Groups[1].Value
        if ($Values.Contains($name)) {
            [void]$builder.Append([string]$Values[$name])
        }
        else {
            [void]$builder.Append($match.Value)
        }
        $position = $match.Index + $match.Length
    }
    [void]$builder.Append($Template.Substring($position))

    return $builder.ToString()
}

function Get-ZsTemplateVariable {
    <#
        .SYNOPSIS
        Lista, sin repetir y ordenada, las variables ${VAR} que usa el template.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Template
    )

    $names = New-Object System.Collections.Generic.List[string]
    foreach ($match in [regex]::Matches($Template, $script:ZsPlaceholderPattern)) {
        $name = $match.Groups[1].Value
        if (-not $names.Contains($name)) {
            $names.Add($name)
        }
    }
    return @($names | Sort-Object -CaseSensitive)
}

function Read-ZsTextFile {
    <#
        .SYNOPSIS
        Lee un archivo como texto UTF-8 sin tocar los saltos de linea.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return (New-Object System.Text.UTF8Encoding($false)).GetString($bytes)
}

function Write-ZsTextFile {
    <#
        .SYNOPSIS
        Escribe texto como UTF-8 sin BOM y sin agregar ningun salto de linea al final.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [Parameter(Mandatory, Position = 1)]
        [AllowEmptyString()]
        [string]$Text
    )

    [System.IO.File]::WriteAllBytes($Path, (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text))
}

function Invoke-ZsRender {
    <#
        .SYNOPSIS
        Renderiza config\ + .env hacia data\zomboid\Server\.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter()]
        [string]$EnvFile,

        [Parameter()]
        [string]$ServerDir,

        [Parameter()]
        [switch]$AllowVanilla,

        [Parameter()]
        [switch]$Quiet
    )

    if ([string]::IsNullOrEmpty($EnvFile)) {
        $EnvFile = Join-Path $RepoRoot '.env'
    }
    $configDir = Join-Path $RepoRoot 'config'
    if ([string]::IsNullOrEmpty($ServerDir)) {
        $ServerDir = Join-Path (Join-Path (Join-Path $RepoRoot 'data') 'zomboid') 'Server'
    }

    $templatePath = Join-Path $configDir 'servertest.ini.tpl'
    $modsPath = Join-Path $configDir 'mods.txt'
    $sandboxPath = Join-Path $configDir 'servertest_SandboxVars.lua'
    $samplePath = Join-Path $configDir 'servertest_SandboxVars.example.lua'
    $outIni = Join-Path $ServerDir 'servertest.ini'

    $notes = New-Object System.Collections.Generic.List[string]

    if (-not (Test-Path -LiteralPath $EnvFile)) {
        throw (Get-ZsText 'render.no_env' $EnvFile)
    }
    if (-not (Test-Path -LiteralPath $templatePath)) {
        throw (Get-ZsText 'render.no_tpl' $templatePath)
    }

    $values = Get-ZsRenderVariable -EnvFile $EnvFile

    # --- Mods: config\mods.txt -> MODS / WORKSHOP_ITEMS ---------------------------------------
    $modIdPrefix = ''
    if ($values.Contains('MOD_ID_PREFIX')) {
        $modIdPrefix = [string]$values['MOD_ID_PREFIX']
    }

    if (Test-Path -LiteralPath $modsPath) {
        $parsed = ConvertFrom-ZsModsFile -Path $modsPath -ModIdPrefix $modIdPrefix -SourceName $modsPath
    }
    else {
        $notes.Add((Get-ZsText 'render.no_mods'))
        $parsed = [pscustomobject]@{ Mods = @(); WorkshopItems = @() }
    }

    $mods = ($parsed.Mods -join ';')
    $workshopItems = ($parsed.WorkshopItems -join ';')
    $values['MODS'] = $mods
    $values['WORKSHOP_ITEMS'] = $workshopItems

    # --- Freno: no sacar todos los mods de un mundo que ya los tenia --------------------------
    # Si el mundo ya corria con mods y este render los sacaria todos, lo mas probable es que
    # config\mods.txt se haya perdido (no se versiona), no que alguien quiera un mundo vanilla.
    $allow = $AllowVanilla.IsPresent -or ($env:ALLOW_VANILLA -eq '1')
    if ([string]::IsNullOrEmpty($mods) -and (Test-Path -LiteralPath $outIni) -and -not $allow) {
        $previous = ''
        foreach ($line in ((Read-ZsTextFile -Path $outIni) -split "\r?\n")) {
            if ($line.StartsWith('Mods=')) {
                $previous = $line.Substring(5)
                break
            }
        }
        if (-not [string]::IsNullOrEmpty($previous)) {
            throw (Get-ZsText 'render.vanilla_block' $previous)
        }
    }

    # --- Validacion: toda variable ${VAR} del template tiene que estar definida ---------------
    $template = Read-ZsTextFile -Path $templatePath
    $templateVars = @(Get-ZsTemplateVariable -Template $template)
    if ($templateVars.Count -eq 0) {
        throw (Get-ZsText 'render.no_tpl_vars' $templatePath)
    }

    $missing = New-Object System.Collections.Generic.List[string]
    $empty = New-Object System.Collections.Generic.List[string]
    foreach ($name in $templateVars) {
        if (-not $values.Contains($name)) {
            $missing.Add($name)
        }
        elseif ([string]::IsNullOrEmpty([string]$values[$name]) -and $script:ZsMayBeEmpty -notcontains $name) {
            $empty.Add($name)
        }
    }
    if ($missing.Count -gt 0) {
        throw (Get-ZsText 'render.missing_vars' $EnvFile ($missing -join ' '))
    }
    if ($empty.Count -gt 0) {
        throw (Get-ZsText 'render.empty_vars' $EnvFile ($empty -join ' '))
    }

    # --- Render -------------------------------------------------------------------------------
    if (-not (Test-Path -LiteralPath $ServerDir)) {
        [void](New-Item -ItemType Directory -Path $ServerDir -Force)
    }

    $rendered = Expand-ZsTemplate -Template $template -Values $values
    if ($rendered.Contains('${')) {
        throw (Get-ZsText 'render.placeholders')
    }

    $temporary = "$outIni.tmp"
    Write-ZsTextFile -Path $temporary -Text $rendered
    Move-Item -LiteralPath $temporary -Destination $outIni -Force

    # config\servertest_SandboxVars.lua es propio de cada partida y no se versiona: si falta, se
    # usa el ejemplo versionado (valores vanilla del juego).
    if (-not (Test-Path -LiteralPath $sandboxPath)) {
        $notes.Add((Get-ZsText 'render.no_sandbox'))
        Copy-Item -LiteralPath $samplePath -Destination (Join-Path $ServerDir 'servertest_SandboxVars.lua') -Force
    }

    foreach ($lua in (Get-ChildItem -LiteralPath $configDir -Filter '*.lua' -File | Sort-Object -Property Name)) {
        if ($lua.Name -like '*.example.lua') {
            continue
        }
        Copy-Item -LiteralPath $lua.FullName -Destination (Join-Path $ServerDir $lua.Name) -Force
    }

    if (-not $Quiet) {
        foreach ($note in $notes) {
            Write-Information -MessageData $note -InformationAction Continue
        }
    }

    return [pscustomobject]@{
        Ini           = $outIni
        ServerDir     = $ServerDir
        Mods          = $mods
        WorkshopItems = $workshopItems
        Notes         = $notes.ToArray()
    }
}
