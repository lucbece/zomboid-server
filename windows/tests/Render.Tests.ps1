# Render parity: windows\lib\Render.ps1 must produce byte-identical output to
# scripts/render-config.sh for the same config/ + .env inputs. Runs both engines against
# throwaway temp copies (never the real data/ or the real .env) and diffs the results.
#
# Requires bash and envsubst on the test runner (both engines' contract is only meaningful
# where the reference implementation can actually run, i.e. Linux CI).

Set-StrictMode -Version Latest

# A nivel de script, no dentro de BeforeAll: Describe -Skip se evalua en la fase de discovery
# de Pester, antes de que corra ningun BeforeAll.
$script:HaveBash = $null -ne (Get-Command -Name 'bash' -ErrorAction SilentlyContinue)
$script:HaveEnvsubst = $null -ne (Get-Command -Name 'envsubst' -ErrorAction SilentlyContinue)

BeforeAll {
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $script:RepoRoot = Split-Path -Parent $script:WindowsDir
    $script:LibDir = Join-Path $script:WindowsDir 'lib'

    . (Join-Path $script:LibDir 'I18n.ps1')
    . (Join-Path $script:LibDir 'Env.ps1')
    . (Join-Path $script:LibDir 'Mods.ps1')
    . (Join-Path $script:LibDir 'Render.ps1')
    Initialize-ZsI18n -Language 'en'

    function Get-ZsParityEnvText {
        param([string]$Upnp = 'false')
        return (@(
                'ADMINUSERNAME=admin'
                'ADMINPASSWORD=test-admin-pass-1'
                'RCONPASSWORD=test-rcon-pass-1'
                'RCON_PORT=27015'
                'SERVER_PASSWORD=test-server-pass-1'
                'PUBLIC_NAME="Parity Test Server"'
                'MAX_PLAYERS=10'
                'GAME_PORT=16261'
                'GAME_UDP_PORT=16262'
                'MIN_MEMORY=2048m'
                'MAX_MEMORY=8g'
                'MOD_ID_PREFIX='
                "UPNP=$Upnp"
                'DISCORD_ENABLE=false'
                'DISCORD_TOKEN='
                'DISCORD_CHAT_CHANNEL='
                'DISCORD_LOG_CHANNEL='
                'DISCORD_COMMAND_CHANNEL='
                'RCLONE_REMOTE=oci'
                'BACKUP_BUCKET='
                'BACKUP_KEEP_LOCAL_DAYS=3'
                'IDLE_MINUTES=30'
                'ZS_LANG=en'
            ) -join "`n") + "`n"
    }

    function New-ZsParityRoot {
        <#
            One throwaway copy of config/ and scripts/, with no mods.txt / SandboxVars.lua
            (each scenario sets those up itself) and no .env (each scenario writes its own).
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Helper de test, no un cmdlet interactivo: siempre arma el directorio temporal.')]
        param()
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("zs-parity-" + [guid]::NewGuid())
        [void](New-Item -ItemType Directory -Path $root -Force)
        Copy-Item -Path (Join-Path $script:RepoRoot 'config') -Destination (Join-Path $root 'config') -Recurse
        Copy-Item -Path (Join-Path $script:RepoRoot 'scripts') -Destination (Join-Path $root 'scripts') -Recurse
        Remove-Item -LiteralPath (Join-Path $root (Join-Path 'config' 'mods.txt')) -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $root (Join-Path 'config' 'servertest_SandboxVars.lua')) -Force -ErrorAction SilentlyContinue
        return $root
    }

    function New-ZsParityPair {
        <#
            Two identical roots (one for each engine), so each can write its own
            data\zomboid\Server\ without the other engine's run clobbering it.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Helper de test, no un cmdlet interactivo: siempre arma el par de directorios.')]
        param(
            [string]$Upnp = 'false',
            [string]$ModsText
        )
        $bashRoot = New-ZsParityRoot
        $psRoot = New-ZsParityRoot
        $envText = Get-ZsParityEnvText -Upnp $Upnp
        foreach ($root in @($bashRoot, $psRoot)) {
            Set-Content -LiteralPath (Join-Path $root '.env') -NoNewline -Value $envText
            if ($null -ne $ModsText) {
                Set-Content -LiteralPath (Join-Path $root (Join-Path 'config' 'mods.txt')) -NoNewline -Value $ModsText
            }
        }
        return [pscustomobject]@{ BashRoot = $bashRoot; PsRoot = $psRoot }
    }

    function Invoke-ZsBashRender {
        param(
            [Parameter(Mandatory)][string]$Root,
            [switch]$AllowVanilla
        )
        $scriptPath = Join-Path $Root (Join-Path 'scripts' 'render-config.sh')
        $previous = $env:ALLOW_VANILLA
        try {
            if ($AllowVanilla) { $env:ALLOW_VANILLA = '1' } else { $env:ALLOW_VANILLA = $null }
            $output = & bash $scriptPath 2>&1
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
        }
        finally {
            $env:ALLOW_VANILLA = $previous
        }
    }

    function Invoke-ZsPowerShellRender {
        param(
            [Parameter(Mandatory)][string]$Root,
            [switch]$AllowVanilla
        )
        try {
            $result = Invoke-ZsRender -RepoRoot $Root -AllowVanilla:$AllowVanilla -Quiet
            return [pscustomobject]@{ ExitCode = 0; Result = $result; Error = $null }
        }
        catch {
            return [pscustomobject]@{ ExitCode = 1; Result = $null; Error = $_.Exception.Message }
        }
    }

    function Compare-ZsRenderedServerDir {
        param([string]$BashRoot, [string]$PsRoot)
        $bashDir = Join-Path $BashRoot (Join-Path 'data' (Join-Path 'zomboid' 'Server'))
        $psDir = Join-Path $PsRoot (Join-Path 'data' (Join-Path 'zomboid' 'Server'))

        $bashFiles = Get-ChildItem -LiteralPath $bashDir -File | Sort-Object -Property Name
        $psFiles = Get-ChildItem -LiteralPath $psDir -File | Sort-Object -Property Name
        ($bashFiles | ForEach-Object Name) | Should -Be ($psFiles | ForEach-Object Name)

        foreach ($file in $bashFiles) {
            $a = [System.IO.File]::ReadAllBytes($file.FullName)
            $b = [System.IO.File]::ReadAllBytes((Join-Path $psDir $file.Name))
            Compare-Object -ReferenceObject $a -DifferenceObject $b |
                Should -BeNullOrEmpty -Because "$($file.Name) must be byte-identical between engines"
        }
    }

    function Remove-ZsParityPair {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Helper de test, no un cmdlet interactivo: siempre limpia los directorios temporales.')]
        param($Pair)
        Remove-Item -LiteralPath $Pair.BashRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $Pair.PsRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Render: parity with scripts/render-config.sh' -Skip:(-not ($script:HaveBash -and $script:HaveEnvsubst)) {
    It 'renders identical output with mods present (semicolon list, one Mod ID with a space)' {
        $mods = @(
            '3567084868  ModManager'
            '2799152995  78amgeneralM35A2; 78amgeneralM35A2extra'
            '3423660713  Jump Jump'
        ) -join "`n"
        $pair = New-ZsParityPair -ModsText $mods
        try {
            $bash = Invoke-ZsBashRender -Root $pair.BashRoot
            $bash.ExitCode | Should -Be 0 -Because $bash.Output
            $ps = Invoke-ZsPowerShellRender -Root $pair.PsRoot
            $ps.ExitCode | Should -Be 0 -Because $ps.Error
            Compare-ZsRenderedServerDir -BashRoot $pair.BashRoot -PsRoot $pair.PsRoot
        }
        finally {
            Remove-ZsParityPair $pair
        }
    }

    It 'renders identical output with no mods.txt at all (vanilla)' {
        $pair = New-ZsParityPair
        try {
            $bash = Invoke-ZsBashRender -Root $pair.BashRoot
            $bash.ExitCode | Should -Be 0 -Because $bash.Output
            $ps = Invoke-ZsPowerShellRender -Root $pair.PsRoot
            $ps.ExitCode | Should -Be 0 -Because $ps.Error
            Compare-ZsRenderedServerDir -BashRoot $pair.BashRoot -PsRoot $pair.PsRoot
        }
        finally {
            Remove-ZsParityPair $pair
        }
    }

    It 'renders identical output when config/servertest_SandboxVars.lua is missing (example fallback)' {
        $pair = New-ZsParityPair
        try {
            $bash = Invoke-ZsBashRender -Root $pair.BashRoot
            $bash.ExitCode | Should -Be 0 -Because $bash.Output
            $ps = Invoke-ZsPowerShellRender -Root $pair.PsRoot
            $ps.ExitCode | Should -Be 0 -Because $ps.Error

            $bashSandbox = Join-Path $pair.BashRoot (Join-Path 'data' (Join-Path 'zomboid' (Join-Path 'Server' 'servertest_SandboxVars.lua')))
            $example = Join-Path $pair.BashRoot (Join-Path 'config' 'servertest_SandboxVars.example.lua')
            (Get-Content -LiteralPath $bashSandbox -Raw) | Should -Be (Get-Content -LiteralPath $example -Raw)

            Compare-ZsRenderedServerDir -BashRoot $pair.BashRoot -PsRoot $pair.PsRoot
        }
        finally {
            Remove-ZsParityPair $pair
        }
    }

    It 'both engines refuse to render an empty mod list over an ini that had mods, unless ALLOW_VANILLA=1' {
        $pair = New-ZsParityPair -ModsText "111  SomeMod`n"
        try {
            $bash = Invoke-ZsBashRender -Root $pair.BashRoot
            $bash.ExitCode | Should -Be 0 -Because $bash.Output
            $ps = Invoke-ZsPowerShellRender -Root $pair.PsRoot
            $ps.ExitCode | Should -Be 0 -Because $ps.Error

            # both worlds now have Mods= set; remove mods.txt and render again without the brake
            Remove-Item -LiteralPath (Join-Path $pair.BashRoot (Join-Path 'config' 'mods.txt')) -Force
            Remove-Item -LiteralPath (Join-Path $pair.PsRoot (Join-Path 'config' 'mods.txt')) -Force

            $bashBlocked = Invoke-ZsBashRender -Root $pair.BashRoot
            $bashBlocked.ExitCode | Should -Not -Be 0
            $psBlocked = Invoke-ZsPowerShellRender -Root $pair.PsRoot
            $psBlocked.ExitCode | Should -Not -Be 0

            # with ALLOW_VANILLA=1 both succeed and end up with an empty Mods=
            $bashAllowed = Invoke-ZsBashRender -Root $pair.BashRoot -AllowVanilla
            $bashAllowed.ExitCode | Should -Be 0 -Because $bashAllowed.Output
            $psAllowed = Invoke-ZsPowerShellRender -Root $pair.PsRoot -AllowVanilla
            $psAllowed.ExitCode | Should -Be 0 -Because $psAllowed.Error

            Compare-ZsRenderedServerDir -BashRoot $pair.BashRoot -PsRoot $pair.PsRoot
        }
        finally {
            Remove-ZsParityPair $pair
        }
    }
}
