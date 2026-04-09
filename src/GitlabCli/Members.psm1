# https://docs.gitlab.com/ee/api/members.html#valid-access-levels
function Get-GitlabMemberAccessLevel {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Position=0)]
        $AccessLevel
    )

    $Levels = [PSCustomObject]@{
        NoAccess = 0
        MinimalAccess = 5
        Guest = 10
        Reporter = 20
        Developer = 30
        Maintainer = 40
        Owner = 50
        Admin = 60
    }

    if ($AccessLevel) {
        if ($Levels.$AccessLevel) {
            return $Levels.$AccessLevel
        }
        if ($Levels.PSObject.Properties | Where-Object { $_.Value -eq $AccessLevel }) {
            return $AccessLevel
        }
        throw "Invalid access level '$AccessLevel'. Valid values are: ($($Levels.PSObject.Properties.Name -join ', '))"
    } else {
        $Levels
    }
}

function Get-GitlabMembershipSortKey {
    [CmdletBinding()]
    [OutputType([array])]
    param(
    )

    @(
        @{
            Expression = 'AccessLevel'
            Descending = $true
        },
        @{
            Expression = 'Username'
            Descending = $false
        }
    )
}

function Get-GitlabGroupMember {
    [CmdletBinding()]
    [OutputType('Gitlab.Member')]
    param (
        [Parameter(Position=0, ValueFromPipelineByPropertyName)]
        [string]
        $GroupId = '.',

        [Parameter()]
        [string]
        $UserId,

        [switch]
        [Parameter()]
        $IncludeInherited,

        [Parameter()]
        [AccessLevel()]
        [string]
        $MinAccessLevel,

        [Parameter()]
        [uint]
        $MaxPages,

        [switch]
        [Parameter()]
        $All,

        [Parameter()]
        [string]
        $SiteUrl
    )

    $MaxPages = Resolve-GitlabMaxPages -MaxPages:$MaxPages -All:$All

    $Group = Get-GitlabGroup -GroupId $GroupId
    if ($UserId) {
        $User = Get-GitlabUser -UserId $UserId
    }

    # https://docs.gitlab.com/api/members/#list-all-members-of-a-group-or-project-including-inherited-and-invited-members
    # https://docs.gitlab.com/ee/api/members.html#list-all-members-of-a-group-or-project
    # https://docs.gitlab.com/api/members/#get-a-member-of-a-group-or-project
    $Members = $IncludeInherited ? "members/all" : "members"
    $Resource = $User ?"groups/$($Group.Id)/$Members/$($User.Id)" : "groups/$($Group.Id)/$Members"

    $Members = Invoke-GitlabApi GET $Resource -MaxPages $MaxPages
    if ($MinAccessLevel) {
        $MinAccessLevelLiteral = Get-GitlabMemberAccessLevel $MinAccessLevel
        $Members = $Members | Where-Object access_level -ge $MinAccessLevelLiteral
    }

    $Members | New-GitlabObject 'Gitlab.Member' |
        Add-Member -PassThru -NotePropertyMembers @{
            GroupId = $Group.Id
        } |
        Sort-Object -Property $(Get-GitlabMembershipSortKey)
}

function Set-GitlabGroupMember {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    [OutputType('Gitlab.Member')]
    param(
        [Parameter()]
        [string]
        $GroupId = '.',

        [Parameter(Position=0, Mandatory)]
        [Alias('Username')]
        [string]
        $UserId,

        [Parameter(Position=1, Mandatory)]
        [AccessLevel()]
        [string]
        $AccessLevel,

        [Parameter(Mandatory)]
        [string]
        $SiteUrl
    )

    $Existing = $Null
    try {
        $Existing = Get-GitlabGroupMember -GroupId $GroupId -UserId $UserId
    }
    catch {
        Write-Verbose "User '$UserId' is not a member of group '$GroupId'"
    }

    if ($Existing) {
        # https://docs.gitlab.com/ee/api/members.html#edit-a-member-of-a-group-or-project
        $Request = @{
            HttpMethod = 'PUT'
            Path       = "groups/$($Existing.GroupId)/members/$($Existing.Id)"
            Body      = @{
                access_level = Get-GitlabMemberAccessLevel $AccessLevel
            }
        }
        if ($PSCmdlet.ShouldProcess("Group '$GroupId'", "update '$($Existing.Name)' membership to '$AccessLevel'")) {
            Invoke-GitlabApi @Request | New-GitlabObject 'Gitlab.Member'
        }
    } else {
        if ($PSCmdlet.ShouldProcess("Group '$GroupId'", "add '$UserId' as '$AccessLevel'")) {
            Add-GitlabGroupMember -GroupId $GroupId -UserId $UserId -AccessLevel $AccessLevel
        }
    }
}

