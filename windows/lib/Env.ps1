# Lectura y escritura del .env del repo, con el mismo formato y las mismas claves que el .env
# que escribe setup.sh. No se ejecuta: se hace dot-source.
#
# El .env lo parsean tres cosas distintas: bash (`source`), Docker Compose y este archivo. Las
# reglas que se respetan son las de bash, que es el mas viejo de los tres:
#   - lineas vacias y las que empiezan con # se ignoran
#   - CLAVE=valor, con o sin `export` adelante
#   - "valor entre comillas dobles": \\ \" \$ \` son escapes, el resto es literal
#   - 'valor entre comillas simples': todo literal
#   - sin comillas: el valor termina en el primer ` #` (comentario al final de la linea)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'I18n.ps1')

# Mismo juego de caracteres que valida infra/terraform/modules/oci/variables.tf y que usa
# setup.sh: el .env lo leen dos parsers distintos, que no escapan igual.
$script:ZsPasswordPattern = '^[A-Za-z0-9._@#%^&*()+=:,/-]{8,64}$'
$script:ZsNamePattern = '^[^"\\$`]{1,64}$'

function Get-ZsPasswordPattern {
    <#
        .SYNOPSIS
        Expresion regular que tiene que cumplir una contrasena del .env.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return $script:ZsPasswordPattern
}

function Test-ZsPassword {
    <#
        .SYNOPSIS
        Valida una contrasena con la misma regla que setup.sh.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Value
    )

    return ($Value -cmatch $script:ZsPasswordPattern)
}

function Test-ZsPublicName {
    <#
        .SYNOPSIS
        Valida el nombre publico del servidor con la misma regla que setup.sh.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Value
    )

    return ($Value -cmatch $script:ZsNamePattern)
}

function ConvertFrom-ZsEnvText {
    <#
        .SYNOPSIS
        Convierte el texto de un .env en un diccionario ordenado.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Text
    )

    $values = [ordered]@{}

    foreach ($rawLine in ($Text -split "\r?\n")) {
        $line = $rawLine.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#')) {
            continue
        }

        $match = [regex]::Match($line, '^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$')
        if (-not $match.Success) {
            continue
        }

        $name = $match.Groups[1].Value
        $rest = $match.Groups[2].Value.TrimStart()

        if ($rest.StartsWith('"')) {
            $values[$name] = Read-ZsQuotedValue -Text $rest -Quote '"'
        }
        elseif ($rest.StartsWith("'")) {
            $values[$name] = Read-ZsQuotedValue -Text $rest -Quote "'"
        }
        else {
            # Sin comillas, bash corta el valor en el primer ` #`: `FOO=bar # nota` vale "bar",
            # pero `FOO=bar#baz` vale "bar#baz" porque ese # no empieza una palabra.
            $value = $rest
            $comment = [regex]::Match($value, '\s#')
            if ($comment.Success) {
                $value = $value.Substring(0, $comment.Index)
            }
            $values[$name] = $value.TrimEnd()
        }
    }

    return $values
}

function Read-ZsQuotedValue {
    <#
        .SYNOPSIS
        Devuelve el contenido de un valor entrecomillado, aplicando los escapes de bash.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [ValidateSet('"', "'")]
        [string]$Quote
    )

    $builder = New-Object System.Text.StringBuilder
    $i = 1
    while ($i -lt $Text.Length) {
        $char = $Text[$i]
        if ($Quote -eq '"' -and $char -eq '\' -and ($i + 1) -lt $Text.Length) {
            $next = $Text[$i + 1]
            # Dentro de comillas dobles bash solo trata como escape estos cuatro: en cualquier
            # otro caso la barra invertida es un caracter mas.
            if ($next -eq '\' -or $next -eq '"' -or $next -eq '$' -or $next -eq '`') {
                [void]$builder.Append($next)
                $i += 2
                continue
            }
        }
        if ("$char" -eq $Quote) {
            break
        }
        [void]$builder.Append($char)
        $i++
    }

    return $builder.ToString()
}

function Read-ZsEnvFile {
    <#
        .SYNOPSIS
        Lee un .env y devuelve un diccionario ordenado con sus claves.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw (Get-ZsText 'render.no_env' $Path)
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes)
    if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) {
        $text = $text.Substring(1)
    }

    return (ConvertFrom-ZsEnvText -Text $text)
}

function ConvertTo-ZsEnvLine {
    <#
        .SYNOPSIS
        Arma una linea CLAVE=valor del .env, entrecomillando cuando hace falta.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,

        [Parameter(Position = 1)]
        [AllowEmptyString()]
        [string]$Value = '',

        [Parameter()]
        [switch]$Quote
    )

    if ($Quote -or $Value -match '\s') {
        # Con .Replace() y no con -replace: en el reemplazo de -replace el signo $ es especial.
        $escaped = $Value.Replace('\', '\\').Replace('"', '\"').Replace('$', '\$').Replace('`', '\`')
        return ('{0}="{1}"' -f $Name, $escaped)
    }
    return ('{0}={1}' -f $Name, $Value)
}

