function Show-WhinsetHelp {
    param([string]$Topic = '')
    $topicKey = $Topic.ToLowerInvariant()
    if (-not $topicKey) {
        return @"
Whinset $($script:WhinsetVersion) - deterministic Windows 11 setup

Usage:
  whinset plan   [-Profile <name>] [-Package <key-or-id>] [-Exclude <key-or-id>] [-Group <group>] [-Json]
  whinset apply  [-Profile <name>] [-Package <key-or-id>] [-Exclude <key-or-id>] [-AcceptAgreements] [-Json]
  whinset status [-RunId <id>] [-Json]
  whinset doctor [-Json]
  whinset resolve <query> [-Json]
  whinset recover [-RunId <id>] [-Retry] [-Json]
  whinset install-cli
  whinset version

Core options:
  -Profile Minimal|Developer|AI|Engineering|Full   Catalog profile (default Developer)
  -Package <key-or-id>                               Exact stable key or exact Source:Id; repeatable
  -Exclude <key-or-id>                               Exact package to exclude; repeatable
  -Group <group>                                     Add Core, Developer, AI, Engineering or Personal
  -IncludePersonal                                   Add the Personal group
  -SkipStoreApps                                     Exclude msstore packages
  -Stage Auto|WindowsBase|Development                Limit package stages (default Auto)
  -ConfigureEnvironment                              Add user/admin environment operations
  -EnableWsl                                        Enable WSL prerequisites, runtime and Ubuntu
  -EnableDocker                                     Enable WSL and install Docker Desktop
  -DockerSmokeTest                                  Run docker hello-world after installation
  -Json                                              Emit one structured JSON document
  -Help, -?                                          Show this help

Examples:
  whinset plan -Profile Developer
  whinset plan -Profile Minimal -Exclude Chrome
  whinset apply -Profile Minimal -AcceptAgreements
  whinset resolve chrome
  whinset status
  whinset doctor
  whinset recover -Retry

Run 'whinset help apply' or 'whinset help security' for details.
"@
    }
    switch ($topicKey) {
        'plan' { return "whinset plan`n`nBuilds and validates a deterministic execution plan without creating Whinset state or requesting UAC. WinGet inventory is read-only. Use -Offline to skip inventory." }
        'apply' { return "whinset apply`n`nRebuilds the plan, executes user operations in the current user context, then performs every elevated operation in one elevated worker. Requires -AcceptAgreements. UAC is requested once only when elevated work remains. Exit 3010 means restart and then run 'whinset recover -Retry'." }
        'status' { return "whinset status [-RunId <id>]`n`nShows the latest or selected run, operation results, recovery state and read-only legacy SetupNewPC state." }
        'doctor' { return "whinset doctor`n`nRuns read-only environment checks for Windows 11, architecture, PowerShell, WinGet, sources, catalog, plan engine, state compatibility and restart state." }
        'resolve' { return "whinset resolve <query>`n`nShows package Keys, names, vendors, exact Source:Id identities, architecture, scope and privilege. Display names are never accepted as installation selectors." }
        'recover' { return "whinset recover [-RunId <id>] [-Retry]`n`nShows pending operations and recovery limits. -Retry uses the saved, reconstructed and hash-verified plan. If a restart is still required in the same boot, it returns 3010 instead of continuing." }
        'security' { return "Privilege model`n`nAll package operations in this release candidate use the existing machine-wide scope behavior and are classified as elevated. User-specific environment operations run outside the elevated worker. The elevated worker accepts only an allowlisted serialized plan reconstructed from the installed catalog; it never executes arbitrary plan-provided PowerShell. UAC is requested through Windows Start-Process -Verb RunAs and is never bypassed. No automatic rollback is claimed." }
        default { throw "Unknown help topic: $Topic" }
    }
}
