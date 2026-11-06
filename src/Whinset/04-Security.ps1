function Assert-WhinsetSameUser {
    param([Parameter(Mandatory)][string]$OriginalUserSid, [Parameter(Mandatory)][string]$CurrentUserSid)
    if ($OriginalUserSid -ne $CurrentUserSid) {
        throw 'Different-user UAC credentials are unsupported. No worker operations were started. Run as the intended user with same-user elevation.'
    }
}

function Assert-WhinsetStateMatchesPlan {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Plan)
    if ($State.PlanHash -ne $Plan.PlanHash -or $State.RunId -ne $Plan.RunId -or $State.OriginalUserSid -ne $Plan.Environment.UserSid -or $State.MachineIdentity.ComputerName -ne $Plan.Environment.ComputerName) { throw 'State identity does not match the plan.' }
    $expected = @($Plan.Operations.Id | Sort-Object)
    $actual = @($State.Operations.Id | Sort-Object)
    if (($expected -join "`n") -cne ($actual -join "`n")) { throw 'State operations do not match the plan.' }
    foreach ($record in $State.Operations) {
        $operation = @($Plan.Operations | Where-Object { $_.Id -eq $record.Id })[0]
        if ($record.Kind -ne $operation.Kind -or $record.Privilege -ne $operation.Privilege -or $record.Status -notin @('Pending','Running','Succeeded','AlreadyInstalled','Skipped','Warning','Failed','AwaitingReboot','Blocked')) { throw 'State operation metadata is inconsistent.' }
    }
}

function Assert-WhinsetPrivatePath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$UserSid)
    $full = [IO.Path]::GetFullPath($Path)
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse points are unsupported in state paths: $cursor" }
        }
        $cursor = Split-Path $cursor -Parent
    }
    $acl = Get-Acl -LiteralPath $full
    $allowed = @($UserSid,'S-1-5-18','S-1-5-32-544')
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $allowed) { throw "Untrusted state owner: $full" }
    $writeMask = [Security.AccessControl.FileSystemRights]'Write,Modify,FullControl,Delete,ChangePermissions,TakeOwnership'
    foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq 'Allow' -and ($rule.FileSystemRights -band $writeMask) -and $rule.IdentityReference.Value -notin $allowed) { throw "State path grants another principal write access: $full" }
    }
}

function Initialize-WhinsetPrivateRunDirectory {
    param([Parameter(Mandatory)][string]$Path)
    $sid = [string](Get-WhinsetMachineIdentity).UserSid
    if (-not (Test-Path -LiteralPath $Path)) {
        # Check existing ancestors before creation, then remove inherited access on the new run.
        $cursor = Split-Path ([IO.Path]::GetFullPath($Path)) -Parent
        while ($cursor) {
            if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Reparse points are unsupported in state paths.' }
            $cursor = Split-Path $cursor -Parent
        }
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true,$false)
        $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier($sid)))
        foreach ($principal in @($sid,'S-1-5-18','S-1-5-32-544')) {
            $identity = New-Object Security.Principal.SecurityIdentifier($principal)
            $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $Path -AclObject $acl
    }
    Assert-WhinsetPrivatePath -Path $Path -UserSid $sid
}

function Get-WhinsetNativeErrorCode {
    param([Parameter(Mandatory)][Exception]$Exception)
    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [ComponentModel.Win32Exception]) { return [int]$current.NativeErrorCode }
        if (($current.HResult -band 0x7fff0000) -eq 0x00070000) { return [int]($current.HResult -band 0xffff) }
        $current = $current.InnerException
    }
    return $null
}

function Assert-WhinsetElevationRequest {
    param($Request, $Plan, $State, [string]$PlanPath, [string]$PlanHash, [string]$Nonce)
    if ($Nonce -cnotmatch '^[a-f0-9]{32}$' -or $Request.SchemaVersion -ne 1 -or $Request.Nonce -cne $Nonce -or $Request.PlanHash -cne $PlanHash) { throw 'Elevation request nonce or plan hash does not match.' }
    if ([IO.Path]::GetFullPath([string]$Request.PlanPath) -ine [IO.Path]::GetFullPath($PlanPath) -or $Request.RunId -ne $Plan.RunId -or $Request.OriginalUserSid -ne $Plan.Environment.UserSid) { throw 'Elevation request identity or path does not match.' }
    # PS7 ConvertFrom-Json materializes ISO timestamps as DateTime; PS5.1 leaves strings.
    if ($Request.CreatedAt -is [datetime]) { $created = [DateTimeOffset]$Request.CreatedAt }
    else { $created = [DateTimeOffset]::Parse([string]$Request.CreatedAt, [Globalization.CultureInfo]::InvariantCulture) }
    $age = ([DateTimeOffset]::UtcNow - $created.ToUniversalTime()).TotalSeconds
    if ($age -lt -30 -or $age -gt 600) { throw 'Elevation request is stale or has a future timestamp.' }
    Assert-WhinsetSameUser -OriginalUserSid $Request.OriginalUserSid -CurrentUserSid ([string](Get-WhinsetMachineIdentity).UserSid)
    Assert-WhinsetStateMatchesPlan -State $State -Plan $Plan
}
