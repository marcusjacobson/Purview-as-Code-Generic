#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Unit tests for scripts/Get-TenantResidualScanCommand.ps1 (ADR 0046).

.DESCRIPTION
    Drift guard for the single-sourced Step 6 placeholder scans. The script
    generates the residual / functional-workflow `git grep` commands from
    .github/agents/tenant-placeholders.yaml so the operator agent body never
    hand-copies the exclude list. These tests assert the generated commands
    stay faithful to the manifest: the residual command carries the manifest
    pattern and EVERY intentionalSamples pathspec; the functional command
    carries its pattern + pathspec and no longer references the removed
    owner-login gate; and the emitted strings are copy-paste safe.

    The script is read-only (it only parses YAML and prints strings), so the
    tests invoke it directly rather than extracting a function. No Graph,
    Azure, or tenant calls are made.

    Reference: https://pester.dev/docs/quick-start
    Reference: docs/adr/0046-tenant-placeholder-manifest.md
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Get-TenantResidualScanCommand.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Get-TenantResidualScanCommand.ps1 at: $script:ScriptPath"
    }

    $script:ManifestPath = Join-Path $PSScriptRoot '..' '..' '.github' 'agents' 'tenant-placeholders.yaml'
    if (-not (Test-Path $script:ManifestPath)) {
        throw "Could not locate tenant-placeholders.yaml at: $script:ManifestPath"
    }

    # Parse the manifest independently so the expected values are read from the
    # source of truth, not duplicated in the test.
    if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
        Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module 'powershell-yaml' -ErrorAction Stop
    $script:Manifest = (Get-Content -LiteralPath $script:ManifestPath -Raw) | ConvertFrom-Yaml
}

Describe 'Get-TenantResidualScanCommand — schema contract' {
    It 'manifest is schemaVersion 2 or later' {
        [int]$script:Manifest.schemaVersion | Should -BeGreaterOrEqual 2
    }
}

Describe 'Get-TenantResidualScanCommand -Kind Residual' {
    BeforeAll {
        $script:Residual = & $script:ScriptPath -Kind Residual
    }

    It 'emits exactly one command line' {
        @($script:Residual).Count | Should -Be 1
    }

    It 'is a copy-paste-safe git grep invocation' {
        $script:Residual | Should -Match '^git --no-pager grep -nEi '
        $script:Residual | Should -Match ' -- '
    }

    It 'carries the manifest residualScan.pattern' {
        $script:Residual | Should -BeLike "*'$($script:Manifest.residualScan.pattern)'*"
    }

    It 'carries every intentionalSamples pathspec, single-quoted' {
        foreach ($spec in $script:Manifest.intentionalSamples) {
            $script:Residual | Should -BeLike "*'$spec'*"
        }
    }
}

Describe 'Get-TenantResidualScanCommand -Kind Functional' {
    BeforeAll {
        $script:Functional = & $script:ScriptPath -Kind Functional
    }

    It 'emits exactly one command line' {
        @($script:Functional).Count | Should -Be 1
    }

    It 'carries the functionalWorkflowScan pattern and pathspec' {
        $script:Functional | Should -BeLike "*'$($script:Manifest.functionalWorkflowScan.pattern)'*"
        $script:Functional | Should -BeLike "*'$($script:Manifest.functionalWorkflowScan.pathspec)'*"
    }

    It 'no longer references the removed owner-login gate' {
        $script:Functional | Should -Not -Match 'user\.login'
    }
}

Describe 'Get-TenantResidualScanCommand -Kind All' {
    BeforeAll {
        $script:All = @(& $script:ScriptPath -Kind All)
    }

    It 'emits both commands, residual first then functional' {
        $script:All.Count | Should -Be 2
        $script:All[0] | Should -Match '^git --no-pager grep -nEi '
        $script:All[1] | Should -BeLike "*'$($script:Manifest.functionalWorkflowScan.pathspec)'*"
    }

    It 'defaults to All when -Kind is omitted' {
        $default = @(& $script:ScriptPath)
        $default.Count | Should -Be 2
    }
}
