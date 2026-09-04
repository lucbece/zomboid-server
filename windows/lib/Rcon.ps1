# Cliente de Source RCON sobre TCP. Es el equivalente de scripts/rcon.sh, que envuelve mcrcon.
# No se ejecuta: se hace dot-source.
#
# Formato de un paquete (todo entero es int32 little-endian):
#
#   [size][id][type][body...][0x00][0x00]
#
# size cuenta desde id inclusive, o sea 4 + 4 + len(body) + 2. Los tipos que se usan:
#
#   3  SERVERDATA_AUTH            pedido de autenticacion, el body es la contrasena
#   2  SERVERDATA_AUTH_RESPONSE   respuesta a la autenticacion; id -1 = contrasena incorrecta
#   2  SERVERDATA_EXECCOMMAND     pedido de ejecucion (mismo numero, distinto sentido)
#   0  SERVERDATA_RESPONSE_VALUE  salida del comando
#
# Quirk verificado en 42.20.4: el server responde un paquete "tarde" — la respuesta del comando
# N no sale hasta que llega el N+1, asi que un solo comando no devuelve nada. scripts/rcon.sh lo
# resuelve agregando un `players` de descarte al final; aca se hace lo mismo. Ver docs/mods.md.
#
# El cliente solo se conecta a 127.0.0.1: en el server nativo RCON escucha en todas las
# interfaces y la unica proteccion es que el firewall no tenga regla para 27015/tcp.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'I18n.ps1')

$script:ZsRconTypeResponse = 0
$script:ZsRconTypeCommand = 2
$script:ZsRconTypeAuth = 3
$script:ZsRconAuthFailedId = -1

function ConvertTo-ZsRconPacket {
    <#
        .SYNOPSIS
        Serializa un paquete de Source RCON.
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)]
        [int]$Id,

        [Parameter(Mandatory)]
        [int]$Type,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Body
    )

    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $stream = New-Object System.IO.MemoryStream
    try {
        # BinaryWriter siempre escribe little-endian, a diferencia de BitConverter, que depende
        # de la arquitectura.
        $writer = New-Object System.IO.BinaryWriter($stream)
        try {
            $writer.Write([int](4 + 4 + $bodyBytes.Length + 2))
            $writer.Write([int]$Id)
            $writer.Write([int]$Type)
            if ($bodyBytes.Length -gt 0) {
                $writer.Write($bodyBytes)
            }
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Flush()
        }
        finally {
            $writer.Dispose()
        }
        return $stream.ToArray()
    }
    finally {
        $stream.Dispose()
    }
}

function Read-ZsStreamByte {
    <#
        .SYNOPSIS
        Lee exactamente Count bytes del stream. Devuelve $null si el stream se termina antes.
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)]
        [System.IO.Stream]$Stream,

        [Parameter(Mandatory)]
        [int]$Count
    )

    $buffer = New-Object byte[] $Count
    $read = 0
    while ($read -lt $Count) {
        $chunk = $Stream.Read($buffer, $read, $Count - $read)
        if ($chunk -le 0) {
            return $null
        }
        $read += $chunk
    }
    return $buffer
}

function ConvertFrom-ZsRconPacket {
    <#
        .SYNOPSIS
        Lee un paquete de Source RCON del stream. Devuelve $null si no hay mas datos.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.IO.Stream]$Stream
    )

    $header = Read-ZsStreamByte -Stream $Stream -Count 4
    if ($null -eq $header) {
        return $null
    }

    $size = [System.BitConverter]::ToInt32(($header | ForEach-Object { $_ }), 0)
    if (-not [System.BitConverter]::IsLittleEndian) {
        [array]::Reverse($header)
        $size = [System.BitConverter]::ToInt32($header, 0)
    }
    if ($size -lt 10 -or $size -gt 65536) {
        throw (Get-ZsText 'rcon.bad_packet' $size)
    }

    $payload = Read-ZsStreamByte -Stream $Stream -Count $size
    if ($null -eq $payload) {
        return $null
    }

    $id = Convert-ZsInt32 -Bytes $payload -Offset 0
    $type = Convert-ZsInt32 -Bytes $payload -Offset 4
    # Los ultimos dos bytes son los terminadores nulos y no son parte del cuerpo.
    $bodyLength = $size - 10
    $body = ''
    if ($bodyLength -gt 0) {
        $body = [System.Text.Encoding]::UTF8.GetString($payload, 8, $bodyLength)
    }

    return [pscustomobject]@{
        Id   = $id
        Type = $type
        Body = $body
    }
}

