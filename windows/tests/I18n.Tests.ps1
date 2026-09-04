Set-StrictMode -Version Latest

BeforeAll {
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $script:LibDir = Join-Path $script:WindowsDir 'lib'
    . (Join-Path $script:LibDir 'I18n.ps1')
}

Describe 'I18n: es and en catalogs' {
    It 'define exactly the same set of keys' {
        $en = Get-ZsCatalogKey -Language 'en'
        $es = Get-ZsCatalogKey -Language 'es'
        $diff = Compare-Object -ReferenceObject $en -DifferenceObject $es
        $diff | Should -BeNullOrEmpty
    }

    It 'have at least one key' {
        (Get-ZsCatalogKey -Language 'en').Count | Should -BeGreaterThan 0
    }

    It 'every key used with Get-ZsText in windows/**.ps1 exists in the English catalog' {
        $en = Get-ZsCatalogKey -Language 'en'
        $files = Get-ChildItem -Path $script:WindowsDir -Filter '*.ps1' -Recurse |
            Where-Object { $_.FullName -notmatch [regex]::Escape((Join-Path 'windows' 'tests')) }
        $used = New-Object System.Collections.Generic.HashSet[string]
        foreach ($file in $files) {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            foreach ($match in [regex]::Matches($text, "Get-ZsText\s+'([a-zA-Z0-9_.]+)'")) {
                [void]$used.Add($match.Groups[1].Value)
            }
        }
        $missing = $used | Where-Object { $en -notcontains $_ }
        $missing | Should -BeNullOrEmpty
    }

    It 'resolves ZS_LANG from the environment before anything else' {
        $previous = $env:ZS_LANG
        try {
            $env:ZS_LANG = 'es'
            Get-ZsLanguage | Should -Be 'es'
        }
        finally {
            $env:ZS_LANG = $previous
        }
    }

    It 'falls back to en for an unknown language' {
        $previous = $env:ZS_LANG
        try {
            $env:ZS_LANG = 'fr'
            Get-ZsLanguage | Should -Be 'en'
        }
        finally {
            $env:ZS_LANG = $previous
        }
    }

    It 'reads ZS_LANG from a given .env file when the environment variable is unset' {
        $previous = $env:ZS_LANG
        $temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("zs-lang-" + [guid]::NewGuid())
        try {
            $env:ZS_LANG = $null
            Set-Content -LiteralPath $temporary -Value "ZS_LANG=es`n"
            Get-ZsLanguage -EnvFile $temporary | Should -Be 'es'
        }
        finally {
            $env:ZS_LANG = $previous
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}
