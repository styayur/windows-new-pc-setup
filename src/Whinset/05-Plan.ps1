function New-WhinsetRecovery {
    param([string]$Class = 'manual', [string]$Instructions = 'Review the recorded change and reverse it manually after verifying the exact target.')
    return [pscustomobject][ordered]@{ Class = $Class; AutomaticRollback = $false; Instructions = $Instructions }
}

function New-WhinsetConfigOperation {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$Privilege,
        [string[]]$DependsOn = @(),
        [Parameter(Mandatory)][string]$SortKey,
        [string]$PackageKey = '',
        [string]$PackageId = '',
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)]$Recovery
    )
    return [pscustomobject][ordered]@{
        Id=$Id; Kind=$Kind; Name=$Name; Description=$Description; Privilege=$Privilege
        DependsOn=$DependsOn; Priority=300; SortKey=$SortKey; Action='configure'; InventoryStatus='Unknown'
        PackageKey=$PackageKey; PackageId=$PackageId; Source='winget'; Architecture='auto'; Scope=$Scope
        Version=$null; VersionPolicy='latest'; ExpectedState='configured'; Reboot='never'; Recovery=$Recovery
    }
}

function New-WhinsetPlan {
    param(
        [Parameter(Mandatory)][string]$CatalogPath,
        [string]$Profile = 'Developer',
        [string[]]$Package = @(),
        [string[]]$Exclude = @(),
        [string[]]$Group = @(),
        [switch]$IncludePersonal,
        [switch]$SkipStoreApps,
        [ValidateSet('Auto','WindowsBase','Development')][string]$Stage = 'Auto',
        [switch]$ConfigureEnvironment,
        [switch]$SkipCondaInit,
        [switch]$EnableWsl,
        [switch]$EnableDocker,
        [switch]$DockerSmokeTest,
        [switch]$ApplicationsOnly,
        [ValidateRange(1,5)][int]$MaxAttempts = 2,
        [ValidateRange(30,14400)][int]$InstallTimeoutSeconds = 3600,
        [switch]$Offline,
        [AllowNull()]$Environment = $null
    )
    if ($ApplicationsOnly -and ($ConfigureEnvironment -or $EnableWsl -or $EnableDocker -or $DockerSmokeTest)) { throw 'ApplicationsOnly cannot be combined with system or environment configuration.' }
    if ($DockerSmokeTest -and -not $EnableDocker) { throw 'DockerSmokeTest requires EnableDocker.' }
    if ($EnableDocker) { $EnableWsl = $true }
    $catalog = Read-WhinsetCatalog -Path $CatalogPath
    $selection = Resolve-WhinsetSelection -Catalog $catalog -Profile $Profile -Package $Package -Exclude $Exclude -Group $Group -IncludePersonal:$IncludePersonal -SkipStoreApps:$SkipStoreApps
    if ($null -eq $Environment) { $Environment = Get-WhinsetEnvironmentSnapshot }
    $selectedPackages = @($selection.Packages)
    if ($Stage -ne 'Auto') { $selectedPackages = @($selectedPackages | Where-Object { $_.Stage -eq $Stage }) }
    $selectedKeys = @{}
    foreach ($item in $selectedPackages) { $selectedKeys[$item.Key.ToLowerInvariant()] = $true }
    foreach ($item in $selectedPackages) {
        foreach ($dependency in $item.Dependencies) {
            if (-not $selectedKeys.ContainsKey($dependency.ToLowerInvariant())) { throw "Stage '$Stage' excludes dependency '$dependency' required by '$($item.Key)'. Use Stage Auto or include the dependency's stage." }
        }
        if ($item.ExpectedState -ne 'installed') { throw "Package '$($item.Key)' requests ExpectedState '$($item.ExpectedState)', which this release candidate does not execute." }
        if ($item.Architecture -notin @('auto','neutral') -and $item.Architecture -ne $Environment.Architecture) { throw "Package '$($item.Key)' requires $($item.Architecture) but the host architecture is $($Environment.Architecture)." }
    }

    $inventory = @{}
    $warnings = New-Object System.Collections.Generic.List[string]
    foreach ($item in $selectedPackages) {
        if ($Offline -or -not $Environment.WingetAvailable) {
            $inventory[$item.Key] = [pscustomobject][ordered]@{ Installed = $null; VersionVerified = $null; Error = ''; Status = 'Unknown' }
            continue
        }
        $probe = Test-WhinsetPackageInstalled -Package $item
        $status = 'Missing'
        if ($probe.Installed -and ($item.VersionPolicy -ne 'pinned' -or $probe.VersionVerified)) { $status = 'Installed' }
        elseif ($probe.Installed -and $item.VersionPolicy -eq 'pinned') { $status = 'VersionConflict' }
        elseif ($probe.Error) { $status = 'Unknown'; [void]$warnings.Add("Inventory for $($item.Key) is unavailable: $($probe.Error)") }
        $inventory[$item.Key] = [pscustomobject][ordered]@{ Installed = $probe.Installed; VersionVerified = $probe.VersionVerified; Error = $probe.Error; Status = $status }
    }

    $operations = @()
    foreach ($item in $selectedPackages) {
        $inventoryStatus = [string]$inventory[$item.Key].Status
        $action = 'install'
        if ($inventoryStatus -eq 'Installed') { $action = 'none' }
        if ($inventoryStatus -eq 'VersionConflict') { $action = 'fail-conflict' }
        $priority = if ($item.Stage -eq 'WindowsBase') { 100 } else { 200 }
        $dependencies = @($item.Dependencies | ForEach-Object { "package:$_" })
        $operations += [pscustomobject][ordered]@{
            Id = "package:$($item.Key)"
            Kind = 'package'
            Name = $item.Name
            Description = "$($item.Vendor) · $($item.Source):$($item.Id)"
            Privilege = [string]$item.Privilege
            DependsOn = $dependencies
            Priority = $priority
            SortKey = $item.Key
            Action = $action
            InventoryStatus = $inventoryStatus
            PackageKey = $item.Key
            PackageId = $item.Id
            Source = $item.Source
            Architecture = $item.Architecture
            Scope = $item.Scope
            Version = $item.Version
            VersionPolicy = $item.VersionPolicy
            ExpectedState = $item.ExpectedState
            Reboot = $item.Reboot
            Recovery = $item.Recovery
        }
    }

    if (-not $ApplicationsOnly -and ($EnableWsl -or $EnableDocker)) {
        $operations += [pscustomobject][ordered]@{
            Id = 'system:wsl-features'; Kind = 'wsl-features'; Name = 'WSL prerequisites'; Description = 'Enable VirtualMachinePlatform and Windows Subsystem for Linux.'
            Privilege = 'elevated'; DependsOn = @(); Priority = 150; SortKey = 'wsl-features'; Action = 'configure'; InventoryStatus = 'Unknown'
            PackageKey = $null; PackageId = $null; Source = 'windows'; Architecture = 'auto'; Scope = 'machine'; Version = $null; VersionPolicy = 'latest'; ExpectedState = 'enabled'; Reboot = 'possible'
            Recovery = New-WhinsetRecovery -Class 'manual' -Instructions 'Disable the Windows optional features manually only if they are not needed by another workload.'
        }
        $operations += [pscustomobject][ordered]@{
            Id = 'system:wsl-runtime'; Kind = 'wsl-runtime'; Name = 'WSL 2 runtime'; Description = 'Update the machine WSL runtime.'
            Privilege = 'elevated'; DependsOn = @('system:wsl-features'); Priority = 250; SortKey = 'wsl-runtime'; Action = 'configure'; InventoryStatus = 'Unknown'
            PackageKey = $null; PackageId = $null; Source = 'windows'; Architecture = 'auto'; Scope = 'machine'; Version = $null; VersionPolicy = 'latest'; ExpectedState = 'enabled'; Reboot = 'possible'
            Recovery = New-WhinsetRecovery -Class 'manual' -Instructions 'Remove the Ubuntu distribution and disable WSL features manually if no longer required.'
        }
    }
    if (-not $ApplicationsOnly -and ($EnableWsl -or $EnableDocker)) {
        $operations += New-WhinsetConfigOperation -Id 'user:wsl-distribution' -Kind 'wsl-distribution' -Name 'Ubuntu for original user' -Description 'Install/register Ubuntu and configure WSL 2 in the original user context.' -Privilege 'user' -DependsOn @('system:wsl-runtime') -SortKey 'wsl-distribution' -Scope 'user' -Recovery (New-WhinsetRecovery -Class 'manual' -Instructions 'Review and unregister the user distribution manually only after backing up its data.')
    }
    if (-not $ApplicationsOnly -and $EnableDocker) {
        $operations += [pscustomobject][ordered]@{
            Id = 'system:docker'; Kind = 'docker'; Name = 'Docker Desktop'; Description = 'Install machine-scoped Docker Desktop from its exact WinGet ID.'
            Privilege = 'elevated'; DependsOn = @('system:wsl-runtime'); Priority = 260; SortKey = 'docker'; Action = 'configure'; InventoryStatus = 'Unknown'
            PackageKey = $null; PackageId = 'Docker.DockerDesktop'; Source = 'winget'; Architecture = 'auto'; Scope = 'machine'; Version = $null; VersionPolicy = 'latest'; ExpectedState = 'installed'; Reboot = 'possible'
            Recovery = New-WhinsetRecovery -Class 'external' -Instructions 'Use Windows Settings or Docker Desktop uninstall. WSL distributions and feature state remain separately managed.'
        }
    }

    if (-not $ApplicationsOnly -and $EnableDocker) {
        $operations += New-WhinsetConfigOperation -Id 'user:docker-verify' -Kind 'docker-user' -Name 'Docker original-user verification' -Description 'Verify the original user daemon and optionally run hello-world; first-run setup may require manual action.' -Privilege 'user' -DependsOn @('system:docker','user:wsl-distribution') -SortKey 'docker-user' -Scope 'user' -Recovery (New-WhinsetRecovery -Class 'external' -Instructions 'Review Docker Desktop user settings and data manually.')
    }
    if (-not $ApplicationsOnly -and $ConfigureEnvironment) {
        if ($selectedKeys.ContainsKey('git')) {
            $recovery = New-WhinsetRecovery -Class 'manual' -Instructions 'Run git lfs uninstall for the current user if Git LFS hooks are no longer wanted.'
            $operations += New-WhinsetConfigOperation -Id 'config:git-lfs' -Kind 'config-git-lfs' -Name 'Git LFS' -Description 'Install Git LFS hooks for the current user.' -Privilege 'user' -DependsOn @('package:Git') -SortKey 'git-lfs' -PackageKey 'Git' -PackageId 'Git.Git' -Scope 'user' -Recovery $recovery
        }
        if ($selectedKeys.ContainsKey('uv') -and $selectedKeys.ContainsKey('systempython')) {
            $recovery = New-WhinsetRecovery -Class 'manual' -Instructions 'Restore the previous UV_PYTHON_PREFERENCE user environment variable recorded in RecoveryData.'
            $operations += New-WhinsetConfigOperation -Id 'config:uv-python' -Kind 'config-uv' -Name 'uv Python policy' -Description 'Set UV_PYTHON_PREFERENCE=system for the current user.' -Privilege 'user' -DependsOn @('package:uv','package:SystemPython') -SortKey 'uv-python' -PackageKey 'uv' -PackageId 'astral-sh.uv' -Scope 'user' -Recovery $recovery
        }
        if ($selectedKeys.ContainsKey('anaconda')) {
            $instructions = 'Review the PowerShell profile change and conda auto_activate_base setting; reverse them manually if unwanted.'
            if ($SkipCondaInit) { $instructions = 'Only conda auto_activate_base is changed because SkipCondaInit was supplied.' }
            $recovery = New-WhinsetRecovery -Class 'manual' -Instructions $instructions
            $operations += New-WhinsetConfigOperation -Id 'config:conda' -Kind 'config-conda' -Name 'Conda user policy' -Description 'Optionally initialize PowerShell and disable automatic base activation.' -Privilege 'user' -DependsOn @('package:Anaconda') -SortKey 'conda' -PackageKey 'Anaconda' -PackageId 'Anaconda.Anaconda3' -Scope 'user' -Recovery $recovery
        }
        if ($selectedKeys.ContainsKey('go')) {
            $recovery = New-WhinsetRecovery -Class 'manual' -Instructions 'Inspect go env -w values and restore any previous GOPATH manually.'
            $operations += New-WhinsetConfigOperation -Id 'config:go' -Kind 'config-go' -Name 'Go user environment' -Description 'Set GOPATH with go env -w for the current user.' -Privilege 'user' -DependsOn @('package:Go') -SortKey 'go' -PackageKey 'Go' -PackageId 'GoLang.Go' -Scope 'user' -Recovery $recovery
        }
        if ($selectedKeys.ContainsKey('rustup')) {
            $recovery = New-WhinsetRecovery -Class 'manual' -Instructions 'Remove ~/.cargo/bin from the user PATH and uninstall toolchains manually if unwanted.'
            $operations += New-WhinsetConfigOperation -Id 'config:rust' -Kind 'config-rust' -Name 'Rust user environment' -Description 'Ensure ~/.cargo/bin is on the current user PATH and install the stable toolchain if needed.' -Privilege 'user' -DependsOn @('package:Rustup') -SortKey 'rust' -PackageKey 'Rustup' -PackageId 'Rustlang.Rustup' -Scope 'user' -Recovery $recovery
        }
        if ($selectedKeys.ContainsKey('openjdk21')) {
            $recovery = New-WhinsetRecovery -Class 'manual' -Instructions 'Restore the previous machine JAVA_HOME and PATH values recorded in RecoveryData.'
            $operations += New-WhinsetConfigOperation -Id 'config:java-home' -Kind 'config-java-home' -Name 'JAVA_HOME' -Description 'Set the machine JAVA_HOME and PATH entry for Microsoft OpenJDK 21.' -Privilege 'elevated' -DependsOn @('package:OpenJDK21') -SortKey 'java-home' -PackageKey 'OpenJDK21' -PackageId 'Microsoft.OpenJDK.21' -Scope 'machine' -Recovery $recovery
        }
    }

    if ($operations.Count -eq 0) { throw 'The selected request produced no operations.' }
    $ordered = Get-WhinsetTopologicalOrder -Nodes $operations -GraphName 'Whinset plan'
    foreach ($operation in $ordered) {
        if ($operation.Privilege -notin @('user','elevated')) { throw "Unsupported privilege '$($operation.Privilege)' for operation '$($operation.Id)'." }
    }

    $builtInCatalog = [IO.Path]::GetFullPath((Join-Path (Get-WhinsetRepositoryRoot) 'config\packages.json'))
    $isBuiltIn = ([IO.Path]::GetFullPath($catalog.Path) -ieq $builtInCatalog)
    $catalogHash = Get-WhinsetHashFile -Path $catalog.Path
    $request = [ordered]@{
        Profile = $selection.Profile
        Groups = @($selection.Groups | Sort-Object)
        Packages = @($selectedPackages.Key | Sort-Object)
        Exclude = @($Exclude | Sort-Object)
        IncludePersonal = [bool]$IncludePersonal
        SkipStoreApps = [bool]$SkipStoreApps
        Stage = $Stage
        ConfigureEnvironment = [bool]$ConfigureEnvironment
        SkipCondaInit = [bool]$SkipCondaInit
        EnableWsl = [bool]$EnableWsl
        EnableDocker = [bool]$EnableDocker
        DockerSmokeTest = [bool]$DockerSmokeTest
        ApplicationsOnly = [bool]$ApplicationsOnly
    }
    $identity = [ordered]@{
        SchemaVersion = 2
        WhinsetVersion = $script:WhinsetVersion
        Catalog = [ordered]@{ Version = $catalog.CatalogVersion; Sha256 = $catalogHash }
        Request = $request
        Execution = [ordered]@{ MaxAttempts = $MaxAttempts; InstallTimeoutSeconds = $InstallTimeoutSeconds }
        Environment = [ordered]@{ ComputerName = $Environment.ComputerName; UserSid = $Environment.UserSid; Architecture = $Environment.Architecture; BuildNumber = $Environment.BuildNumber; ProductType = $Environment.ProductType; PowerShellVersion = $Environment.PowerShellVersion }
        Packages = @($selectedPackages | Sort-Object Key | ForEach-Object { [ordered]@{ Key=$_.Key; Id=$_.Id; Source=$_.Source; Architecture=$_.Architecture; Scope=$_.Scope; Version=$_.Version; VersionPolicy=$_.VersionPolicy; Privilege=$_.Privilege; Stage=$_.Stage; Dependencies=@($_.Dependencies | Sort-Object) } })
        Operations = @($ordered | Sort-Object Id | ForEach-Object { [ordered]@{ Id=$_.Id; Kind=$_.Kind; Privilege=$_.Privilege; DependsOn=@($_.DependsOn | Sort-Object); PackageKey=$_.PackageKey; PackageId=$_.PackageId; Source=$_.Source; Scope=$_.Scope; Version=$_.Version } })
    }
    $planHash = Get-WhinsetHashText -Text (Get-WhinsetCanonicalJson -Value $identity)
    $runId = $planHash.Substring(0,12)
    $missing = @($ordered | Where-Object { $_.Action -eq 'install' }).Count
    $installed = @($ordered | Where-Object { $_.InventoryStatus -eq 'Installed' }).Count
    $unknown = @($ordered | Where-Object { $_.InventoryStatus -eq 'Unknown' -and $_.Kind -eq 'package' }).Count
    $actionable = @($ordered | Where-Object { $_.Action -ne 'none' })
    $user = @($ordered | Where-Object { $_.Privilege -eq 'user' })
    $elevated = @($actionable | Where-Object { $_.Privilege -eq 'elevated' })
    $requiresElevation = $elevated.Count -gt 0
    $uacPrompts = 0
    if ($requiresElevation -and -not $Environment.IsAdministrator) { $uacPrompts = 1 }
    $blockers = @($Environment.Blockers)
    if (-not $isBuiltIn) { $blockers += 'Custom catalogs are plan-only in this release candidate; use the built-in catalog for apply or the legacy entrypoint for a reviewed custom catalog.' }
    $rebootPossible = (@($actionable | Where-Object { $_.Reboot -ne 'never' }).Count -gt 0)
    return [pscustomobject][ordered]@{
        SchemaVersion = 2
        WhinsetVersion = $script:WhinsetVersion
        PlanHash = $planHash
        RunId = $runId
        CatalogVersion = $catalog.CatalogVersion
        Catalog = [ordered]@{ Path = $catalog.Path; Sha256 = $catalogHash; BuiltIn = $isBuiltIn }
        Request = $request
        Execution = [ordered]@{ MaxAttempts = $MaxAttempts; InstallTimeoutSeconds = $InstallTimeoutSeconds }
        Environment = $Environment
        Selection = [ordered]@{ SelectedCount = $selectedPackages.Count; MissingCount = $missing; AlreadyInstalledCount = $installed; UnknownCount = $unknown; Reasons = $selection.SelectionReasons }
        Operations = @($ordered)
        Order = @($ordered.Id)
        Summary = [ordered]@{ OperationCount = $ordered.Count; ActionableOperationCount = $actionable.Count; UserOperationCount = $user.Count; ElevatedOperationCount = $elevated.Count; RequiresElevation = $requiresElevation; UacPromptsExpected = $uacPrompts; RebootPossible = $rebootPossible; PendingRebootNow = (@($Environment.PendingReboot).Count -gt 0) }
        InterruptionPoints = @(@('BeforeElevation') + @($(if ($rebootPossible) { 'PossibleRebootAfterOperations' })))
        RecoveryLimitations = @('Package installers can change PATH, services, registry keys and other machine state outside Whinset control.', 'Successful package installs remain after a failed run; use exact vendor-specific uninstall instructions.', 'Windows optional features and WSL/Docker first-run state may require manual reversal.', 'No operation is automatically rolled back.')
        Blockers = @($blockers)
        Warnings = @($Environment.Warnings + $warnings)
        Identity = $identity
    }
}