function Write-ZsEnvFile {
    <#
        .SYNOPSIS
        Escribe el .env del repo con las mismas claves y el mismo orden que setup.sh.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
        Justification = 'El .env es un archivo de texto que leen bash y Docker Compose: la contrasena se escribe en claro por definicion.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '',
        Justification = 'No hay autenticacion aca: son los valores que van al archivo de configuracion.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$AdminPassword,

        [Parameter(Mandatory)]
        [string]$RconPassword,

        [Parameter(Mandatory)]
        [string]$ServerPassword,

        [Parameter(Mandatory)]
        [string]$PublicName,

        [Parameter(Mandatory)]
        [int]$MaxPlayers,

        [Parameter(Mandatory)]
        [string]$MaxMemory,

        [Parameter(Mandatory)]
        [ValidateSet('es', 'en')]
        [string]$Language,

        [Parameter()]
        [string]$AdminUsername = 'admin',

        [Parameter()]
        [int]$RconPort = 27015,

        [Parameter()]
        [int]$GamePort = 16261,

        [Parameter()]
        [int]$GameUdpPort = 16262,

        [Parameter()]
        [string]$MinMemory = '2048m',

        [Parameter()]
        [bool]$Upnp = $true
    )

    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    $upnpValue = if ($Upnp) { 'true' } else { 'false' }

    $lines = @(
        "# Generado por windows\setup.cmd el $stamp."
        '# Tiene contrasenas: esta en .gitignore, NUNCA lo subas a GitHub.'
        '#'
        '# Este .env es el de ESTA computadora. Lo leen los scripts de windows\ y, si algun dia'
        '# se corre el motor de Linux sobre el mismo repositorio, tambien scripts/ y el Makefile.'
        ''
        '# --- Cuenta de admin del juego ---'
        (ConvertTo-ZsEnvLine 'ADMINUSERNAME' $AdminUsername)
        (ConvertTo-ZsEnvLine 'ADMINPASSWORD' $AdminPassword -Quote)
        ''
        '# --- RCON (puerto 27015, solo local) ---'
        (ConvertTo-ZsEnvLine 'RCONPASSWORD' $RconPassword -Quote)
        (ConvertTo-ZsEnvLine 'RCON_PORT' ([string]$RconPort))
        ''
        '# --- Acceso de los jugadores ---'
        (ConvertTo-ZsEnvLine 'SERVER_PASSWORD' $ServerPassword -Quote)
        (ConvertTo-ZsEnvLine 'PUBLIC_NAME' $PublicName -Quote)
        (ConvertTo-ZsEnvLine 'MAX_PLAYERS' ([string]$MaxPlayers))
        ''
        '# --- Puertos del juego ---'
        (ConvertTo-ZsEnvLine 'GAME_PORT' ([string]$GamePort))
        (ConvertTo-ZsEnvLine 'GAME_UDP_PORT' ([string]$GameUdpPort))
        ''
        '# --- Memoria de la JVM ---'
        (ConvertTo-ZsEnvLine 'MIN_MEMORY' $MinMemory)
        (ConvertTo-ZsEnvLine 'MAX_MEMORY' $MaxMemory)
        ''
        '# --- Mods ---'
        (ConvertTo-ZsEnvLine 'MOD_ID_PREFIX' '')
        ''
        '# --- Red: UPnP le pide al router que abra los puertos solo ---'
        (ConvertTo-ZsEnvLine 'UPNP' $upnpValue)
        ''
        '# --- Puente de Discord (opcional) ---'
        (ConvertTo-ZsEnvLine 'DISCORD_ENABLE' 'false')
        (ConvertTo-ZsEnvLine 'DISCORD_TOKEN' '')
        (ConvertTo-ZsEnvLine 'DISCORD_CHAT_CHANNEL' '')
        (ConvertTo-ZsEnvLine 'DISCORD_LOG_CHANNEL' '')
        (ConvertTo-ZsEnvLine 'DISCORD_COMMAND_CHANNEL' '')
        ''
        '# --- Backups ---'
        (ConvertTo-ZsEnvLine 'RCLONE_REMOTE' 'oci')
        (ConvertTo-ZsEnvLine 'BACKUP_BUCKET' '')
        (ConvertTo-ZsEnvLine 'BACKUP_KEEP_LOCAL_DAYS' '3')
        ''
        '# --- Apagado por inactividad (todavia sin usar) ---'
        (ConvertTo-ZsEnvLine 'IDLE_MINUTES' '30')
        ''
        '# --- CLI ---'
        (ConvertTo-ZsEnvLine 'ZS_LANG' $Language)
        ''
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrEmpty($directory) -and -not (Test-Path -LiteralPath $directory)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }

    # Sin BOM y con saltos \n: el mismo archivo lo puede leer bash desde WSL sin sorpresas.
    $text = ($lines -join "`n")
    [System.IO.File]::WriteAllBytes($Path, (New-Object System.Text.UTF8Encoding($false)).GetBytes($text))
}