function Add-GitlabGroupMember {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Gitlab.Member')]
    param (
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string]
        $GroupId,

        [Parameter(Mandatory)]
        [string]
        $UserId,

        [Parameter(Mandatory)]
        [AccessLevel()]
        [string]
        $AccessLevel,

        [Parameter()]
        [string]
        $SiteUrl
    )

    $User    = Get-GitlabUser -UserId $UserId
    $GroupId = Resolve-GitlabGroupId $GroupId

    if ($PSCmdlet.ShouldProcess("group $GroupId", "grant $($User.Username) '$AccessLevel'")) {
        # https://docs.gitlab.com/ee/api/members.html#add-a-member-to-a-group-or-project
        $Request = @{
            HttpMethod = 'POST'
            Path       = "groups/$GroupId/members"
            Body = @{
                user_id      = $User.Id
                access_level = Get-GitlabMemberAccessLevel $AccessLevel
            }
        }
        Invoke-GitlabApi @Request |
            New-GitlabObject 'Gitlab.Member'
    }
}

function Remove-GitlabGroupMember {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    [OutputType([void])]
    param (
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string]
        $GroupId,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('Username')]
        [string]
        $UserId,

        [Parameter()]
        [string]
        $SiteUrl
    )

    $User = Get-GitlabUser -UserId $UserId

    if ($PSCmdlet.ShouldProcess($GroupId, "remove $($User.Username)'s group membership")) {
        try {
            # https://docs.gitlab.com/ee/api/members.html#remove-a-member-from-a-group-or-project
            Invoke-GitlabApi DELETE "groups/$(Resolve-GitlabGroupId $GroupId)/members/$($User.Id)" | Out-Null
            Write-Host "Removed $($User.Username) from $GroupId"
        }
        catch {
            Write-Error "Error removing $($User.Username) from $($Group.Name): $_"
        }
    }
}

function Get-GitlabProjectInvitedGroup {
    [CmdletBinding()]
    [OutputType('Gitlab.Group')]
    param (
        [Parameter(Position=0, ValueFromPipelineByPropertyName)]
        [string]
        $ProjectId = '.',

        [Parameter()]
        [string]
        $SiteUrl,

        [Parameter()]
        [uint]
        $MaxPages,

        [Parameter()]
        [switch]
        $All
    )

    $MaxPages = Resolve-GitlabMaxPages -MaxPages:$MaxPages -All:$All

    $ProjectId = Resolve-GitlabProjectId $ProjectId

    # https://docs.gitlab.com/api/projects/#list-all-invited-groups-in-a-project
    Invoke-GitlabApi GET "projects/$ProjectId/invited_groups" -MaxPages $MaxPages |
        New-GitlabObject 'Gitlab.Group'
}

function Get-GitlabProjectMember {
    [CmdletBinding()]
    [OutputType('Gitlab.Member')]
    param (
        [Parameter(ValueFromPipelineByPropertyName)]
        [string]
        $ProjectId = '.',

        [Parameter()]
        [Alias('Username')]
        [string]
        $UserId,

        [switch]
        [Parameter()]
        $IncludeInherited,

        [Parameter()]
        [uint]
        $MaxPages,

        [switch]
        [Parameter()]
        $All,

        [Parameter()]
        [string]
        $SiteUrl
    )

    $MaxPages = Resolve-GitlabMaxPages -MaxPages:$MaxPages -All:$All

    $ProjectId = Resolve-GitlabProjectId $ProjectId

    if ($UserId) {
        $User = Get-GitlabUser -UserId $UserId
    }

    # https://docs.gitlab.com/api/members/#list-all-members-of-a-group-or-project-including-inherited-and-invited-members
    # https://docs.gitlab.com/ee/api/members.html#list-all-members-of-a-group-or-project
    # https://docs.gitlab.com/api/members/#get-a-member-of-a-group-or-project
    $Members = $IncludeInherited ? "members/all" : "members"
    $Resource = $User ? "projects/$ProjectId/$Members/$($User.Id)" : "projects/$ProjectId/$Members"

    Invoke-GitlabApi GET $Resource -MaxPages $MaxPages |
        New-GitlabObject 'Gitlab.Member' |
        Add-Member -PassThru -NotePropertyMembers @{
            ProjectId = $ProjectId
        } |
        Sort-Object -Property $(Get-GitlabMembershipSortKey)
}

