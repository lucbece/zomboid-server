BeforeAll {
    $libDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib'
    . (Join-Path $libDir 'I18n.ps1')
    . (Join-Path $libDir 'Ui.ps1')
    . (Join-Path $libDir 'Env.ps1')
    . (Join-Path $libDir 'Rcon.ps1')
    . (Join-Path $libDir 'Backup.ps1')
}

Describe 'Backup: Compress-ZsDirectory' {
    It 'zips several directories under their own prefix and reads files that are open for writing' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("zs-backup-{0}" -f [guid]::NewGuid())
        $a = Join-Path $root 'Saves'
        $b = Join-Path $root 'db'
        [void](New-Item -ItemType Directory -Path (Join-Path $a 'sub') -Force)
        [void](New-Item -ItemType Directory -Path $b -Force)
        Set-Content -LiteralPath (Join-Path $a (Join-Path 'sub' 'world.bin')) -Value 'world'
        $dbPath = Join-Path $b 'players.db'
        # Abierto para escritura con share ReadWrite, como lo tiene SQLite mientras el server corre.
        $held = New-Object System.IO.FileStream($dbPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
        $bytes = [System.Text.Encoding]::ASCII.GetBytes('sqlite')
        $held.Write($bytes, 0, $bytes.Length); $held.Flush()
        $zip = Join-Path $root 'out.zip'
        try {
            Compress-ZsDirectory -Source @($a, $b) -Destination $zip
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
            try {
                $names = @($archive.Entries | ForEach-Object FullName)
                $names.Count | Should -Be 2
                $names | Should -Contain 'Saves/sub/world.bin'
                $names | Should -Contain 'db/players.db'
                ($archive.GetEntry('db/players.db')).Length | Should -Be 6
            }
            finally { $archive.Dispose() }
        }
        finally {
            $held.Dispose()
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Backup: Remove-ZsOldBackup' {
    It 'returns an empty array (not $null) when nothing is expired, and the expired paths otherwise' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("zs-prune-{0}" -f [guid]::NewGuid())
        $backupDir = Join-Path $root 'backups'
        [void](New-Item -ItemType Directory -Path $backupDir -Force)
        try {
            $none = @(Remove-ZsOldBackup -RepoRoot $root -KeepDays 3)
            $none.Count | Should -Be 0
            $old = Join-Path $backupDir 'old.zip'
            $new = Join-Path $backupDir 'new.zip'
            Set-Content -LiteralPath $old -Value 'x'
            Set-Content -LiteralPath $new -Value 'y'
            (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddDays(-10)
            $removed = @(Remove-ZsOldBackup -RepoRoot $root -KeepDays 3)
            $removed.Count | Should -Be 1
            Test-Path -LiteralPath $old | Should -BeFalse
            Test-Path -LiteralPath $new | Should -BeTrue
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
