BeforeAll {
    $TestModuleName = "GroupSharedProjectTest"
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

Describe "Get-GitlabGroupSharedProject" {

    Context "API path" {
        BeforeEach {
            Mock -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -MockWith { @() }
        }

        It "Should call the correct API endpoint" {
            Get-GitlabGroupSharedProject -GroupId 'my-group'

            Should -Invoke -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -ParameterFilter {
                $Method -eq 'GET' -and $Path -eq 'groups/my-group/projects/shared'
            }
        }

        It "Should URL-encode the group path" {
            Get-GitlabGroupSharedProject -GroupId 'my/nested/group'

            Should -Invoke -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -ParameterFilter {
                $Method -eq 'GET' -and $Path -eq 'groups/my%2Fnested%2Fgroup/projects/shared'
            }
        }
    }

    Context "Query parameters" {
        BeforeEach {
            Mock -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -MockWith { @() }
        }

        It "Should pass search parameter" {
            Get-GitlabGroupSharedProject -GroupId 'my-group' -Search 'foo'

            Should -Invoke -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -ParameterFilter {
                $Query.search -eq 'foo'
            }
        }

        It "Should pass visibility parameter" {
            Get-GitlabGroupSharedProject -GroupId 'my-group' -Visibility 'private'

            Should -Invoke -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -ParameterFilter {
                $Query.visibility -eq 'private'
            }
        }

        It "Should pass order_by parameter" {
            Get-GitlabGroupSharedProject -GroupId 'my-group' -OrderBy 'name'

            Should -Invoke -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -ParameterFilter {
                $Query.order_by -eq 'name'
            }
        }

        It "Should pass sort parameter" {
            Get-GitlabGroupSharedProject -GroupId 'my-group' -Sort 'asc'

            Should -Invoke -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -ParameterFilter {
                $Query.sort -eq 'asc'
            }
        }

        It "Should pass archived switch" {
            Get-GitlabGroupSharedProject -GroupId 'my-group' -Archived

            Should -Invoke -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -ParameterFilter {
                $Query.archived -eq 'true'
            }
        }

        It "Should pass simple switch" {
            Get-GitlabGroupSharedProject -GroupId 'my-group' -Simple

            Should -Invoke -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -ParameterFilter {
                $Query.simple -eq 'true'
            }
        }

        It "Should pass starred switch" {
            Get-GitlabGroupSharedProject -GroupId 'my-group' -Starred

            Should -Invoke -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -ParameterFilter {
                $Query.starred -eq 'true'
            }
        }

        It "Should pass with_issues_enabled switch" {
            Get-GitlabGroupSharedProject -GroupId 'my-group' -WithIssuesEnabled

            Should -Invoke -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -ParameterFilter {
                $Query.with_issues_enabled -eq 'true'
            }
        }

        It "Should pass with_merge_requests_enabled switch" {
            Get-GitlabGroupSharedProject -GroupId 'my-group' -WithMergeRequestsEnabled

            Should -Invoke -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -ParameterFilter {
                $Query.with_merge_requests_enabled -eq 'true'
            }
        }

        It "Should pass min_access_level parameter" {
            Get-GitlabGroupSharedProject -GroupId 'my-group' -MinAccessLevel 30

            Should -Invoke -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -ParameterFilter {
                $Query.min_access_level -eq 30
            }
        }

        It "Should not include unset optional parameters in query" {
            Get-GitlabGroupSharedProject -GroupId 'my-group'

            Should -Invoke -CommandName Invoke-GitlabApi -ModuleName $TestModuleName -ParameterFilter {
                $Query.Count -eq 0
            }
        }
    }
}
