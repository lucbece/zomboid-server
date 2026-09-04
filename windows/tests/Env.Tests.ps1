Set-StrictMode -Version Latest

BeforeAll {
    $script:LibDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib'
    . (Join-Path $script:LibDir 'I18n.ps1')
    . (Join-Path $script:LibDir 'Env.ps1')
    Initialize-ZsI18n -Language 'en'
}

Describe 'Env: .env round trip' {
    BeforeEach {
        $script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("zs-env-" + [guid]::NewGuid())
        [void](New-Item -ItemType Directory -Path $script:TempDir -Force)
        $script:EnvPath = Join-Path $script:TempDir '.env'
    }

    AfterEach {
        Remove-Item -LiteralPath $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'writes and reads back every value unchanged, including a password with spaces' {
        Write-ZsEnvFile -Path $script:EnvPath -AdminPassword 'admin secret 1234' -RconPassword 'rcon-secret-5678' `
            -ServerPassword 'server-pass-9012' -PublicName 'My Zomboid Server' -MaxPlayers 12 `
            -MaxMemory '10g' -Language 'es' -Upnp $true

        $values = Read-ZsEnvFile -Path $script:EnvPath

        $values['ADMINPASSWORD'] | Should -Be 'admin secret 1234'
        $values['RCONPASSWORD'] | Should -Be 'rcon-secret-5678'
        $values['SERVER_PASSWORD'] | Should -Be 'server-pass-9012'
        $values['PUBLIC_NAME'] | Should -Be 'My Zomboid Server'
        $values['MAX_PLAYERS'] | Should -Be '12'
        $values['MAX_MEMORY'] | Should -Be '10g'
        $values['ZS_LANG'] | Should -Be 'es'
        $values['UPNP'] | Should -Be 'true'
        $values['RCON_PORT'] | Should -Be '27015'
        $values['IDLE_MINUTES'] | Should -Be '30'
    }

    It 'writes UPNP=false when Upnp is $false' {
        Write-ZsEnvFile -Path $script:EnvPath -AdminPassword 'a12345678' -RconPassword 'r12345678' `
            -ServerPassword 's12345678' -PublicName 'Server' -MaxPlayers 8 -MaxMemory '8g' `
            -Language 'en' -Upnp $false

        (Read-ZsEnvFile -Path $script:EnvPath)['UPNP'] | Should -Be 'false'
    }

    It 'writes the file without a BOM and with LF line endings' {
        Write-ZsEnvFile -Path $script:EnvPath -AdminPassword 'a12345678' -RconPassword 'r12345678' `
            -ServerPassword 's12345678' -PublicName 'Server' -MaxPlayers 8 -MaxMemory '8g' `
            -Language 'en' -Upnp $true

        $bytes = [System.IO.File]::ReadAllBytes($script:EnvPath)
        $bytes[0] | Should -Not -Be 0xEF
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        $text | Should -Not -Match "`r`n"
    }

    It 'parses a value quoted with double quotes and bash escapes' {
        $content = @'
FOO="a \"quoted\" \$value with \\ and spaces"
'@
        Set-Content -LiteralPath $script:EnvPath -NoNewline -Value $content
        $values = Read-ZsEnvFile -Path $script:EnvPath
        $values['FOO'] | Should -Be 'a "quoted" $value with \ and spaces'
    }

    It 'parses a value quoted with single quotes literally (no escapes)' {
        $content = @'
FOO='a \$literal \\ value'
'@
        Set-Content -LiteralPath $script:EnvPath -NoNewline -Value $content
        $values = Read-ZsEnvFile -Path $script:EnvPath
        $values['FOO'] | Should -Be 'a \$literal \\ value'
    }

    It 'cuts an unquoted value at the first " #" (inline comment)' {
        Set-Content -LiteralPath $script:EnvPath -NoNewline -Value "FOO=bar # a comment`nBAZ=bar#not-a-comment`n"
        $values = Read-ZsEnvFile -Path $script:EnvPath
        $values['FOO'] | Should -Be 'bar'
        $values['BAZ'] | Should -Be 'bar#not-a-comment'
    }

    It 'ignores blank lines and comment lines, and reads export FOO=bar' {
        Set-Content -LiteralPath $script:EnvPath -NoNewline -Value "# a comment`n`nexport FOO=bar`n"
        $values = Read-ZsEnvFile -Path $script:EnvPath
        $values['FOO'] | Should -Be 'bar'
        $values.Contains('# a comment') | Should -BeFalse
    }

    It 'skips the UTF-8 BOM when reading' {
        $bytes = [System.Text.Encoding]::UTF8.GetPreamble() + [System.Text.Encoding]::UTF8.GetBytes("FOO=bar`n")
        [System.IO.File]::WriteAllBytes($script:EnvPath, $bytes)
        (Read-ZsEnvFile -Path $script:EnvPath)['FOO'] | Should -Be 'bar'
    }
}

Describe 'Env: password and name validation' {
    It 'accepts a valid generated password' {
        Test-ZsPassword 'arena-tulipan-molino-4821' | Should -BeTrue
    }

    It 'rejects a password with a space' {
        Test-ZsPassword 'has a space' | Should -BeFalse
    }

    It 'rejects a password shorter than 8 characters' {
        Test-ZsPassword 'short1' | Should -BeFalse
    }

    It 'accepts a plain server name' {
        Test-ZsPublicName 'My Zomboid Server' | Should -BeTrue
    }

    It 'rejects a server name with a double quote' {
        Test-ZsPublicName 'bad "name"' | Should -BeFalse
    }
}
