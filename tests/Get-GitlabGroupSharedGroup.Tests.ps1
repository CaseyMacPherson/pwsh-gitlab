BeforeAll {
    $TestModuleName = "GroupSharedGroupTest"
    Get-Module -Name $TestModuleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Get-Module -Name GitlabCli -All | Remove-Module -Force -ErrorAction SilentlyContinue

    . $PSScriptRoot/../src/GitlabCli/Private/Transformations.ps1

    Import-Module (New-Module -Name $TestModuleName -ScriptBlock ([scriptblock]::Create(
        @(
            Get-Content "$PSScriptRoot/../src/GitlabCli/Private/Globals.ps1" -Raw
            Get-Content "$PSScriptRoot/../src/GitlabCli/Private/Functions/PaginationHelpers.ps1" -Raw
            Get-Content "$PSScriptRoot/../src/GitlabCli/Private/Validations.ps1" -Raw
            Get-Content "$PSScriptRoot/../src/GitlabCli/Groups.psm1" -Raw
        ) -join "`n"))) -Force

    function global:Invoke-GitlabApi {
        param(
            [Parameter(Position=0)][string]$Method,
            [Parameter(Position=1)][string]$Path,
            [hashtable]$Query,
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
    function global:Resolve-LocalGroupPath {
        param([string]$GroupId)
        return $GroupId
    }
    function global:Save-GroupToCache {
        param([Parameter(ValueFromPipeline)]$InputObject)
        process { $InputObject }
    }
    function global:Resolve-GitlabGroupId {
        param([Parameter(Position=0)][string]$GroupId)
        return $GroupId
    }
}

Describe "Get-GitlabGroupSharedGroup" {

    Context "API path" {
        BeforeEach {
            Mock -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -MockWith { @() }
        }

        It "Should call the correct API endpoint" {
            Get-GitlabGroupSharedGroup -GroupId 'my-group'

            Should -Invoke -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -ParameterFilter {
                $Method -eq 'GET' -and $Path -eq 'groups/my-group/groups/shared'
            }
        }

        It "Should URL-encode the group path" {
            Get-GitlabGroupSharedGroup -GroupId 'my/nested/group'

            Should -Invoke -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -ParameterFilter {
                $Method -eq 'GET' -and $Path -eq 'groups/my%2Fnested%2Fgroup/groups/shared'
            }
        }
    }

    Context "Query parameters" {
        BeforeEach {
            Mock -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -MockWith { @() }
        }

        It "Should pass search parameter" {
            Get-GitlabGroupSharedGroup -GroupId 'my-group' -Search 'foo'

            Should -Invoke -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -ParameterFilter {
                $Query.search -eq 'foo'
            }
        }

        It "Should pass visibility parameter" {
            Get-GitlabGroupSharedGroup -GroupId 'my-group' -Visibility 'internal'

            Should -Invoke -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -ParameterFilter {
                $Query.visibility -eq 'internal'
            }
        }

        It "Should pass order_by parameter" {
            Get-GitlabGroupSharedGroup -GroupId 'my-group' -OrderBy 'path'

            Should -Invoke -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -ParameterFilter {
                $Query.order_by -eq 'path'
            }
        }

        It "Should pass sort parameter" {
            Get-GitlabGroupSharedGroup -GroupId 'my-group' -Sort 'desc'

            Should -Invoke -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -ParameterFilter {
                $Query.sort -eq 'desc'
            }
        }

        It "Should pass skip_groups parameter" {
            Get-GitlabGroupSharedGroup -GroupId 'my-group' -SkipGroups 1, 2, 3

            Should -Invoke -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -ParameterFilter {
                ($Query.skip_groups -join ',') -eq '1,2,3'
            }
        }

        It "Should pass min_access_level parameter" {
            Get-GitlabGroupSharedGroup -GroupId 'my-group' -MinAccessLevel 40

            Should -Invoke -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -ParameterFilter {
                $Query.min_access_level -eq 40
            }
        }

        It "Should not include unset optional parameters in query" {
            Get-GitlabGroupSharedGroup -GroupId 'my-group'

            Should -Invoke -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -ParameterFilter {
                $Query.Count -eq 0
            }
        }
    }
}