function Convert-ZsInt32 {
    <#
        .SYNOPSIS
        Lee un int32 little-endian de un arreglo de bytes. Usa BitConverter y no aritmetica de
        bits: un id negativo (auth failure = -1) tiene el bit alto prendido, y castear ese
        patron de bits a [int] con una conversion "checked" (la que hace PowerShell) tira
        OverflowException en vez de reinterpretar los mismos bytes.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [byte[]]$Bytes,

        [Parameter(Mandatory)]
        [int]$Offset
    )

    if ([System.BitConverter]::IsLittleEndian) {
        return [System.BitConverter]::ToInt32($Bytes, $Offset)
    }
    $reversed = $Bytes[$Offset..($Offset + 3)]
    [array]::Reverse($reversed)
    return [System.BitConverter]::ToInt32($reversed, 0)
}

function Invoke-ZsRcon {
    <#
        .SYNOPSIS
        Ejecuta un comando por RCON contra el server local y devuelve su salida.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
        Justification = 'Source RCON manda la contrasena en claro dentro del paquete: un SecureString habria que desarmarlo igual.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Command,

        [Parameter(Mandatory)]
        [string]$Password,

        [Parameter()]
        [string]$Address = '127.0.0.1',

        [Parameter()]
        [int]$Port = 27015,

        [Parameter()]
        [int]$ConnectTimeoutMs = 5000,

        [Parameter()]
        [int]$ReadTimeoutMs = 10000
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connect = $client.BeginConnect($Address, $Port, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne($ConnectTimeoutMs)) {
            throw (Get-ZsText 'rcon.connect_failed' $Address $Port)
        }
        $client.EndConnect($connect)

        $stream = $client.GetStream()
        $stream.ReadTimeout = $ReadTimeoutMs
        $stream.WriteTimeout = $ReadTimeoutMs

        $authId = 1
        $commandId = 2
        $flushId = 3

        $authPacket = ConvertTo-ZsRconPacket -Id $authId -Type $script:ZsRconTypeAuth -Body $Password
        $stream.Write($authPacket, 0, $authPacket.Length)
        $stream.Flush()

        # Algunos servidores mandan un RESPONSE_VALUE vacio antes del AUTH_RESPONSE.
        while ($true) {
            $packet = ConvertFrom-ZsRconPacket -Stream $stream
            if ($null -eq $packet) {
                throw (Get-ZsText 'rcon.auth_no_reply')
            }
            if ($packet.Type -eq $script:ZsRconTypeCommand) {
                if ($packet.Id -eq $script:ZsRconAuthFailedId) {
                    throw (Get-ZsText 'rcon.auth_failed')
                }
                break
            }
        }

        $commandPacket = ConvertTo-ZsRconPacket -Id $commandId -Type $script:ZsRconTypeCommand -Body $Command
        $stream.Write($commandPacket, 0, $commandPacket.Length)
        # El paquete de descarte: sin el, la respuesta del comando anterior no llega nunca. Su
        # propia respuesta es la que se pierde, igual que con mcrcon.
        $flushPacket = ConvertTo-ZsRconPacket -Id $flushId -Type $script:ZsRconTypeCommand -Body 'players'
        $stream.Write($flushPacket, 0, $flushPacket.Length)
        $stream.Flush()

        $answer = $null
        $fallback = $null
        try {
            while ($true) {
                $packet = ConvertFrom-ZsRconPacket -Stream $stream
                if ($null -eq $packet) {
                    break
                }
                if ($packet.Body.Length -eq 0) {
                    continue
                }
                if ($packet.Id -eq $commandId) {
                    $answer = $packet.Body
                    break
                }
                if ($null -eq $fallback) {
                    $fallback = $packet.Body
                }
            }
        }
        catch [System.IO.IOException] {
            # Vencio el tiempo de lectura: se devuelve lo que haya llegado.
            Write-Verbose "rcon: se agoto la espera de la respuesta"
        }

        if ($null -ne $answer) {
            return $answer
        }
        if ($null -ne $fallback) {
            return $fallback
        }
        return ''
    }
    finally {
        $client.Close()
    }
}

function Invoke-ZsRconFromEnv {
    <#
        .SYNOPSIS
        Igual que Invoke-ZsRcon, pero saca la contrasena y el puerto del .env ya leido.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Command,

        [Parameter(Mandatory)]
        [System.Collections.Specialized.OrderedDictionary]$EnvValues,

        [Parameter()]
        [int]$ReadTimeoutMs = 10000
    )

    if (-not $EnvValues.Contains('RCONPASSWORD') -or [string]::IsNullOrEmpty([string]$EnvValues['RCONPASSWORD'])) {
        throw (Get-ZsText 'rcon.no_password')
    }

    $port = 27015
    if ($EnvValues.Contains('RCON_PORT') -and -not [string]::IsNullOrEmpty([string]$EnvValues['RCON_PORT'])) {
        $port = [int]$EnvValues['RCON_PORT']
    }

    return (Invoke-ZsRcon -Command $Command -Password ([string]$EnvValues['RCONPASSWORD']) -Port $port -ReadTimeoutMs $ReadTimeoutMs)
}
