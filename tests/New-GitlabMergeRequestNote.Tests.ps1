BeforeAll {
    $TestModuleName = "Notes"
    Get-Module -Name $TestModuleName -All | Remove-Module -Force -ErrorAction SilentlyContinue

    . $PSScriptRoot/../src/GitlabCli/Private/Transformations.ps1

    Import-Module (New-Module -Name $TestModuleName -ScriptBlock ([scriptblock]::Create(
        @(
            Get-Content "$PSScriptRoot/../src/GitlabCli/Private/Globals.ps1" -Raw
            Get-Content "$PSScriptRoot/../src/GitlabCli/Private/Functions/PaginationHelpers.ps1" -Raw
            Get-Content "$PSScriptRoot/../src/GitlabCli/Private/Validations.ps1" -Raw
            Get-Content "$PSScriptRoot/../src/GitlabCli/Notes.psm1" -Raw
        ) -join "`n"))) -Force

    function global:Invoke-GitlabApi {
        param(
            [Parameter(Position=0)][string]$Method,
            [Parameter(Position=1)][string]$Path,
            [hashtable]$Query,
            [hashtable]$Body,
            [uint]$MaxPages
        )
        @()
    }
    function global:New-GitlabObject {
        param(
            [Parameter(ValueFromPipeline)]$InputObject,
            [Parameter(Position=0)][string]$DisplayType
        )
        process { $InputObject }
    }
    function global:Resolve-GitlabProjectId {
        param([Parameter(Position=0)][string]$ProjectId)
        return $ProjectId
    }
}

Describe "New-GitlabMergeRequestNote" {
    BeforeEach {
        Mock -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -MockWith { @() }
    }

    It "Should POST to the merge request notes endpoint" {
        New-GitlabMergeRequestNote -ProjectId '123' -MergeRequestId '7' -Note 'Looks good' -Confirm:$false

        Should -Invoke -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -ParameterFilter {
            $Method -eq 'POST' -and $Path -eq 'projects/123/merge_requests/7/notes'
        }
    }

    It "Should send the note text as the body" {
        New-GitlabMergeRequestNote -ProjectId '123' -MergeRequestId '7' -Note 'Looks good' -Confirm:$false

        Should -Invoke -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -ParameterFilter {
            $Body.body -eq 'Looks good'
        }
    }

    It "Should not call the API when -WhatIf is specified" {
        New-GitlabMergeRequestNote -ProjectId '123' -MergeRequestId '7' -Note 'Looks good' -WhatIf

        Should -Not -Invoke -CommandName Invoke-GitlabApi -ModuleName $TestModuleName
    }

    It "Should support the Add-GitlabMergeRequestNote alias" {
        Add-GitlabMergeRequestNote -ProjectId '123' -MergeRequestId '7' -Note 'Looks good' -Confirm:$false

        Should -Invoke -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -ParameterFilter {
            $Method -eq 'POST' -and $Path -eq 'projects/123/merge_requests/7/notes'
        }
    }
}
