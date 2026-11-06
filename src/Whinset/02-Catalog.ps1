function Read-WhinsetCatalog {
    param([Parameter(Mandatory)][string]$Path)
    $fullPath = Resolve-WhinsetAbsolutePath -Path $Path
    if (-not (Test-Path -LiteralPath $fullPath)) { throw "Catalog not found: $fullPath" }
    $config = Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $config -or $config -is [array]) { throw 'Catalog must be a JSON object.' }
    $allowedTop = @('SchemaVersion','CatalogVersion','Profiles','Groups','Packages')
    foreach ($name in $config.PSObject.Properties.Name) { if ($name -notin $allowedTop) { throw "Unknown catalog property: $name" } }
    if (-not $config.PSObject.Properties['SchemaVersion'] -or $config.SchemaVersion -is [bool] -or $config.SchemaVersion -is [string] -or [int]$config.SchemaVersion -ne 2) { throw 'Whinset catalogs require SchemaVersion 2.' }
    if ($config.CatalogVersion -isnot [string] -or [string]::IsNullOrWhiteSpace($config.CatalogVersion)) { throw 'CatalogVersion must be a nonempty string.' }
    if ($config.Groups -isnot [array] -or $config.Groups.Count -eq 0) { throw 'Groups must be a nonempty array.' }
    $groups = @($config.Groups | ForEach-Object { [string]$_ } | Select-Object -Unique)
    foreach ($group in $groups) { if ($group -notin $script:WhinsetAllowedGroups) { throw "Unknown group: $group" } }

    if ($null -eq $config.Profiles -or $config.Profiles -is [array]) { throw 'Profiles must be an object.' }
    $profiles = [ordered]@{}
    foreach ($property in $config.Profiles.PSObject.Properties) {
        $profileName = $property.Name.ToLowerInvariant()
        $profile = $property.Value
        if ($profile.Groups -isnot [array] -or $profile.Groups.Count -eq 0) { throw "Profile '$profileName' must contain a nonempty Groups array." }
        foreach ($group in $profile.Groups) { if ([string]$group -notin $groups) { throw "Profile '$profileName' refers to unknown group: $group" } }
        if (-not $profile.PSObject.Properties['Description'] -or [string]::IsNullOrWhiteSpace([string]$profile.Description)) { throw "Profile '$profileName' requires a Description." }
        $profiles[$profileName] = [pscustomobject][ordered]@{ Name = $profileName; Groups = @($profile.Groups); Description = [string]$profile.Description }
    }
    if ($profiles.Count -eq 0) { throw 'At least one profile is required.' }

    if ($config.Packages -isnot [array]) { throw 'Packages must be an array.' }
    $allowedFields = @('Key','Name','Vendor','Id','Source','Architecture','Scope','VersionPolicy','Stage','Category','Groups','Privilege','Dependencies','Conflicts','ExpectedState','Reboot','Recovery','Version')
    $requiredFields = @('Key','Name','Vendor','Id','Source','Architecture','Scope','VersionPolicy','Stage','Category','Groups','Privilege','Dependencies','Conflicts','ExpectedState','Reboot','Recovery')
    $keys = @{}
    $identities = @{}
    $packages = @()
    foreach ($item in $config.Packages) {
        if ($null -eq $item) { throw 'Package cannot be null.' }
        foreach ($field in $requiredFields) { if (-not $item.PSObject.Properties[$field]) { throw "Missing package field '$field' for package '$($item.Key)'." } }
        foreach ($field in $item.PSObject.Properties.Name) { if ($field -notin $allowedFields) { throw "Unknown package field '$field' for package '$($item.Key)'." } }
        if ($item.Key -isnot [string] -or $item.Key -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') { throw "Invalid package Key: $($item.Key)" }
        if ($item.Id -isnot [string] -or $item.Id -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') { throw "Invalid package Id for '$($item.Key)'." }
        if ($item.Name -isnot [string] -or [string]::IsNullOrWhiteSpace($item.Name)) { throw "Package '$($item.Key)' requires a nonempty Name." }
        if ($item.Vendor -isnot [string] -or [string]::IsNullOrWhiteSpace($item.Vendor)) { throw "Package '$($item.Key)' requires a nonempty Vendor." }
        if ($item.Source -isnot [string] -or $item.Source -notin @('winget','msstore')) { throw "Package '$($item.Key)' has an invalid Source." }
        if ($item.Architecture -isnot [string] -or $item.Architecture -notin @('auto','x64','arm64','neutral')) { throw "Package '$($item.Key)' has an invalid Architecture." }
        if ($item.Scope -isnot [string] -or $item.Scope -notin @('auto','user','machine')) { throw "Package '$($item.Key)' has an invalid Scope." }
        if ($item.VersionPolicy -isnot [string] -or $item.VersionPolicy -notin @('latest','pinned')) { throw "Package '$($item.Key)' has an invalid VersionPolicy." }
        if ($item.Stage -isnot [string] -or $item.Stage -notin @('WindowsBase','Development')) { throw "Package '$($item.Key)' has an invalid Stage." }
        if ($item.Category -isnot [string] -or $item.Category -notin $groups) { throw "Package '$($item.Key)' has an invalid Category." }
        if ($item.Groups -isnot [array] -or $item.Groups.Count -eq 0) { throw "Package '$($item.Key)' requires a nonempty Groups array." }
        foreach ($group in $item.Groups) { if ([string]$group -notin $groups) { throw "Package '$($item.Key)' has an invalid Group: $group" } }
        if ($item.Privilege -isnot [string] -or $item.Privilege -notin @('user','elevated')) { throw "Package '$($item.Key)' has an invalid Privilege." }
        if ($item.Privilege -eq 'user' -and $item.Scope -eq 'machine') { throw "Package '$($item.Key)' declares user privilege with machine scope." }
        if ($item.Dependencies -isnot [array]) { throw "Package '$($item.Key)' Dependencies must be an array." }
        if ($item.Conflicts -isnot [array]) { throw "Package '$($item.Key)' Conflicts must be an array." }
        foreach ($dependency in $item.Dependencies) { if ($dependency -isnot [string] -or [string]::IsNullOrWhiteSpace($dependency)) { throw "Package '$($item.Key)' has an invalid dependency entry." } }
        foreach ($conflict in $item.Conflicts) { if ($conflict -isnot [string] -or [string]::IsNullOrWhiteSpace($conflict)) { throw "Package '$($item.Key)' has an invalid conflict entry." } }
        if ($item.ExpectedState -isnot [string] -or $item.ExpectedState -notin @('installed','absent')) { throw "Package '$($item.Key)' has an invalid ExpectedState." }
        if ($item.Reboot -isnot [string] -or $item.Reboot -notin @('never','possible','required')) { throw "Package '$($item.Key)' has an invalid Reboot value." }
        if ($null -eq $item.Recovery -or $item.Recovery -is [array] -or -not $item.Recovery.PSObject.Properties['Class'] -or -not $item.Recovery.PSObject.Properties['Instructions']) { throw "Package '$($item.Key)' requires a Recovery object." }
        if ($item.Recovery.Class -notin @('automatic','manual','external')) { throw "Package '$($item.Key)' has an invalid Recovery.Class." }
        if ($item.PSObject.Properties['Version']) {
            if ($item.Version -isnot [string] -or $item.Version -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') { throw "Package '$($item.Key)' has an invalid Version." }
            if ($item.VersionPolicy -ne 'pinned') { throw "Package '$($item.Key)' has Version but VersionPolicy is not pinned." }
            if ($item.Source -eq 'msstore') { throw "Package '$($item.Key)' cannot pin an msstore version." }
            if ($item.Scope -in @('user','machine')) { throw "Package '$($item.Key)' cannot combine Version and an explicit Scope." }
        }
        if ($item.VersionPolicy -eq 'pinned' -and -not $item.PSObject.Properties['Version']) { throw "Package '$($item.Key)' pins a version but has no Version field." }
        $identity = "$($item.Source)|$($item.Id)"
        if ($keys.ContainsKey($item.Key.ToLowerInvariant())) { throw "Duplicate package Key: $($item.Key)" }
        if ($identities.ContainsKey($identity.ToLowerInvariant())) { throw "Duplicate package Source/Id: $identity" }
        $keys[$item.Key.ToLowerInvariant()] = $true
        $identities[$identity.ToLowerInvariant()] = $true
        if ($item.Id -eq 'Docker.DockerDesktop') { throw 'Docker Desktop must be selected through system:dockers, not as a catalog package.' }
        $packages += [pscustomobject][ordered]@{
            Key = [string]$item.Key
            Name = [string]$item.Name
            Vendor = [string]$item.Vendor
            Id = [string]$item.Id
            Source = [string]$item.Source
            Architecture = [string]$item.Architecture
            Scope = [string]$item.Scope
            VersionPolicy = [string]$item.VersionPolicy
            Version = if ($item.PSObject.Properties['Version']) { [string]$item.Version } else { $null }
            Stage = [string]$item.Stage
            Category = [string]$item.Category
            Groups = @($item.Groups)
            Privilege = [string]$item.Privilege
            Dependencies = @($item.Dependencies)
            Conflicts = @($item.Conflicts)
            ExpectedState = [string]$item.ExpectedState
            Reboot = [string]$item.Reboot
            Recovery = $item.Recovery
        }
    }

    $byKey = @{}
    foreach ($package in $packages) { $byKey[$package.Key.ToLowerInvariant()] = $package }
    foreach ($package in $packages) {
        foreach ($dependency in $package.Dependencies) {
            if ($dependency -ieq $package.Key) { throw "Package '$($package.Key)' depends on itself." }
            if (-not $byKey.ContainsKey($dependency.ToLowerInvariant())) { throw "Package '$($package.Key)' depends on unknown package: $dependency" }
        }
        foreach ($conflict in $package.Conflicts) {
            if (-not $byKey.ContainsKey($conflict.ToLowerInvariant())) { throw "Package '$($package.Key)' conflicts with unknown package: $conflict" }
        }
    }
    return [pscustomobject][ordered]@{
        Path = $fullPath
        SchemaVersion = 2
        CatalogVersion = [string]$config.CatalogVersion
        Groups = $groups
        Profiles = $profiles
        Packages = @($packages)
    }
}

function Get-WhinsetProfileNames {
    param([Parameter(Mandatory)]$Catalog)
    return @($Catalog.Profiles.Keys)
}

function Get-WhinsetCandidateText {
    param([Parameter(Mandatory)]$Package)
    return ("{0} | {1} | {2}/{3} | {4} | {5} | {6}" -f $Package.Key, $Package.Name, $Package.Source, $Package.Id, $Package.Vendor, $Package.Architecture, $Package.Privilege)
}

function Get-WhinsetPackageCandidates {
    param([Parameter(Mandatory)]$Catalog, [AllowEmptyString()][string]$Query)
    if ([string]::IsNullOrWhiteSpace($Query)) { return @() }
    $needle = $Query.Trim()
    $source = $null
    $identifier = $needle
    if ($needle -match '^(winget|msstore):(.+)$') { $source = $Matches[1]; $identifier = $Matches[2] }
    $exactKey = @($Catalog.Packages | Where-Object { $_.Key -ieq $identifier })
    if ($exactKey.Count -gt 0) { return $exactKey }
    $exactId = @($Catalog.Packages | Where-Object { $_.Id -ieq $identifier -and (-not $source -or $_.Source -ieq $source) })
    if ($exactId.Count -gt 0) { return $exactId }
    return @($Catalog.Packages | Where-Object { $_.Name -like "*$needle*" -or $_.Key -like "*$needle*" -or $_.Id -like "*$needle*" -or $_.Vendor -like "*$needle*" } | Sort-Object Name,Key)
}

function Resolve-WhinsetPackageReference {
    param([Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)][string]$Reference)
    $value = $Reference.Trim()
    if (-not $value) { throw 'Package reference cannot be empty.' }
    $source = $null
    $identifier = $value
    if ($value -match '^(winget|msstore):(.+)$') { $source = $Matches[1].ToLowerInvariant(); $identifier = $Matches[2] }
    $byKey = @($Catalog.Packages | Where-Object { $_.Key -ieq $identifier })
    if ($byKey.Count -eq 1) { return $byKey[0] }
    if ($byKey.Count -gt 1) { throw "Ambiguous package key: $identifier" }
    $byId = @($Catalog.Packages | Where-Object { $_.Id -ieq $identifier -and (-not $source -or $_.Source -ieq $source) })
    if ($byId.Count -eq 1) { return $byId[0] }
    if ($byId.Count -gt 1) {
        $candidates = ($byId | ForEach-Object { Get-WhinsetCandidateText $_ }) -join [Environment]::NewLine
        throw "Package ID '$identifier' exists in multiple sources. Use a stable Key or qualify it as winget:<id> / msstore:<id>.`nCandidates:`n$candidates"
    }
    $byName = @($Catalog.Packages | Where-Object { $_.Name -ieq $identifier })
    if ($byName.Count -gt 0) {
        $candidates = ($byName | ForEach-Object { Get-WhinsetCandidateText $_ }) -join [Environment]::NewLine
        throw "Display names are not installation selectors. Use an exact package Key or ID.`nCandidates:`n$candidates"
    }
    $suggestions = @(Get-WhinsetPackageCandidates -Catalog $Catalog -Query $identifier | Select-Object -First 8)
    $hint = ''
    if ($suggestions.Count -gt 0) { $hint = "`nPossible matches:`n" + (($suggestions | ForEach-Object { Get-WhinsetCandidateText $_ }) -join [Environment]::NewLine) }
    throw "Unknown package reference: $Reference$hint"
}

function Test-WhinsetCatalogCycles {
    param([Parameter(Mandatory)]$Catalog)
    $nodes = @($Catalog.Packages | ForEach-Object {
        [pscustomobject][ordered]@{ Id = $_.Key; DependsOn = @($_.Dependencies); Priority = 0; SortKey = $_.Key }
    })
    $ordered = Get-WhinsetTopologicalOrder -Nodes $nodes -GraphName 'package dependency graph'
    return $ordered
}

function Resolve-WhinsetSelection {
    param(
        [Parameter(Mandatory)]$Catalog,
        [string]$Profile = 'Developer',
        [string[]]$Package = @(),
        [string[]]$Exclude = @(),
        [string[]]$Group = @(),
        [switch]$IncludePersonal,
        [switch]$SkipStoreApps
    )
    $profileKey = $Profile.ToLowerInvariant()
    if (-not $Catalog.Profiles.Contains($profileKey)) { throw "Unknown profile '$Profile'. Available profiles: $(@($Catalog.Profiles.Keys) -join ', ')" }
    $groups = @($Catalog.Profiles[$profileKey].Groups)
    foreach ($extraGroup in $Group) {
        $match = @($Catalog.Groups | Where-Object { $_ -ieq $extraGroup })
        if ($match.Count -ne 1) { throw "Unknown group '$extraGroup'. Available groups: $($Catalog.Groups -join ', ')" }
        $groups += $match[0]
    }
    if ($IncludePersonal) { $groups += 'Personal' }
    $groups = @($groups | Select-Object -Unique)

    $selected = @{}
    $reasons = [ordered]@{}
    $explicit = @{}
    foreach ($item in $Catalog.Packages) {
        $groupMatch = @($item.Groups | Where-Object { $groups -contains $_ }).Count -gt 0
        if (-not $groupMatch) { continue }
        if ($SkipStoreApps -and $item.Source -eq 'msstore') { continue }
        $selected[$item.Key.ToLowerInvariant()] = $item
        $reasons[$item.Key] = 'profile'
    }
    foreach ($reference in $Package) {
        $item = Resolve-WhinsetPackageReference -Catalog $Catalog -Reference $reference
        if ($SkipStoreApps -and $item.Source -eq 'msstore') { throw "Package '$($item.Key)' is from msstore but -SkipStoreApps was supplied." }
        $selected[$item.Key.ToLowerInvariant()] = $item
        $explicit[$item.Key.ToLowerInvariant()] = $true
        $reasons[$item.Key] = 'explicit'
    }

    $excluded = @{}
    foreach ($reference in $Exclude) {
        $item = Resolve-WhinsetPackageReference -Catalog $Catalog -Reference $reference
        if ($explicit.ContainsKey($item.Key.ToLowerInvariant())) { throw "Package '$($item.Key)' is both explicitly selected and excluded." }
        $excluded[$item.Key.ToLowerInvariant()] = $true
        $selected.Remove($item.Key.ToLowerInvariant())
        $reasons.Remove($item.Key)
    }

    $queue = New-Object System.Collections.Queue
    foreach ($item in @($selected.Values)) { $queue.Enqueue($item) }
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        foreach ($dependencyKey in $item.Dependencies) {
            $lower = $dependencyKey.ToLowerInvariant()
            if ($excluded.ContainsKey($lower)) { throw "Cannot exclude '$dependencyKey': selected package '$($item.Key)' depends on it." }
            if ($selected.ContainsKey($lower)) { continue }
            $dependency = @($Catalog.Packages | Where-Object { $_.Key -ieq $dependencyKey })[0]
            if ($SkipStoreApps -and $dependency.Source -eq 'msstore') { throw "Dependency '$dependencyKey' is from msstore but -SkipStoreApps was supplied." }
            $selected[$lower] = $dependency
            $reasons[$dependency.Key] = "dependency of $($item.Key)"
            $queue.Enqueue($dependency)
        }
    }

    $resultPackages = @($selected.Values | Sort-Object Key)
    foreach ($item in $resultPackages) {
        foreach ($conflictKey in $item.Conflicts) {
            $conflict = @($resultPackages | Where-Object { $_.Key -ieq $conflictKey })
            if ($conflict.Count -gt 0) { throw "Package conflict: '$($item.Key)' conflicts with selected package '$($conflict[0].Key)'." }
        }
    }
    [void](Test-WhinsetCatalogCycles -Catalog ([pscustomobject]@{ Packages = $resultPackages }))
    return [pscustomobject][ordered]@{
        Profile = $profileKey
        Groups = $groups
        Packages = $resultPackages
        SelectionReasons = $reasons
        Excluded = @($excluded.Keys | Sort-Object)
    }
}

