Set-StrictMode -Version Latest

BeforeAll {
    $script:LibDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib'
    . (Join-Path $script:LibDir 'I18n.ps1')
    . (Join-Path $script:LibDir 'Mods.ps1')
    Initialize-ZsI18n -Language 'en'
}

Describe 'Mods: config/mods.txt grammar' {
    It 'parses a Mod ID that contains spaces' {
        $result = ConvertFrom-ZsModsText -Text "3567084868  Jump Jump`n"
        $result.WorkshopItems | Should -Be @('3567084868')
        $result.Mods | Should -Be @('Jump Jump')
    }

    It 'splits a semicolon-separated list of Mod IDs from a single Workshop item' {
        $result = ConvertFrom-ZsModsText -Text "2799152995  78amgeneralM35A2; 78amgeneralM35A2extra; 78amgeneralM49A2C`n"
        $result.WorkshopItems | Should -Be @('2799152995')
        $result.Mods | Should -Be @('78amgeneralM35A2', '78amgeneralM35A2extra', '78amgeneralM49A2C')
    }

    It 'lists a repeated Workshop id only once in WorkshopItems, keeping every Mod ID in file order' {
        $text = @"
111  ModOne
111  ModOneExtra
222  ModTwo
"@
        $result = ConvertFrom-ZsModsText -Text $text
        $result.WorkshopItems | Should -Be @('111', '222')
        $result.Mods | Should -Be @('ModOne', 'ModOneExtra', 'ModTwo')
    }

    It 'rejects a non-numeric workshop id' {
        { ConvertFrom-ZsModsText -Text "abc  SomeMod`n" } | Should -Throw
    }

    It 'rejects a line with a workshop id but no mod id' {
        { ConvertFrom-ZsModsText -Text "12345`n" } | Should -Throw
    }

    It 'ignores comments and blank lines' {
        $text = @"
# a full line comment

123  ModA  # trailing comment
"@
        $result = ConvertFrom-ZsModsText -Text $text
        $result.WorkshopItems | Should -Be @('123')
        $result.Mods | Should -Be @('ModA')
    }

    It 'returns empty lists for an empty file (vanilla)' {
        $result = ConvertFrom-ZsModsText -Text ''
        $result.Mods | Should -BeNullOrEmpty
        $result.WorkshopItems | Should -BeNullOrEmpty
    }

    It 'applies MOD_ID_PREFIX to every Mod ID' {
        $result = ConvertFrom-ZsModsText -Text "123  ModA;ModB`n" -ModIdPrefix '\'
        $result.Mods | Should -Be @('\ModA', '\ModB')
    }
}
