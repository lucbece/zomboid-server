# Idioma del CLI de Windows y catalogo de mensajes. No se ejecuta: se hace dot-source.
#
# Es el equivalente de scripts/lib/i18n.sh. El idioma sale, en este orden:
#   1. la variable de entorno ZS_LANG
#   2. la linea ZS_LANG= del .env del repo (se lee con regex, no cargando el .env entero:
#      el .env tiene contrasenas y lo carga cada comando cuando le toca)
#   3. la cultura de la interfaz del sistema (es* -> es)
#   4. en
#
# Solo valen "es" y "en"; cualquier otra cosa cae a "en". El catalogo ingles se carga siempre
# primero, asi una clave que le falte al castellano sale en ingles y no como la clave pelada.
#
# Uso:
#   Get-ZsText 'render.no_env' $ruta      -> el mensaje formateado con -f
#
# Los placeholders son los de -f ({0}, {1}); una llave literal se escribe {{ o }}.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ZsCatalog = $null
$script:ZsLanguage = $null

function Get-ZsLanguage {
    <#
        .SYNOPSIS
        Resuelve el idioma del CLI (es o en).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$EnvFile
    )

    $candidate = ''
    if ($null -ne $env:ZS_LANG) {
        $candidate = $env:ZS_LANG
    }

    if ([string]::IsNullOrWhiteSpace($candidate) -and -not [string]::IsNullOrEmpty($EnvFile) -and (Test-Path -LiteralPath $EnvFile)) {
        foreach ($line in [System.IO.File]::ReadAllLines($EnvFile)) {
            $m = [regex]::Match($line, '^\s*ZS_LANG\s*=\s*"?([A-Za-z_]*)"?\s*$')
            if ($m.Success) {
                $candidate = $m.Groups[1].Value
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = [System.Globalization.CultureInfo]::CurrentUICulture.Name
    }

    if ($candidate -match '^(?i)es') { return 'es' }
    return 'en'
}

function Initialize-ZsI18n {
    <#
        .SYNOPSIS
        Carga los catalogos de mensajes y deja la consola en UTF-8.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter()]
        [ValidateSet('es', 'en')]
        [string]$Language,

        [Parameter()]
        [string]$EnvFile
    )

    if ([string]::IsNullOrEmpty($Language)) {
        $Language = Get-ZsLanguage -EnvFile $EnvFile
    }

    # Windows PowerShell 5.1 escribe en la code page de la consola (850/437 en la mayoria de
    # las instalaciones en castellano) y se come las tildes de los catalogos. Se fuerza UTF-8;
    # si no hay consola de verdad (salida redirigida, host sin consola) la asignacion tira y
    # el mensaje sale igual, solo que con la codificacion del host.
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    }
    catch {
        Write-Verbose "no se pudo poner la consola en UTF-8: $($_.Exception.Message)"
    }

    $catalogDir = Join-Path $PSScriptRoot 'i18n'
    $catalog = @{}

    foreach ($lang in @('en', $Language) | Select-Object -Unique) {
        $path = Join-Path $catalogDir "$lang.psd1"
        if (-not (Test-Path -LiteralPath $path)) {
            throw "i18n: falta el catalogo $path"
        }
        $data = Import-PowerShellDataFile -LiteralPath $path
        foreach ($key in $data.Keys) {
            $catalog[$key] = $data[$key]
        }
    }

    $script:ZsCatalog = $catalog
    $script:ZsLanguage = $Language
}

function Get-ZsCurrentLanguage {
    <#
        .SYNOPSIS
        Devuelve el idioma con el que se cargo el catalogo.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($null -eq $script:ZsLanguage) {
        Initialize-ZsI18n
    }
    return $script:ZsLanguage
}

function Get-ZsText {
    <#
        .SYNOPSIS
        Devuelve el mensaje del catalogo formateado con los argumentos que se le pasen.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Key,

        [Parameter(Position = 1, ValueFromRemainingArguments)]
        [object[]]$Arguments
    )

    if ($null -eq $script:ZsCatalog) {
        Initialize-ZsI18n
    }

    if (-not $script:ZsCatalog.ContainsKey($Key)) {
        # Una traduccion que falta se tiene que notar, pero nunca romper un comando.
        Write-Warning "i18n: missing key $Key"
        return $Key
    }

    $format = [string]$script:ZsCatalog[$Key]
    if ($null -eq $Arguments -or $Arguments.Count -eq 0) {
        return $format
    }
    return ($format -f $Arguments)
}

function Get-ZsCatalogKey {
    <#
        .SYNOPSIS
        Lista las claves de un catalogo. La usa el test que compara es y en.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('es', 'en')]
        [string]$Language
    )

    $path = Join-Path (Join-Path $PSScriptRoot 'i18n') "$Language.psd1"
    $data = Import-PowerShellDataFile -LiteralPath $path
    return @($data.Keys | Sort-Object)
}