function Set-GitlabProjectMember {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    [OutputType('Gitlab.Member')]
    param(
        [Parameter()]
        [string]
        $ProjectId = '.',

        [Parameter(Position=0, Mandatory)]
        [Alias('Username')]
        [string]
        $UserId,

        [Parameter(Position=1, Mandatory)]
        [AccessLevel()]
        [string]
        $AccessLevel,

        [Parameter(Mandatory)]
        [string]
        $SiteUrl
    )

    $Existing = $Null
    try {
        $Existing = Get-GitlabProjectMember -ProjectId @ProjectId -UserId $UserId
    }
    catch {
        Write-Verbose "User '$UserId' is not a member of '$ProjectId'"
    }

    if ($Existing) {
        # https://docs.gitlab.com/ee/api/members.html#edit-a-member-of-a-group-or-project
        $Request = @{
            HttpMethod = 'PUT'
            Path       = "projects/$($Existing.ProjectId)/members/$($Existing.Id)"
            Body      = @{
                access_level = Get-GitlabMemberAccessLevel $AccessLevel
            }
        }
        if ($PSCmdlet.ShouldProcess("Project '$ProjectId'", "update '$($Existing.Name)' membership to '$AccessLevel'")) {
            Invoke-GitlabApi @Request | New-GitlabObject 'Gitlab.Member'
        }
    } else {
        if ($PSCmdlet.ShouldProcess("Project '$ProjectId'", "add '$UserId' as '$AccessLevel'")) {
            Add-GitlabProjectMember -ProjectId $ProjectId -UserId $UserId -AccessLevel $AccessLevel
        }
    }
}

function Add-GitlabProjectMember {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Gitlab.Member')]
    param (
        [Parameter()]
        [string]
        $ProjectId = '.',

        [Parameter(Position=0, Mandatory)]
        [Alias('Username')]
        [string]
        $UserId,

        [Parameter(Position=1, Mandatory)]
        [AccessLevel()]
        [string]
        $AccessLevel,

        [Parameter()]
        [string]
        $SiteUrl
    )

    $User      = Get-GitlabUser -UserId $UserId
    $ProjectId = Resolve-GitlabProjectId $ProjectId

    $Request = @{
        # https://docs.gitlab.com/ee/api/members.html#add-a-member-to-a-group-or-project
        HttpMethod = 'POST'
        Path       = "projects/$ProjectId/members"
        Body       = @{
            user_id      = $User.Id
            access_level = Get-GitlabMemberAccessLevel $AccessLevel
        }
    }

    if ($PSCmdlet.ShouldProcess("project $ProjectId", "grant '$($User.Username)' $AccessLevel membership")) {
        Invoke-GitlabApi @Request | New-GitlabObject 'Gitlab.Member'
    }
}

# https://docs.gitlab.com/ee/api/members.html#remove-a-member-from-a-group-or-project
function Remove-GitlabProjectMember {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    [OutputType([void])]
    param (
        [Parameter(ValueFromPipelineByPropertyName)]
        [string]
        $ProjectId = '.',

        [Parameter(Position=0, Mandatory=$true, ValueFromPipelineByPropertyName)]
        [Alias('Username')]
        [string]
        $UserId,

        [Parameter()]
        [string]
        $SiteUrl
    )

    $User = Get-GitlabUser -UserId $UserId
    $Project = Get-GitlabProject -ProjectId $ProjectId

    if ($PSCmdlet.ShouldProcess("$($Project.PathWithNamespace)", "Remove $($User.Username)'s membership")) {
        if ($Project.Owner.Username -eq $User.Username) {
            Write-Warning "Can't remove owner '$($User.Username)' from '$($Project.PathWithNamespace)'"
        } else {
            try {
                Invoke-GitlabApi DELETE "projects/$($Project.Id)/members/$($User.Id)" | Out-Null
                Write-Host "Removed $($User.Username) from $($Project.Name)"
            }
            catch {
                Write-Error "Error removing $($User.Username) from $($Project.Name): $_"
            }
        }
    }
}

