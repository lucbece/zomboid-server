Set-StrictMode -Version Latest

BeforeAll {
    $script:LibDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib'
    . (Join-Path $script:LibDir 'I18n.ps1')
    . (Join-Path $script:LibDir 'Rcon.ps1')
    Initialize-ZsI18n -Language 'en'
}

Describe 'Rcon: packet encoding (fixed byte vectors)' {
    It 'encodes a SERVERDATA_AUTH packet with id 1 and body "testpass"' {
        $bytes = ConvertTo-ZsRconPacket -Id 1 -Type 3 -Body 'testpass'
        $expected = [byte[]](
            0x12, 0x00, 0x00, 0x00, # size = 18 (4 + 4 + 8 + 2)
            0x01, 0x00, 0x00, 0x00, # id = 1
            0x03, 0x00, 0x00, 0x00, # type = 3 (SERVERDATA_AUTH)
            0x74, 0x65, 0x73, 0x74, 0x70, 0x61, 0x73, 0x73, # "testpass"
            0x00, 0x00
        )
        $bytes | Should -Be $expected
    }

    It 'encodes an empty-body packet as 10 bytes total plus the size field' {
        $bytes = ConvertTo-ZsRconPacket -Id 2 -Type 2 -Body ''
        $expected = [byte[]](
            0x0A, 0x00, 0x00, 0x00, # size = 10 (4 + 4 + 0 + 2)
            0x02, 0x00, 0x00, 0x00, # id = 2
            0x02, 0x00, 0x00, 0x00, # type = 2 (SERVERDATA_EXECCOMMAND)
            0x00, 0x00
        )
        $bytes | Should -Be $expected
    }

    It 'encodes a negative id (-1, auth failure) as its two''s complement bytes' {
        $bytes = ConvertTo-ZsRconPacket -Id -1 -Type 2 -Body ''
        $bytes[4..7] | Should -Be ([byte[]](0xFF, 0xFF, 0xFF, 0xFF))
    }
}

Describe 'Rcon: packet decoding (fixed byte vectors)' {
    It 'decodes the same "testpass" auth packet back to its id, type and body' {
        $bytes = [byte[]](
            0x12, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00,
            0x03, 0x00, 0x00, 0x00,
            0x74, 0x65, 0x73, 0x74, 0x70, 0x61, 0x73, 0x73,
            0x00, 0x00
        )
        $stream = New-Object System.IO.MemoryStream (, $bytes)
        try {
            $packet = ConvertFrom-ZsRconPacket -Stream $stream
            $packet.Id | Should -Be 1
            $packet.Type | Should -Be 3
            $packet.Body | Should -Be 'testpass'
        }
        finally {
            $stream.Dispose()
        }
    }

    It 'decodes an empty-body packet with an empty string, not null' {
        $bytes = [byte[]](0x0A, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00)
        $stream = New-Object System.IO.MemoryStream (, $bytes)
        try {
            $packet = ConvertFrom-ZsRconPacket -Stream $stream
            $packet.Body | Should -Be ''
        }
        finally {
            $stream.Dispose()
        }
    }

    It 'decodes a negative id (-1) correctly from its two''s complement bytes' {
        $bytes = [byte[]](0x0A, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00)
        $stream = New-Object System.IO.MemoryStream (, $bytes)
        try {
            $packet = ConvertFrom-ZsRconPacket -Stream $stream
            $packet.Id | Should -Be -1
        }
        finally {
            $stream.Dispose()
        }
    }

    It 'returns $null when the stream has no more data' {
        $stream = New-Object System.IO.MemoryStream (, [byte[]]@())
        try {
            ConvertFrom-ZsRconPacket -Stream $stream | Should -BeNullOrEmpty
        }
        finally {
            $stream.Dispose()
        }
    }

    It 'rejects a packet whose declared size is out of the protocol range' {
        $bytes = [byte[]](0x70, 0x11, 0x01, 0x00) # size = 70000, well above the 65536 cap
        $stream = New-Object System.IO.MemoryStream (, $bytes)
        try {
            { ConvertFrom-ZsRconPacket -Stream $stream } | Should -Throw
        }
        finally {
            $stream.Dispose()
        }
    }

    It 'round-trips encode then decode for an arbitrary command body' {
        $encoded = ConvertTo-ZsRconPacket -Id 42 -Type 2 -Body 'servermsg "hola a todos"'
        $stream = New-Object System.IO.MemoryStream (, $encoded)
        try {
            $packet = ConvertFrom-ZsRconPacket -Stream $stream
            $packet.Id | Should -Be 42
            $packet.Type | Should -Be 2
            $packet.Body | Should -Be 'servermsg "hola a todos"'
        }
        finally {
            $stream.Dispose()
        }
    }
}
