#Requires -Version 7.4
<#
.SYNOPSIS
    Emit the ready-to-run Step 6 placeholder-scan `git grep` command(s) from the
    tenant placeholder manifest, so the operator agent body never hand-copies
    the exclude list.

.DESCRIPTION
    Single-sources the @operator-tenant Step 6 residual/functional scans from
    .github/agents/tenant-placeholders.yaml (ratified by
    docs/adr/0046-tenant-placeholder-manifest.md). Prior to this helper the full
    `git grep` command — the search regex plus ~20 `:!pathspec` excludes — was
    hardcoded in operator-tenant.agent.md, duplicating the manifest's
    `intentionalSamples` list and free to drift from it. This script reads the
    manifest and assembles the exact command(s) so the manifest is the only
    place the scan is defined.

    It reads three manifest keys (schemaVersion 2+):
      * residualScan.pattern            — the broad-scan search regex.
      * intentionalSamples              — the exclude pathspecs for the broad scan.
      * functionalWorkflowScan.pattern  — the targeted workflow-value regex.
      * functionalWorkflowScan.pathspec — the workflow path to scan.

    Read-only: it parses the manifest and writes command strings to the output
    stream. It never runs git, never edits files, never touches the tenant.

    References:
      ADR 0046 (this script's contract):
        docs/adr/0046-tenant-placeholder-manifest.md
      powershell-yaml (ConvertFrom-Yaml):
        https://www.powershellgallery.com/packages/powershell-yaml
      git grep / pathspec:
        https://git-scm.com/docs/git-grep
        https://git-scm.com/docs/gitglossary#Documentation/gitglossary.txt-pathspec

.PARAMETER Kind
    Which command(s) to emit:
      * Residual   — the broad scan (residualScan.pattern excluding intentionalSamples).
      * Functional — the targeted workflow scan (functionalWorkflowScan).
      * All         — both, Residual first then Functional (default).

.PARAMETER ManifestPath
    Path to the tenant placeholder manifest. Defaults to the repo copy at
    .github/agents/tenant-placeholders.yaml relative to this script.

.EXAMPLE
    ./scripts/Get-TenantResidualScanCommand.ps1

    Emits both the residual and functional-workflow scan commands.

.EXAMPLE
    ./scripts/Get-TenantResidualScanCommand.ps1 -Kind Residual | Invoke-Expression

    Runs just the broad residual scan.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('Residual', 'Functional', 'All')]
    [string]$Kind = 'All',

    [Parameter()]
    [string]$ManifestPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $PSBoundParameters.ContainsKey('ManifestPath') -or [string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $PSScriptRoot '..' '.github' 'agents' 'tenant-placeholders.yaml'
}

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "Tenant placeholder manifest not found at '$ManifestPath'."
}

# Reference: https://www.powershellgallery.com/packages/powershell-yaml
if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Write-Information 'Installing powershell-yaml module to CurrentUser scope.' -InformationAction Continue
    Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
}
Import-Module 'powershell-yaml' -ErrorAction Stop

$manifest = (Get-Content -LiteralPath $ManifestPath -Raw) | ConvertFrom-Yaml

# The structured residualScan / functionalWorkflowScan blocks were introduced at
# schemaVersion 2 (ADR 0046). Fail loudly on an older manifest rather than emit a
# half-formed command.
$schemaVersion = if ($manifest.ContainsKey('schemaVersion')) { [int]$manifest.schemaVersion } else { 0 }
if ($schemaVersion -lt 2) {
    throw "Manifest '$ManifestPath' is schemaVersion $schemaVersion; this script requires schemaVersion 2 or later (structured residualScan / functionalWorkflowScan blocks)."
}

function Get-QuotedList {
    param([Parameter(Mandatory = $true)][string[]]$Values)
    return ($Values | ForEach-Object { "'$_'" }) -join ' '
}

function Get-ResidualScanCommand {
    if (-not $manifest.ContainsKey('residualScan') -or -not $manifest.residualScan.ContainsKey('pattern')) {
        throw "Manifest is missing 'residualScan.pattern'."
    }
    if (-not $manifest.ContainsKey('intentionalSamples')) {
        throw "Manifest is missing 'intentionalSamples'."
    }
    $pattern = [string]$manifest.residualScan.pattern
    $excludes = @($manifest.intentionalSamples | ForEach-Object { [string]$_ })
    return "git --no-pager grep -nEi '$pattern' -- $(Get-QuotedList -Values $excludes)"
}

function Get-FunctionalWorkflowScanCommand {
    if (-not $manifest.ContainsKey('functionalWorkflowScan') -or
        -not $manifest.functionalWorkflowScan.ContainsKey('pattern') -or
        -not $manifest.functionalWorkflowScan.ContainsKey('pathspec')) {
        throw "Manifest is missing 'functionalWorkflowScan.pattern' or 'functionalWorkflowScan.pathspec'."
    }
    $pattern = [string]$manifest.functionalWorkflowScan.pattern
    $pathspec = [string]$manifest.functionalWorkflowScan.pathspec
    return "git --no-pager grep -nE '$pattern' -- '$pathspec'"
}

switch ($Kind) {
    'Residual' { Get-ResidualScanCommand }
    'Functional' { Get-FunctionalWorkflowScanCommand }
    'All' {
        Get-ResidualScanCommand
        Get-FunctionalWorkflowScanCommand
    }
}