function Get-GitlabUserMembership {
    [CmdletBinding(DefaultParameterSetName='ByUsername')]
    [OutputType('Gitlab.UserMembership')]
    param (
        [Parameter(ParameterSetName='ByUsername', Position=0, Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
        [string]
        $Username,

        [Parameter(ParameterSetName='Me')]
        [switch]
        $Me,

        [Parameter()]
        [string]
        $SiteUrl,

        [Parameter()]
        [uint]
        $MaxPages,

        [Parameter()]
        [switch]
        $All
    )

    $MaxPages = Resolve-GitlabMaxPages -MaxPages:$MaxPages -All:$All

    if ($Me) {
        $Username = $(Get-GitlabUser -Me).Username
    }

    $User = Get-GitlabUser -Username $Username

    # https://docs.gitlab.com/ee/api/users.html#user-memberships-admin-only
    Invoke-GitlabApi GET "users/$($User.Id)/memberships" -MaxPages $MaxPages |
        New-GitlabObject 'Gitlab.UserMembership'
}

function Remove-GitlabUserMembership {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position=0, ValueFromPipelineByPropertyName)]
        [string]
        $Username,

        [Parameter()]
        $Group,

        [Parameter()]
        $Project,

        [Parameter()]
        [switch]
        $RemoveAllAccess,

        [Parameter()]
        [string]
        $SiteUrl
    )

    $User = Get-GitlabUser -Username $Username

    if ($Group) {
        if ($PSCmdlet.ShouldProcess("$($Group -join ',' )", "remove $Username access from groups")) {
            $Group | ForEach-Object {
                $User | Remove-GitlabGroupMember -GroupId $_
            }
        }
    }
    if ($Project) {
        if ($PSCmdlet.ShouldProcess("$($Project -join ',' )", "remove $Username access from project ")) {
            $Project | ForEach-Object {
                $User | Remove-GitlabProjectMember -ProjectId $_
            }
        }
    }
    if ($RemoveAllAccess) {
        $CurrentAccess = $User | Get-GitlabUserMembership
        $Request = @{
            Group   = $CurrentAccess | Where-Object Sourcetype -eq 'Namespace' | Select-Object -ExpandProperty SourceId
            Project = $CurrentAccess | Where-Object Sourcetype -eq 'Project' | Select-Object -ExpandProperty SourceId
        }
        $User | Remove-GitlabUserMembership @Request
    }
}

function Add-GitlabUserMembership {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param (
        [Parameter(Position=0, Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
        [string]
        $Username,

        [Parameter(Position=1, Mandatory=$true)]
        [string]
        $GroupId,

        [Parameter(Position=2, Mandatory=$true)]
        [string]
        [ValidateSet('developer', 'maintainer', 'owner')]
        $AccessLevel,

        [Parameter(Mandatory=$false)]
        [string]
        $SiteUrl
    )

    $GroupId = Resolve-GitlabGroupId $GroupId
    $User = Get-GitlabUser -UserId $Username

    if ($PSCmdlet.ShouldProcess("group $GroupId", "add $($User.Username) to group")) {
        # https://docs.gitlab.com/ee/api/members.html#add-a-member-to-a-group-or-project
        Invoke-GitlabApi POST "groups/$GroupId/members" @{
            user_id = $User.Id
            access_level = Get-GitlabMemberAccessLevel $AccessLevel
        }
    }
}

# https://docs.gitlab.com/ee/api/members.html#edit-a-member-of-a-group-or-project
function Update-GitlabUserMembership {
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName='Group')]
    [OutputType('Gitlab.Member')]
    param (
        [Parameter(Position=0, Mandatory, ValueFromPipelineByPropertyName)]
        [string]
        $Username,

        [Parameter(ParameterSetName='Group', Mandatory, ValueFromPipelineByPropertyName)]
        [string]
        $GroupId,

        [Parameter(ParameterSetName='Project', Mandatory, ValueFromPipelineByPropertyName)]
        [string]
        $ProjectId,

        [Parameter(Mandatory)]
        [string]
        [ValidateSet('developer', 'maintainer', 'owner')]
        $AccessLevel,

        [Parameter()]
        [string]
        $SiteUrl
    )

    $User = Get-GitlabUser -UserId $Username

    $Rows = @()

    $AccessLevelLiteral = Get-GitlabMemberAccessLevel $AccessLevel

    switch ($PSCmdlet.ParameterSetName) {
        Group {
            $GroupId = Resolve-GitlabGroupId $GroupId
            if ($PSCmdLet.ShouldProcess("group $GroupId", "update $($User.Username)'s membership access level to '$AccessLevel' on group")) {
                $Rows = Invoke-GitlabApi PUT "groups/$GroupId/members/$($User.Id)" @{
                    access_level = $AccessLevelLiteral
                }
            }
         }
        Project {
            $Project = Get-GitlabProject -ProjectId $ProjectId
            if ($PSCmdLet.ShouldProcess($Project.PathWithNamespace, "update $($User.Username)'s membership access level to '$AccessLevel' on project")) {
                $Rows = Invoke-GitlabApi PUT "projects/$($Project.Id)/members/$($User.Id)" @{
                    access_level = $AccessLevelLiteral
                }
            }
        }
    }

    $Rows | New-GitlabObject 'Gitlab.Member'
}

function Get-GitlabGroupAncestor {
    [CmdletBinding()]
    [OutputType('Gitlab.Group')]
    param (
        [Parameter(Mandatory)]
        [string]
        $FullPath
    )

    $Parts = $FullPath -split '/'
    if ($Parts.Count -le 1) {
        return
    }

    for ($i = $Parts.Count - 1; $i -ge 1; $i--) {
        $AncestorPath = ($Parts[0..($i - 1)]) -join '/'
        Get-GitlabGroup -GroupId $AncestorPath
    }
}