function Get-WhinsetTopologicalOrder {
    param([Parameter(Mandatory)][object[]]$Nodes, [string]$GraphName = 'operation graph')
    $byId = @{}
    foreach ($node in $Nodes) {
        if (-not $node.Id) { throw "Node without Id in $GraphName." }
        if ($byId.ContainsKey([string]$node.Id)) { throw "Duplicate node '$($node.Id)' in $GraphName." }
        $byId[[string]$node.Id] = $node
    }
    $remaining = @{}
    $indegree = @{}
    foreach ($node in $Nodes) {
        $id = [string]$node.Id
        $remaining[$id] = $true
        $indegree[$id] = 0
        foreach ($dependency in @($node.DependsOn)) {
            if (-not $byId.ContainsKey([string]$dependency)) { throw "Node '$id' depends on unknown node '$dependency' in $GraphName." }
        }
    }
    foreach ($node in $Nodes) {
        foreach ($dependency in @($node.DependsOn)) { $indegree[[string]$node.Id] = [int]$indegree[[string]$node.Id] + 1 }
    }
    $result = New-Object System.Collections.Generic.List[object]
    while ($remaining.Count -gt 0) {
        $ready = @($Nodes | Where-Object { $remaining.ContainsKey([string]$_.Id) -and [int]$indegree[[string]$_.Id] -eq 0 } | Sort-Object @{Expression={[int]$_.Priority}}, @{Expression={[string]$_.SortKey}})
        if ($ready.Count -eq 0) {
            $cycleNodes = @($remaining.Keys | Sort-Object) -join ', '
            throw "Dependency cycle detected in $GraphName. Unresolved nodes: $cycleNodes"
        }
        $node = $ready[0]
        $id = [string]$node.Id
        [void]$result.Add($node)
        $remaining.Remove($id)
        foreach ($candidate in $Nodes) {
            if (@($candidate.DependsOn) -contains $id) { $indegree[[string]$candidate.Id] = [int]$indegree[[string]$candidate.Id] - 1 }
        }
    }
    return $result.ToArray()
}