function Test-WhinsetPlanTrust {
    param([Parameter(Mandatory)]$Plan, [string]$TrustedCatalogPath = '')
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Plan -or [int]$Plan.SchemaVersion -ne 2) { [void]$errors.Add('Plan schema must be 2.') }
    if (-not $Plan.PSObject.Properties['Identity'] -or -not $Plan.PSObject.Properties['Operations']) { [void]$errors.Add('Plan is missing Identity or Operations.') }
    if ($errors.Count -eq 0) {
        $actualHash = Get-WhinsetHashText -Text (Get-WhinsetCanonicalJson -Value $Plan.Identity)
        if ($actualHash -ne [string]$Plan.PlanHash) { [void]$errors.Add('Plan hash does not match the serialized identity.') }
        if (-not $TrustedCatalogPath) { $TrustedCatalogPath = Join-Path (Get-WhinsetRepositoryRoot) 'config\packages.json' }
        $trustedHash = Get-WhinsetHashFile -Path $TrustedCatalogPath
        if ([string]$Plan.Identity.Catalog.Sha256 -ne $trustedHash) { [void]$errors.Add('Plan catalog hash does not match the trusted built-in catalog.') }
        $catalog = Read-WhinsetCatalog -Path $TrustedCatalogPath
        $byKey = @{}
        foreach ($item in $catalog.Packages) { $byKey[$item.Key.ToLowerInvariant()] = $item }
        $seen = @{}
        $allowedKinds = @('package','wsl-features','wsl-runtime','wsl-distribution','docker','docker-user','config-git-lfs','config-uv','config-conda','config-go','config-rust','config-java-home')
        foreach ($operation in @($Plan.Operations)) {
            if (-not $operation.Id -or $seen.ContainsKey([string]$operation.Id)) { [void]$errors.Add("Duplicate or empty operation ID: $($operation.Id)") }
            $seen[[string]$operation.Id] = $true
            if ([string]$operation.Kind -notin $allowedKinds) { [void]$errors.Add("Operation kind is not allowlisted: $($operation.Kind)") }
            if ([string]$operation.Privilege -notin @('user','elevated')) { [void]$errors.Add("Operation privilege is invalid: $($operation.Id)") }
            if ($operation.Kind -eq 'package') {
                $key = ([string]$operation.PackageKey).ToLowerInvariant()
                if (-not $byKey.ContainsKey($key)) { [void]$errors.Add("Unknown package operation: $($operation.PackageKey)") }
                else {
                    $trusted = $byKey[$key]
                    if ([string]$operation.PackageId -ne $trusted.Id -or [string]$operation.Source -ne $trusted.Source -or [string]$operation.Privilege -ne $trusted.Privilege) { [void]$errors.Add("Package operation metadata differs from the trusted catalog: $($operation.PackageKey)") }
                }
            } elseif ($operation.Kind -eq 'docker') {
                if ([string]$operation.PackageId -ne 'Docker.DockerDesktop' -or [string]$operation.Source -ne 'winget') { [void]$errors.Add('Docker operation metadata is not trusted.') }
            } elseif ($operation.Kind -notlike 'config-*' -and $operation.Kind -notlike 'wsl-*' -and $operation.Kind -ne 'docker-user') {
                [void]$errors.Add("Executable operation is not recognized: $($operation.Id)")
            }
        }
        try { [void](Get-WhinsetTopologicalOrder -Nodes @($Plan.Operations) -GraphName 'serialized plan') } catch { [void]$errors.Add($_.Exception.Message) }
    }
    return [pscustomobject][ordered]@{ Valid = ($errors.Count -eq 0); Errors = @($errors) }
}