function Resolve-AccessLevelName {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [int]
        $AccessLevel
    )

    $Levels = Get-GitlabMemberAccessLevel
    $Match = $Levels.psobject.Properties | Where-Object Value -eq $AccessLevel | Select-Object -ExpandProperty Name
    if ($Match) { $Match } else { $AccessLevel.ToString() }
}

function Build-MembershipSourceReport {
    [CmdletBinding()]
    [OutputType('Gitlab.MembershipReport')]
    param (
        [Parameter()]
        [array]
        $Entries
    )

    if (-not $Entries -or $Entries.Count -eq 0) {
        return
    }

    $Grouped = $Entries | Group-Object -Property UserId

    foreach ($UserGroup in $Grouped) {
        $Sources = $UserGroup.Group
        # Use the effective access level from members/all if provided, otherwise compute max
        $EffectiveAccessLevel = if ($null -ne $Sources[0].EffectiveAccessLevel) {
            $Sources[0].EffectiveAccessLevel
        } else {
            ($Sources | Measure-Object -Property AccessLevel -Maximum).Maximum
        }
        $EffectiveAccessLevelName = Resolve-AccessLevelName $EffectiveAccessLevel

        $SourceDetails = $Sources | ForEach-Object {
            $SourceAccessLevelName = Resolve-AccessLevelName $_.AccessLevel
            [PSCustomObject]@{
                SourceType           = $_.SourceType
                SourceName           = $_.SourceName
                SourcePath           = $_.SourcePath
                AccessLevel          = $_.AccessLevel
                AccessLevelName      = $SourceAccessLevelName
                DiffersFromEffective = $_.AccessLevel -ne $EffectiveAccessLevel
            }
        }

        $Report = [PSCustomObject]@{
            PSTypeName            = 'Gitlab.MembershipReport'
            UserId                = [int]$UserGroup.Name
            Username              = $Sources[0].Username
            Name                  = $Sources[0].Name
            EffectiveAccessLevel  = $EffectiveAccessLevel
            EffectiveAccessLevelName = $EffectiveAccessLevelName
            Sources               = $SourceDetails
            SourceCount           = $SourceDetails.Count
            IsOverlapping         = $SourceDetails.Count -gt 1
            HasDifferingAccess    = ($SourceDetails | Where-Object DiffersFromEffective).Count -gt 0
        }
        $Report
    }
}

