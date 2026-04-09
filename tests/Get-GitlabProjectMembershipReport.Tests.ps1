BeforeAll {
    $TestModuleName = "Members"
    Get-Module -Name $TestModuleName -All | Remove-Module -Force -ErrorAction SilentlyContinue

    . $PSScriptRoot/../src/GitlabCli/Private/Transformations.ps1

    # Strip [AccessLevel()] attributes from Members.psm1 source before loading
    # to avoid Pester failing to build CommandMetadata when mocking
    $MembersContent = (Get-Content "$PSScriptRoot/../src/GitlabCli/Members.psm1" -Raw) -replace '\[AccessLevel\(\)\]', ''

    Import-Module (New-Module -Name $TestModuleName -ScriptBlock ([scriptblock]::Create(
        @(
            Get-Content "$PSScriptRoot/../src/GitlabCli/Private/Globals.ps1" -Raw
            Get-Content "$PSScriptRoot/../src/GitlabCli/Private/Functions/PaginationHelpers.ps1" -Raw
            Get-Content "$PSScriptRoot/../src/GitlabCli/Private/Validations.ps1" -Raw
            $MembersContent
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
    function global:Resolve-GitlabProjectId {
        param([Parameter(Position=0)][string]$ProjectId)
        return $ProjectId
    }
    function global:Resolve-GitlabGroupId {
        param([Parameter(Position=0)][string]$GroupId)
        return $GroupId
    }

    function global:Get-GitlabProject {
        param([string]$ProjectId)
        [PSCustomObject]@{
            Id                = 100
            Name              = 'my-project'
            PathWithNamespace = 'top-group/sub-group/my-project'
            SharedWithGroups  = @()
        }
    }
    function global:Get-GitlabGroup {
        param([string]$GroupId)
        switch ($GroupId) {
            'top-group/sub-group' {
                [PSCustomObject]@{ Id = 10; Name = 'sub-group'; FullPath = 'top-group/sub-group'; SharedWithGroups = @() }
            }
            'top-group' {
                [PSCustomObject]@{ Id = 1; Name = 'top-group'; FullPath = 'top-group'; SharedWithGroups = @(
                    @{ group_id = 50; group_name = 'invited-team'; group_access_level = 30 }
                ) }
            }
            '50' {
                [PSCustomObject]@{ Id = 50; Name = 'invited-team'; FullPath = 'other/invited-team'; SharedWithGroups = @() }
            }
            default {
                [PSCustomObject]@{ Id = 99; Name = $GroupId; FullPath = $GroupId; SharedWithGroups = @() }
            }
        }
    }
    function global:Get-GitlabUser {
        param([string]$UserId, [string]$Username)
        $Id = if ($UserId) { $UserId } else { $Username }
        [PSCustomObject]@{ Id = $Id; Username = $Id }
    }

    function global:Save-GroupToCache {
        param([Parameter(ValueFromPipeline)]$InputObject)
        process { $InputObject }
    }
}

AfterAll {
    Get-Module -Name $TestModuleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe "Get-GitlabProjectMembershipReport" {

    BeforeEach {
        # Direct project members (no -IncludeInherited)
        Mock -CommandName Get-GitlabProjectMember -ModuleName $TestModuleName -ParameterFilter { -not $IncludeInherited } -MockWith {
            @(
                [PSCustomObject]@{ Id = 1; Username = 'alice';  Name = 'Alice';  AccessLevel = 40 }
                [PSCustomObject]@{ Id = 2; Username = 'bob';    Name = 'Bob';    AccessLevel = 30 }
            )
        }

        # All effective project members (with -IncludeInherited)
        Mock -CommandName Get-GitlabProjectMember -ModuleName $TestModuleName -ParameterFilter { $IncludeInherited } -MockWith {
            @(
                [PSCustomObject]@{ Id = 1; Username = 'alice';  Name = 'Alice';  AccessLevel = 40 }
                [PSCustomObject]@{ Id = 2; Username = 'bob';    Name = 'Bob';    AccessLevel = 30 }
                [PSCustomObject]@{ Id = 3; Username = 'carol';  Name = 'Carol';  AccessLevel = 30 }
                [PSCustomObject]@{ Id = 4; Username = 'dave';   Name = 'Dave';   AccessLevel = 40 }
                [PSCustomObject]@{ Id = 5; Username = 'eve';    Name = 'Eve';    AccessLevel = 20 }
            )
        }

        # Invited groups on the project
        Mock -CommandName Get-GitlabProjectInvitedGroup -ModuleName $TestModuleName -MockWith {
            @(
                [PSCustomObject]@{ Id = 50; Name = 'invited-team'; FullPath = 'other/invited-team' }
            )
        }

        # Group members - varies by GroupId
        Mock -CommandName Get-GitlabGroupMember -ModuleName $TestModuleName -MockWith {
            param($GroupId)
            switch ($GroupId) {
                50 {
                    # invited group members
                    @(
                        [PSCustomObject]@{ Id = 3; Username = 'carol'; Name = 'Carol'; AccessLevel = 40 }
                    )
                }
                10 {
                    # sub-group direct members
                    @(
                        [PSCustomObject]@{ Id = 1; Username = 'alice'; Name = 'Alice'; AccessLevel = 30 }
                    )
                }
                1 {
                    # top-group members
                    @(
                        [PSCustomObject]@{ Id = 2; Username = 'bob'; Name = 'Bob'; AccessLevel = 20 }
                        [PSCustomObject]@{ Id = 4; Username = 'dave'; Name = 'Dave'; AccessLevel = 40 }
                    )
                }
                default { @() }
            }
        }
    }

    Context "Default behavior" {
        It "Should return all members from members/all" {
            $Result = Get-GitlabProjectMembershipReport -ProjectId 'top-group/sub-group/my-project'

            # alice has Direct(40) + Direct(30) = overlapping
            # bob has Direct(30) + InheritedGroup(20) = overlapping
            # carol has InvitedGroup only = not overlapping
            # dave has InheritedGroup only = not overlapping
            # eve has no identified source = Inherited
            $Result.Count | Should -Be 5
            $Result.Username | Should -Contain 'alice'
            $Result.Username | Should -Contain 'bob'
            $Result.Username | Should -Contain 'carol'
            $Result.Username | Should -Contain 'dave'
            $Result.Username | Should -Contain 'eve'
        }

        It "Should show effective access level as highest across sources" {
            $Result = Get-GitlabProjectMembershipReport -ProjectId 'top-group/sub-group/my-project'

            $Alice = $Result | Where-Object Username -eq 'alice'
            $Alice.EffectiveAccessLevel | Should -Be 40
            $Alice.Sources.Count | Should -Be 2

            $Bob = $Result | Where-Object Username -eq 'bob'
            $Bob.EffectiveAccessLevel | Should -Be 30
            $Bob.Sources.Count | Should -Be 2
        }

        It "Should flag sources that differ from effective access level" {
            $Result = Get-GitlabProjectMembershipReport -ProjectId 'top-group/sub-group/my-project'

            $Alice = $Result | Where-Object Username -eq 'alice'
            $AliceDirectProject = $Alice.Sources | Where-Object { $_.SourceType -eq 'Direct' -and $_.SourcePath -eq 'top-group/sub-group/my-project' }
            $AliceDirectProject.DiffersFromEffective | Should -BeFalse
            $AliceDirectGroup = $Alice.Sources | Where-Object { $_.SourceType -eq 'Direct' -and $_.SourcePath -eq 'top-group/sub-group' }
            $AliceDirectGroup.DiffersFromEffective | Should -BeTrue
            $AliceDirectGroup.AccessLevel | Should -Be 30

            $Bob = $Result | Where-Object Username -eq 'bob'
            $BobDirectProject = $Bob.Sources | Where-Object { $_.SourceType -eq 'Direct' -and $_.SourcePath -eq 'top-group/sub-group/my-project' }
            $BobDirectProject.DiffersFromEffective | Should -BeFalse
            $BobInherited = $Bob.Sources | Where-Object SourceType -eq 'InheritedGroup'
            $BobInherited.DiffersFromEffective | Should -BeTrue
            $BobInherited.AccessLevel | Should -Be 20
        }

        It "Should mark overlapping members correctly" {
            $Result = Get-GitlabProjectMembershipReport -ProjectId 'top-group/sub-group/my-project'
            $Alice = $Result | Where-Object Username -eq 'alice'
            $Alice.IsOverlapping | Should -BeTrue

            $Carol = $Result | Where-Object Username -eq 'carol'
            $Carol.IsOverlapping | Should -BeFalse
            $Carol.Sources.Count | Should -Be 1
            $Carol.Sources[0].SourceType | Should -Be 'InheritedGroupVia'
        }

        It "Should include members with no identified source as Inherited" {
            $Result = Get-GitlabProjectMembershipReport -ProjectId 'top-group/sub-group/my-project'

            $Eve = $Result | Where-Object Username -eq 'eve'
            $Eve.IsOverlapping | Should -BeFalse
            $Eve.Sources.Count | Should -Be 1
            $Eve.Sources[0].SourceType | Should -Be 'Inherited'
            $Eve.EffectiveAccessLevel | Should -Be 20
        }
    }

    Context "Source types" {
        It "Should correctly tag Direct project sources" {
            $Result = Get-GitlabProjectMembershipReport -ProjectId 'top-group/sub-group/my-project'
            $Alice = $Result | Where-Object Username -eq 'alice'
            ($Alice.Sources | Where-Object { $_.SourceType -eq 'Direct' -and $_.SourcePath -eq 'top-group/sub-group/my-project' }).SourcePath | Should -Be 'top-group/sub-group/my-project'
        }

        It "Should correctly tag Direct group sources" {
            $Result = Get-GitlabProjectMembershipReport -ProjectId 'top-group/sub-group/my-project'
            $Alice = $Result | Where-Object Username -eq 'alice'
            ($Alice.Sources | Where-Object { $_.SourceType -eq 'Direct' -and $_.SourcePath -eq 'top-group/sub-group' }).SourcePath | Should -Be 'top-group/sub-group'
        }

        It "Should correctly tag InheritedGroup sources" {
            $Result = Get-GitlabProjectMembershipReport -ProjectId 'top-group/sub-group/my-project'
            $Dave = $Result | Where-Object Username -eq 'dave'
            ($Dave.Sources | Where-Object SourceType -eq 'InheritedGroup').SourcePath | Should -Be 'top-group'
        }

        It "Should correctly tag InheritedGroupVia sources for ancestor-level shares" {
            $Result = Get-GitlabProjectMembershipReport -ProjectId 'top-group/sub-group/my-project'
            $Carol = $Result | Where-Object Username -eq 'carol'
            ($Carol.Sources | Where-Object SourceType -eq 'InheritedGroupVia').SourcePath | Should -Be 'other/invited-team'
            ($Carol.Sources | Where-Object SourceType -eq 'InheritedGroupVia').SourceName | Should -Be 'invited-team (from parent group top-group)'
        }
    }

    Context "Invited group source access level" {
        It "Should cap invited group member access at invitation level" {
            $Result = Get-GitlabProjectMembershipReport -ProjectId 'top-group/sub-group/my-project'

            # carol has AccessLevel 40 in invited group, but invitation level is 30
            # so her source access should be capped at 30
            $Carol = $Result | Where-Object Username -eq 'carol'
            $Carol.EffectiveAccessLevel | Should -Be 30
            $Carol.Sources[0].AccessLevel | Should -Be 30
        }
    }

    Context "HasDifferingAccess" {
        It "Should be true when sources have different access levels" {
            $Result = Get-GitlabProjectMembershipReport -ProjectId 'top-group/sub-group/my-project'
            $Alice = $Result | Where-Object Username -eq 'alice'
            $Alice.HasDifferingAccess | Should -BeTrue
        }
    }

    Context "Sorting" {
        It "Should sort by effective access level descending then username ascending" {
            $Result = Get-GitlabProjectMembershipReport -ProjectId 'top-group/sub-group/my-project'
            $Result[0].EffectiveAccessLevel | Should -BeGreaterOrEqual $Result[-1].EffectiveAccessLevel
        }
    }
}

Describe "Get-GitlabGroupMembershipReport" {

    BeforeEach {
        # Direct group members (no -IncludeInherited)
        Mock -CommandName Get-GitlabGroupMember -ModuleName $TestModuleName -ParameterFilter { -not $IncludeInherited } -MockWith {
            param($GroupId)
            switch ($GroupId) {
                99 {
                    # target group direct members
                    @(
                        [PSCustomObject]@{ Id = 1; Username = 'alice'; Name = 'Alice'; AccessLevel = 40 }
                        [PSCustomObject]@{ Id = 2; Username = 'bob';   Name = 'Bob';   AccessLevel = 30 }
                    )
                }
                50 {
                    # shared group members
                    @(
                        [PSCustomObject]@{ Id = 2; Username = 'bob'; Name = 'Bob'; AccessLevel = 40 }
                    )
                }
                1 {
                    # ancestor (top-group) members
                    @(
                        [PSCustomObject]@{ Id = 1; Username = 'alice'; Name = 'Alice'; AccessLevel = 20 }
                        [PSCustomObject]@{ Id = 3; Username = 'carol'; Name = 'Carol'; AccessLevel = 30 }
                    )
                }
                default { @() }
            }
        }

        # All effective group members (with -IncludeInherited)
        Mock -CommandName Get-GitlabGroupMember -ModuleName $TestModuleName -ParameterFilter { $IncludeInherited } -MockWith {
            param($GroupId)
            switch ($GroupId) {
                50 {
                    # shared group members (including inherited)
                    @(
                        [PSCustomObject]@{ Id = 2; Username = 'bob'; Name = 'Bob'; AccessLevel = 40 }
                    )
                }
                default {
                    # target group effective members
                    @(
                        [PSCustomObject]@{ Id = 1; Username = 'alice'; Name = 'Alice'; AccessLevel = 40 }
                        [PSCustomObject]@{ Id = 2; Username = 'bob';   Name = 'Bob';   AccessLevel = 40 }
                        [PSCustomObject]@{ Id = 3; Username = 'carol'; Name = 'Carol'; AccessLevel = 30 }
                    )
                }
            }
        }

        Mock -CommandName Get-GitlabGroup -ModuleName $TestModuleName -MockWith {
            param($GroupId)
            switch ($GroupId) {
                'top-group/sub-group' {
                    [PSCustomObject]@{ Id = 99; Name = 'sub-group'; FullPath = 'top-group/sub-group'; SharedWithGroups = @(
                        @{ group_id = 50; group_name = 'shared-team'; group_access_level = 30 }
                    ) }
                }
                'top-group' {
                    [PSCustomObject]@{ Id = 1; Name = 'top-group'; FullPath = 'top-group'; SharedWithGroups = @() }
                }
                default {
                    [PSCustomObject]@{ Id = 99; Name = $GroupId; FullPath = $GroupId; SharedWithGroups = @() }
                }
            }
        }
    }

    Context "Default behavior" {
        It "Should return all members" {
            $Result = Get-GitlabGroupMembershipReport -GroupId 'top-group/sub-group'

            # alice: Direct(40) + InheritedGroup(20) = overlapping
            # bob: Direct(30) + InvitedGroup(40 capped to 30) = overlapping
            # carol: InheritedGroup only = not overlapping
            $Result.Count | Should -Be 3
            $Result.Username | Should -Contain 'alice'
            $Result.Username | Should -Contain 'bob'
            $Result.Username | Should -Contain 'carol'
        }
    }

    Context "Effective access level" {
        It "Should compute effective access as highest across sources" {
            $Result = Get-GitlabGroupMembershipReport -GroupId 'top-group/sub-group'

            $Alice = $Result | Where-Object Username -eq 'alice'
            $Alice.EffectiveAccessLevel | Should -Be 40

            $Bob = $Result | Where-Object Username -eq 'bob'
            $Bob.EffectiveAccessLevel | Should -Be 40
        }

        It "Should flag lower sources as differing" {
            $Result = Get-GitlabGroupMembershipReport -GroupId 'top-group/sub-group'

            $Alice = $Result | Where-Object Username -eq 'alice'
            $AliceInherited = $Alice.Sources | Where-Object SourceType -eq 'InheritedGroup'
            $AliceInherited.DiffersFromEffective | Should -BeTrue

            $Bob = $Result | Where-Object Username -eq 'bob'
            $BobDirect = $Bob.Sources | Where-Object SourceType -eq 'Direct'
            $BobDirect.DiffersFromEffective | Should -BeTrue
        }
    }
}