function Get-WhinsetTrustedPlan {
    param([Parameter(Mandatory)][string]$PlanPath, [Parameter(Mandatory)][string]$ExpectedPlanHash)
    $stored = Read-WhinsetJsonFile -Path $PlanPath
    $trustedCatalog = Join-Path (Get-WhinsetRepositoryRoot) 'config\packages.json'
    if (-not $stored.PSObject.Properties['Identity'] -or -not $stored.PSObject.Properties['Request']) { throw 'Stored plan is missing trusted fields.' }
    $trustedHash = Get-WhinsetHashFile -Path $trustedCatalog
    if ([string]$stored.Identity.Catalog.Sha256 -ne $trustedHash) { throw 'Stored plan catalog hash does not match the installed catalog.' }
    $request = $stored.Request
    $execution = $stored.Execution
    if ($null -eq $execution) { $execution = [pscustomobject]@{ MaxAttempts=2; InstallTimeoutSeconds=3600 } }
    $rebuilt = New-WhinsetPlan -CatalogPath $trustedCatalog -Profile ([string]$request.Profile) -Package @($request.Packages) -Exclude @($request.Exclude) -Group @($request.Groups) -IncludePersonal:$request.IncludePersonal -SkipStoreApps:$request.SkipStoreApps -Stage ([string]$request.Stage) -ConfigureEnvironment:$request.ConfigureEnvironment -SkipCondaInit:$request.SkipCondaInit -EnableWsl:$request.EnableWsl -EnableDocker:$request.EnableDocker -DockerSmokeTest:$request.DockerSmokeTest -ApplicationsOnly:$request.ApplicationsOnly -MaxAttempts ([int]$execution.MaxAttempts) -InstallTimeoutSeconds ([int]$execution.InstallTimeoutSeconds) -Offline -Environment $stored.Environment
    if ([string]$rebuilt.PlanHash -ne $ExpectedPlanHash -or [string]$stored.PlanHash -ne $ExpectedPlanHash) { throw 'Plan hash verification failed after trusted reconstruction.' }
    $fields = @('Id','Kind','Privilege','DependsOn','PackageKey','PackageId','Source','Architecture','Scope','Version','VersionPolicy')
    $storedGraph = @($stored.Operations | Select-Object $fields)
    $trustedGraph = @($rebuilt.Operations | Select-Object $fields)
    if ((Get-WhinsetCanonicalJson $storedGraph) -cne (Get-WhinsetCanonicalJson $trustedGraph) -or (@($stored.Order) -join "`n") -cne (@($rebuilt.Order) -join "`n")) { throw 'Serialized operation graph differs from trusted reconstruction.' }
    return $rebuilt
}