function Get-GitlabProjectMembershipReport {
    [CmdletBinding()]
    [OutputType('Gitlab.MembershipReport')]
    param (
        [Parameter(Position=0, ValueFromPipelineByPropertyName)]
        [string]
        $ProjectId = '.',

        [Parameter()]
        [string]
        $SiteUrl
    )

    $Project = Get-GitlabProject -ProjectId $ProjectId

    # Build a map of invited group ID -> invitation access level
    # from shared_with_groups on the project and each group in the hierarchy
    $InvitationAccessMap = @{} # GroupId -> max invitation access level across all sharing points
    $InvitationSourceMap = @{} # GroupId -> @{ ViaType; ViaPath } tracking where the group was shared

    # Project-level shares
    if ($Project.SharedWithGroups) {
        foreach ($swg in $Project.SharedWithGroups) {
            $gid = $swg.group_id
            $level = $swg.group_access_level
            if (-not $InvitationAccessMap.ContainsKey($gid) -or $level -gt $InvitationAccessMap[$gid]) {
                $InvitationAccessMap[$gid] = $level
            }
            $InvitationSourceMap[$gid] = @{
                ViaType = 'InvitedGroup'
                ViaPath = $Project.PathWithNamespace
            }
        }
    }

    # Collect the universe of known sources
    # 1. Direct project members
    $DirectProjectMembers = Get-GitlabProjectMember -ProjectId $Project.Id -All
    $DirectProjectIndex = @{}
    foreach ($m in $DirectProjectMembers) {
        $DirectProjectIndex[$m.Id] = $m
    }

    # 2. Project's group hierarchy (direct parent + ancestors)
    $GroupPath = ($Project.PathWithNamespace -split '/')[0..($Project.PathWithNamespace.Split('/').Count - 2)] -join '/'
    $GroupSources = @{} # GroupId -> { Group, SourceType, Members }
    if ($GroupPath) {
        $Group = Get-GitlabGroup -GroupId $GroupPath
        $GroupMembers = Get-GitlabGroupMember -GroupId $Group.Id -All
        $GroupSources[$Group.Id] = @{
            Group      = $Group
            SourceType = 'Direct'
            Members    = @{}
        }
        foreach ($m in $GroupMembers) {
            $GroupSources[$Group.Id].Members[$m.Id] = $m
        }

        # Group-level shares (groups shared with this group)
        if ($Group.SharedWithGroups) {
            foreach ($swg in $Group.SharedWithGroups) {
                $gid = $swg.group_id
                $level = $swg.group_access_level
                if (-not $InvitationAccessMap.ContainsKey($gid) -or $level -gt $InvitationAccessMap[$gid]) {
                    $InvitationAccessMap[$gid] = $level
                }
                if (-not $InvitationSourceMap.ContainsKey($gid)) {
                    $InvitationSourceMap[$gid] = @{
                        ViaType = 'InheritedGroupVia'
                        ViaPath = $Group.FullPath
                    }
                }
            }
        }

        $Ancestors = Get-GitlabGroupAncestor -FullPath $Group.FullPath
        foreach ($Ancestor in $Ancestors) {
            $AncestorMembers = Get-GitlabGroupMember -GroupId $Ancestor.Id -All
            $GroupSources[$Ancestor.Id] = @{
                Group      = $Ancestor
                SourceType = 'InheritedGroup'
                Members    = @{}
            }
            foreach ($m in $AncestorMembers) {
                $GroupSources[$Ancestor.Id].Members[$m.Id] = $m
            }

            # Ancestor-level shares
            if ($Ancestor.SharedWithGroups) {
                foreach ($swg in $Ancestor.SharedWithGroups) {
                    $gid = $swg.group_id
                    $level = $swg.group_access_level
                    if (-not $InvitationAccessMap.ContainsKey($gid) -or $level -gt $InvitationAccessMap[$gid]) {
                        $InvitationAccessMap[$gid] = $level
                    }
                    if (-not $InvitationSourceMap.ContainsKey($gid)) {
                        $InvitationSourceMap[$gid] = @{
                            ViaType = 'InheritedGroupVia'
                            ViaPath = $Ancestor.FullPath
                        }
                    }
                }
            }
        }
    }

    # 3. Invited/shared groups (project-level + group-level shares)
    $InvitedGroupSources = @{} # GroupId -> { Group, Members, InvitationAccessLevel }

    # Collect all shared group IDs from the InvitationAccessMap (populated from
    # SharedWithGroups on the project and each group in the hierarchy)
    $SharedGroupIds = @($InvitationAccessMap.Keys)

    # Also fetch project-level invited groups (in case they aren't in SharedWithGroups)
    $ProjectInvitedGroups = Get-GitlabProjectInvitedGroup -ProjectId $Project.Id -All
    foreach ($ig in $ProjectInvitedGroups) {
        if ($SharedGroupIds -notcontains $ig.Id) {
            $SharedGroupIds += $ig.Id
        }
        if (-not $InvitationSourceMap.ContainsKey($ig.Id)) {
            $InvitationSourceMap[$ig.Id] = @{
                ViaType = 'InvitedGroup'
                ViaPath = $Project.PathWithNamespace
            }
        }
    }

    foreach ($gid in $SharedGroupIds) {
        # Skip groups already in the hierarchy (they are accounted for as Direct/InheritedGroup)
        if ($GroupSources.ContainsKey($gid)) {
            continue
        }
        try {
            $SharedGroup = Get-GitlabGroup -GroupId $gid
        } catch {
            continue
        }
        # Use -IncludeInherited to get all effective members of the shared group
        $InvitedMembers = Get-GitlabGroupMember -GroupId $gid -IncludeInherited -All
        $InvitationAccessLevel = if ($InvitationAccessMap.ContainsKey($gid)) { $InvitationAccessMap[$gid] } else { $null }
        $InvitationSource = if ($InvitationSourceMap.ContainsKey($gid)) { $InvitationSourceMap[$gid] } else { @{ ViaType = 'InvitedGroup'; ViaPath = '' } }
        $InvitedGroupSources[$gid] = @{
            Group                 = $SharedGroup
            Members               = @{}
            InvitationAccessLevel = $InvitationAccessLevel
            InvitationSource      = $InvitationSource
        }
        foreach ($m in $InvitedMembers) {
            $InvitedGroupSources[$gid].Members[$m.Id] = $m
        }
    }

    # Get all effective members (includes inherited + invited)
    $AllEffectiveMembers = Get-GitlabProjectMember -ProjectId $Project.Id -IncludeInherited -All
    $EffectiveIndex = @{} # UserId -> effective access level from members/all
    foreach ($em in $AllEffectiveMembers) {
        $EffectiveIndex[$em.Id] = $em.AccessLevel
    }

    $Entries = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($em in $AllEffectiveMembers) {
        $FoundSources = @()

        # Check direct project membership
        if ($DirectProjectIndex.ContainsKey($em.Id)) {
            $FoundSources += [PSCustomObject]@{
                SourceType = 'Direct'
                SourceName = $Project.Name
                SourcePath = $Project.PathWithNamespace
                AccessLevel = $DirectProjectIndex[$em.Id].AccessLevel
            }
        }

        # Check group hierarchy
        foreach ($gs in $GroupSources.Values) {
            if ($gs.Members.ContainsKey($em.Id)) {
                $FoundSources += [PSCustomObject]@{
                    SourceType = $gs.SourceType
                    SourceName = $gs.Group.Name
                    SourcePath = $gs.Group.FullPath
                    AccessLevel = $gs.Members[$em.Id].AccessLevel
                }
            }
        }

        # Check invited groups (cap access at invitation level)
        foreach ($igs in $InvitedGroupSources.Values) {
            if ($igs.Members.ContainsKey($em.Id)) {
                $MemberAccessLevel = $igs.Members[$em.Id].AccessLevel
                if ($null -ne $igs.InvitationAccessLevel) {
                    $MemberAccessLevel = [Math]::Min($MemberAccessLevel, $igs.InvitationAccessLevel)
                }
                $SourceType = $igs.InvitationSource.ViaType
                $SourceName = if ($SourceType -eq 'InheritedGroupVia') {
                    "$($igs.Group.Name) (from parent group $($igs.InvitationSource.ViaPath))"
                } else {
                    $igs.Group.Name
                }
                $FoundSources += [PSCustomObject]@{
                    SourceType  = $SourceType
                    SourceName  = $SourceName
                    SourcePath  = $igs.Group.FullPath
                    AccessLevel = $MemberAccessLevel
                }
            }
        }

        if ($FoundSources.Count -eq 0) {
            $FoundSources += [PSCustomObject]@{
                SourceType  = 'Inherited'
                SourceName  = ''
                SourcePath  = ''
                AccessLevel = $EffectiveIndex[$em.Id]
            }
        }

        foreach ($src in $FoundSources) {
            $Entries.Add([PSCustomObject]@{
                UserId               = $em.Id
                Username             = $em.Username
                Name                 = $em.Name
                AccessLevel          = $src.AccessLevel
                EffectiveAccessLevel = $EffectiveIndex[$em.Id]
                SourceType           = $src.SourceType
                SourceName           = $src.SourceName
                SourcePath           = $src.SourcePath
            })
        }
    }

    $Report = Build-MembershipSourceReport -Entries $Entries

    $Report | Sort-Object -Property @(
        @{ Expression = 'EffectiveAccessLevel'; Descending = $true },
        @{ Expression = 'Username'; Descending = $false }
    )
}

