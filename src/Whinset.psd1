@{
    RootModule = 'Whinset.psm1'
    ModuleVersion = '2.0.0'
    GUID = '64b695de-31d1-4a74-9a31-56b0e4ceb97a'
    Author = 'styayur'
    CompanyName = 'Whinset'
    Copyright = '(c) 2026 styayur. MIT License.'
    Description = 'Deterministic Windows 11 setup planning and privilege orchestration.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop','Core')
    FunctionsToExport = @('Invoke-Whinset')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @('whinset')
    PrivateData = @{
        PSData = @{
            Prerelease = 'rc.2'
            Tags = @('Windows','Provisioning','WinGet','PowerShell','UAC')
            LicenseUri = 'https://github.com/styayur/whinset/blob/main/LICENSE'
            ProjectUri = 'https://github.com/styayur/whinset'
            ReleaseNotes = 'https://github.com/styayur/whinset/releases'
        }
    }
}
