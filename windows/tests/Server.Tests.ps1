Set-StrictMode -Version Latest

BeforeAll {
    $script:LibDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib'
    . (Join-Path $script:LibDir 'I18n.ps1')
    . (Join-Path $script:LibDir 'Render.ps1')
    . (Join-Path $script:LibDir 'Mods.ps1')
    . (Join-Path $script:LibDir 'SteamCmd.ps1')
    . (Join-Path $script:LibDir 'Ui.ps1')
    . (Join-Path $script:LibDir 'Server.ps1')
    Initialize-ZsI18n -Language 'en'

    $script:BatPath = Join-Path $PSScriptRoot (Join-Path 'fixtures' 'StartServer64.bat')
}

Describe 'Server: Split-ZsCommandLine' {
    It 'splits plain whitespace-separated tokens' {
        Split-ZsCommandLine -Line 'a b  c' | Should -Be @('a', 'b', 'c')
    }

    It 'keeps a quoted segment with spaces as one token' {
        Split-ZsCommandLine -Line 'a "b c" d' | Should -Be @('a', 'b c', 'd')
    }
}

Describe 'Server: Get-ZsJavaCommand (StartServer64.bat fixture)' {
    BeforeAll {
        $script:Command = Get-ZsJavaCommand -BatPath $script:BatPath -MinMemory '4096m' -MaxMemory '6g' `
            -AdminUsername 'admin' -AdminPassword 'secret1234' -CacheDir 'C:\repo\data\zomboid' -Port 16261
    }

    It 'points the executable at jre64\bin\java.exe relative to the server directory' {
        $serverDir = Split-Path -Parent $script:BatPath
        $expected = Join-Path $serverDir (Join-Path 'jre64' (Join-Path 'bin' 'java.exe'))
        $script:Command.Executable | Should -Be $expected
    }

    It 'replaces -Xms and -Xmx with MIN_MEMORY and MAX_MEMORY' {
        $script:Command.Arguments | Should -Contain '-Xms4096m'
        $script:Command.Arguments | Should -Contain '-Xmx6g'
        $script:Command.Arguments | Should -Not -Contain '-Xms16g'
        $script:Command.Arguments | Should -Not -Contain '-Xmx16g'
    }

    It 'drops the %* placeholder' {
        $script:Command.Arguments | Should -Not -Contain '%*'
    }

    It 'preserves the JVM flags, the classpath and the main class untouched' {
        $script:Command.Arguments | Should -Contain '-Djava.awt.headless=true'
        $script:Command.Arguments | Should -Contain '-XX:+UseZGC'
        $script:Command.Arguments | Should -Contain '-Djava.library.path=natives/;natives/win64/;.'
        $script:Command.Arguments | Should -Contain '-cp'
        $script:Command.Arguments | Should -Contain 'java/istack-commons-runtime.jar;java/jassimp.jar;java/javacord-2.0.17-shaded.jar;java/javax.activation-api.jar;java/jaxb-api.jar;java/jaxb-runtime.jar;java/lwjgl.jar;java/lwjgl-natives-windows.jar;java/sqlite-jdbc.jar;java/uncommons-maths-1.2.3.jar;java/zombie.jar'
        $script:Command.Arguments | Should -Contain 'zombie.network.GameServer'
        $script:Command.Arguments | Should -Contain '-statistic'
        $script:Command.Arguments | Should -Contain '0'
    }

    It 'appends the server, admin and cachedir arguments' {
        $joined = $script:Command.Arguments -join ' '
        $joined | Should -Match '-servername servertest'
        $joined | Should -Match '-adminusername admin'
        $joined | Should -Match '-adminpassword secret1234'
        $joined | Should -Match '-cachedir=C:\\repo\\data\\zomboid'
        $joined | Should -Match '-port 16261'
    }

    It 'keeps the argument count consistent: 10 original tokens kept (drops the exe and %*) plus 9 appended' {
        # -servername x2, -adminusername x2, -adminpassword x2, -cachedir=... x1, -port x2 = 9
        $script:Command.Arguments.Count | Should -Be 19
    }
}

Describe 'Server: Get-ZsJavaCommand error handling' {
    It 'throws a clear error when the bat file does not exist' {
        { Get-ZsJavaCommand -BatPath 'C:\does\not\exist\StartServer64.bat' -MinMemory '2g' -MaxMemory '4g' `
                -AdminUsername 'a' -AdminPassword 'b' -CacheDir 'C:\x' -Port 16261 } | Should -Throw
    }

    It 'throws when the file has no java.exe invocation line' {
        $temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("zs-bat-" + [guid]::NewGuid() + '.bat')
        Set-Content -LiteralPath $temporary -Value "@echo off`r`necho no java here`r`n"
        try {
            { Get-ZsJavaCommand -BatPath $temporary -MinMemory '2g' -MaxMemory '4g' `
                    -AdminUsername 'a' -AdminPassword 'b' -CacheDir 'C:\x' -Port 16261 } | Should -Throw
        }
        finally {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Server: path helpers' {
    # Sin letra de unidad: en Linux, Join-Path con un root "C:\..." intenta resolver una unidad
    # PSDrive "C" que no existe y tira DriveNotFoundException. Estas funciones son puro armado
    # de rutas (no tocan el disco), asi que un root generico alcanza para probarlas en los dos
    # sistemas operativos.
    BeforeAll {
        $script:GenericRoot = Join-Path 'repo-root' 'zomboid-server'
    }

    It 'places the pid file at data\server.pid' {
        Get-ZsPidFilePath -RepoRoot $script:GenericRoot | Should -Be (Join-Path $script:GenericRoot (Join-Path 'data' 'server.pid'))
    }

    It 'places the log file at data\logs\server.log' {
        Get-ZsLogFilePath -RepoRoot $script:GenericRoot | Should -Be (Join-Path $script:GenericRoot (Join-Path 'data' (Join-Path 'logs' 'server.log')))
    }

    It 'uses data\zomboid as the cache directory' {
        Get-ZsCacheDir -RepoRoot $script:GenericRoot | Should -Be (Join-Path $script:GenericRoot (Join-Path 'data' 'zomboid'))
    }
}

Describe 'Server: launcher .cmd (ConvertTo-ZsBatchArgument / Write-ZsLauncherScript)' {
    It 'leaves plain arguments alone' {
        ConvertTo-ZsBatchArgument -Argument '-Xmx8g' | Should -Be '-Xmx8g'
    }
    It 'quotes arguments with spaces' {
        ConvertTo-ZsBatchArgument -Argument 'C:\Program Files\x' | Should -Be '"C:\Program Files\x"'
    }
    It 'doubles % and quotes cmd metacharacters (passwords may contain them)' {
        ConvertTo-ZsBatchArgument -Argument 'pa%ss&w(o)rd^1' | Should -Be '"pa%%ss&w(o)rd^1"'
    }
    It 'writes an ASCII batch with cd, the quoted executable and the log redirection' {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ("zs-launch-{0}.cmd" -f [guid]::NewGuid())
        try {
            Write-ZsLauncherScript -Path $path -WorkingDirectory 'C:\srv' -Executable 'C:\srv\jre64\bin\java.exe' `
                -Arguments @('-Xmx4g', '-adminpassword', 'a&b', '-cachedir=C:\my repo\data\zomboid') -LogPath 'C:\my repo\data\logs\server.log'
            $lines = [System.IO.File]::ReadAllLines($path)
            $lines[0] | Should -Be '@echo off'
            $lines[1] | Should -Be 'cd /D "C:\srv"'
            $lines[2] | Should -Be '"C:\srv\jre64\bin\java.exe" -Xmx4g -adminpassword "a&b" "-cachedir=C:\my repo\data\zomboid" >> "C:\my repo\data\logs\server.log" 2>&1'
            [System.IO.File]::ReadAllBytes($path)[0] | Should -Be 64  # '@': sin BOM
        }
        finally {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}