function Get-GitlabGroupMembershipReport {
    [CmdletBinding()]
    [OutputType('Gitlab.MembershipReport')]
    param (
        [Parameter(Position=0, ValueFromPipelineByPropertyName)]
        [string]
        $GroupId = '.',

        [Parameter()]
        [string]
        $SiteUrl
    )

    $Group = Get-GitlabGroup -GroupId $GroupId

    # Build invitation access level map from shared_with_groups
    $InvitationAccessMap = @{}
    $InvitationSourceMap = @{}
    if ($Group.SharedWithGroups) {
        foreach ($swg in $Group.SharedWithGroups) {
            $gid = $swg.group_id
            $level = $swg.group_access_level
            if (-not $InvitationAccessMap.ContainsKey($gid) -or $level -gt $InvitationAccessMap[$gid]) {
                $InvitationAccessMap[$gid] = $level
            }
            $InvitationSourceMap[$gid] = @{
                ViaType = 'InvitedGroup'
                ViaPath = $Group.FullPath
            }
        }
    }

    # Collect the universe of known sources
    # 1. Direct group members
    $DirectMembers = Get-GitlabGroupMember -GroupId $Group.Id -All
    $DirectIndex = @{}
    foreach ($m in $DirectMembers) {
        $DirectIndex[$m.Id] = $m
    }

    # 2. Shared/invited groups
    $InvitedGroupSources = @{}
    $SharedGroupIds = @($InvitationAccessMap.Keys)

    # 3. Ancestor groups
    $AncestorSources = @{}
    $Ancestors = Get-GitlabGroupAncestor -FullPath $Group.FullPath
    foreach ($Ancestor in $Ancestors) {
        $AncestorMembers = Get-GitlabGroupMember -GroupId $Ancestor.Id -All
        $AncestorSources[$Ancestor.Id] = @{
            Group   = $Ancestor
            Members = @{}
        }
        foreach ($m in $AncestorMembers) {
            $AncestorSources[$Ancestor.Id].Members[$m.Id] = $m
        }

        # Ancestor-level shares
        if ($Ancestor.SharedWithGroups) {
            foreach ($swg in $Ancestor.SharedWithGroups) {
                $gid = $swg.group_id
                $level = $swg.group_access_level
                if (-not $InvitationAccessMap.ContainsKey($gid) -or $level -gt $InvitationAccessMap[$gid]) {
                    $InvitationAccessMap[$gid] = $level
                }
                if (-not $InvitationSourceMap.ContainsKey($gid)) {
                    $InvitationSourceMap[$gid] = @{
                        ViaType = 'InheritedGroupVia'
                        ViaPath = $Ancestor.FullPath
                    }
                }
            }
        }

    }

    # Fetch members for all shared groups
    foreach ($gid in $SharedGroupIds) {
        # Skip groups already in the hierarchy
        if ($AncestorSources.ContainsKey($gid)) {
            continue
        }
        try {
            $SharedGroup = Get-GitlabGroup -GroupId $gid
        } catch {
            continue
        }
        # Use -IncludeInherited to get all effective members of the shared group
        $SharedGroupMembers = Get-GitlabGroupMember -GroupId $gid -IncludeInherited -All
        $InvitationAccessLevel = if ($InvitationAccessMap.ContainsKey($gid)) { $InvitationAccessMap[$gid] } else { $null }
        $InvitationSource = if ($InvitationSourceMap.ContainsKey($gid)) { $InvitationSourceMap[$gid] } else { @{ ViaType = 'InvitedGroup'; ViaPath = '' } }
        $InvitedGroupSources[$gid] = @{
            Group                 = $SharedGroup
            Members               = @{}
            InvitationAccessLevel = $InvitationAccessLevel
            InvitationSource      = $InvitationSource
        }
        foreach ($m in $SharedGroupMembers) {
            $InvitedGroupSources[$gid].Members[$m.Id] = $m
        }
    }

    # Get all effective members (includes inherited + invited)
    $AllEffectiveMembers = Get-GitlabGroupMember -GroupId $Group.Id -IncludeInherited -All
    $EffectiveIndex = @{}
    foreach ($em in $AllEffectiveMembers) {
        $EffectiveIndex[$em.Id] = $em.AccessLevel
    }

    $Entries = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($em in $AllEffectiveMembers) {
        $FoundSources = @()

        # Check direct group membership
        if ($DirectIndex.ContainsKey($em.Id)) {
            $FoundSources += [PSCustomObject]@{
                SourceType  = 'Direct'
                SourceName  = $Group.Name
                SourcePath  = $Group.FullPath
                AccessLevel = $DirectIndex[$em.Id].AccessLevel
            }
        }

        # Check invited groups (cap access at invitation level)
        foreach ($igs in $InvitedGroupSources.Values) {
            if ($igs.Members.ContainsKey($em.Id)) {
                $MemberAccessLevel = $igs.Members[$em.Id].AccessLevel
                if ($null -ne $igs.InvitationAccessLevel) {
                    $MemberAccessLevel = [Math]::Min($MemberAccessLevel, $igs.InvitationAccessLevel)
                }
                $SourceType = $igs.InvitationSource.ViaType
                $SourceName = if ($SourceType -eq 'InheritedGroupVia') {
                    "$($igs.Group.Name) (via $($igs.InvitationSource.ViaPath))"
                } else {
                    $igs.Group.Name
                }
                $FoundSources += [PSCustomObject]@{
                    SourceType  = $SourceType
                    SourceName  = $SourceName
                    SourcePath  = $igs.Group.FullPath
                    AccessLevel = $MemberAccessLevel
                }
            }
        }

        # Check ancestor groups
        foreach ($as in $AncestorSources.Values) {
            if ($as.Members.ContainsKey($em.Id)) {
                $FoundSources += [PSCustomObject]@{
                    SourceType  = 'InheritedGroup'
                    SourceName  = $as.Group.Name
                    SourcePath  = $as.Group.FullPath
                    AccessLevel = $as.Members[$em.Id].AccessLevel
                }
            }
        }

        if ($FoundSources.Count -eq 0) {
            $FoundSources += [PSCustomObject]@{
                SourceType  = 'Inherited'
                SourceName  = ''
                SourcePath  = ''
                AccessLevel = $EffectiveIndex[$em.Id]
            }
        }

        foreach ($src in $FoundSources) {
            $Entries.Add([PSCustomObject]@{
                UserId               = $em.Id
                Username             = $em.Username
                Name                 = $em.Name
                AccessLevel          = $src.AccessLevel
                EffectiveAccessLevel = $EffectiveIndex[$em.Id]
                SourceType           = $src.SourceType
                SourceName           = $src.SourceName
                SourcePath           = $src.SourcePath
            })
        }
    }

    $Report = Build-MembershipSourceReport -Entries $Entries

    $Report | Sort-Object -Property @(
        @{ Expression = 'EffectiveAccessLevel'; Descending = $true },
        @{ Expression = 'Username'; Descending = $false }
    )
}
