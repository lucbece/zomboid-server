# Presentacion compartida por setup.ps1 y zs.ps1. No se ejecuta: se hace dot-source.
#
# Es el equivalente de scripts/lib/ui.sh, con la misma forma:
#   OK / AVISO / FALTA + una linea que dice que hacer.
#
# Toda la salida a consola del motor de Windows pasa por aca, para que haya un solo lugar
# donde se decide como se escribe y se pueda revisar de una sola pasada.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'I18n.ps1')

# Write-Host es lo correcto para un CLI: la salida es para la persona que mira la pantalla, no
# un objeto para el pipeline. Write-Output ensuciaria el valor de retorno de cada funcion, asi
# que la unica supresion del analizador esta en Write-ZsLine, por donde pasa toda la salida.

function Write-ZsLine {
    <#
        .SYNOPSIS
        Escribe una linea en la consola.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'CLI interactivo: la salida es para la terminal, no para el pipeline.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [string]$Message = '',

        [Parameter()]
        [System.ConsoleColor]$Color
    )

    if ($PSBoundParameters.ContainsKey('Color')) {
        Write-Host $Message -ForegroundColor $Color
    }
    else {
        Write-Host $Message
    }
}

function Write-ZsTitle {
    <#
        .SYNOPSIS
        Titulo de seccion, con una linea de guiones del mismo largo.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message
    )

    Write-ZsLine ''
    Write-ZsLine $Message
    Write-ZsLine ('-' * $Message.Length)
}

function Write-ZsOk {
    <#
        .SYNOPSIS
        Linea de resultado correcto.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message
    )

    Write-ZsLine ("  {0} {1}" -f (Get-ZsText 'ui.label.ok'), $Message) -Color Green
}

function Write-ZsWarn {
    <#
        .SYNOPSIS
        Linea de aviso.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message
    )

    Write-ZsLine ("  {0} {1}" -f (Get-ZsText 'ui.label.warn'), $Message) -Color Yellow
}

function Write-ZsMiss {
    <#
        .SYNOPSIS
        Linea de falta algo.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message
    )

    Write-ZsLine ("  {0} {1}" -f (Get-ZsText 'ui.label.miss'), $Message) -Color Red
}

function Write-ZsHint {
    <#
        .SYNOPSIS
        Linea de accion, alineada debajo del OK/AVISO/FALTA (2 + 7 de etiqueta + 1 columnas).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message
    )

    Write-ZsLine ("          {0}" -f $Message)
}

function Write-ZsStep {
    <#
        .SYNOPSIS
        Paso en curso.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message
    )

    Write-ZsLine ("==> {0}" -f $Message) -Color Cyan
}

function Read-ZsAnswer {
    <#
        .SYNOPSIS
        Pregunta con valor por defecto. En modo no interactivo devuelve el default sin preguntar.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Question,

        [Parameter(Position = 1)]
        [AllowEmptyString()]
        [string]$Default = '',

        [Parameter()]
        [switch]$NonInteractive
    )

    if ($NonInteractive) {
        return $Default
    }

    if ([string]::IsNullOrEmpty($Default)) {
        $prompt = "  {0}" -f $Question
    }
    else {
        $prompt = "  {0} [{1}]" -f $Question, $Default
    }

    $answer = Read-Host -Prompt $prompt
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $Default
    }
    return $answer.Trim()
}

function Read-ZsConfirm {
    <#
        .SYNOPSIS
        Pregunta si/no. Devuelve $true si la respuesta es que si.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Question,

        [Parameter(Position = 1)]
        [bool]$Default = $true,

        [Parameter()]
        [switch]$NonInteractive
    )

    if ($NonInteractive) {
        return $Default
    }

    if ($Default) {
        $options = Get-ZsText 'ui.confirm.yes'
    }
    else {
        $options = Get-ZsText 'ui.confirm.no'
    }

    $answer = Read-Host -Prompt ("  {0} {1}" -f $Question, $options)
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $Default
    }
    return ($answer.Trim() -match '^(?i)[sy]')
}
