# https://docs.gitlab.com/ee/api/runners.html

function Get-GitlabRunner {
    [CmdletBinding(DefaultParameterSetName='ListAll')]
    param (
        [Parameter(Mandatory, Position=0, ParameterSetName='RunnerId')]
        [string]
        $RunnerId,

        [Parameter(ParameterSetName='ListAll')]
        [ValidateSet('instance_type', 'group_type', 'project_type')]
        [string]
        $Type,

        [Parameter(ParameterSetName='ListAll')]
        [ValidateSet('active', 'paused', 'online', 'offline')]
        [string]
        $Status,

        [Parameter(ParameterSetName='ListAll')]
        [string []]
        $Tags,

        [switch]
        [Parameter()]
        $FetchDetails,

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

    $Params = @{
        HttpMethod = 'GET'
        Query      = @{}
        MaxPages   = Get-GitlabMaxPages -MaxPages:$MaxPages -All:$All
        SiteUrl    = $SiteUrl
    }

    switch ($PSCmdlet.ParameterSetName) {
        # https://docs.gitlab.com/ee/api/runners.html#get-runners-details
        RunnerId { 
            $Params.Path = "runners/$RunnerId"
        }
        # https://docs.gitlab.com/ee/api/runners.html#list-all-runners
        ListAll {
            $Params.Path = 'runners/all'
            $Params.Query.type = $Type
            $Params.Query.status = $Status
            $Params.Query.tag_list = $Tags -join ','
        }
        Default { throw "Unsupported parameter combination" }
    }

    $Runners = Invoke-GitlabApi @Params | New-WrapperObject 'Gitlab.Runner'
    if ($FetchDetails) {
        $RunnerCount = $Runners.Count
        $i = 0
        $Runners | ForEach-Object {
            $PercentComplete = $($i++ / $RunnerCount * 100)
            Write-Progress "Fetching runner details ($i of $RunnerCount)" -PercentComplete $PercentComplete
            Get-GitlabRunner -RunnerId $_.Id -SiteUrl $SiteUrl
        }
    }
    $Runners
}

function Get-GitlabRunnerJob {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, Position=0, ValueFromPipelineByPropertyName)]
        [string]
        $RunnerId,

        [Parameter()]
        [uint]
        $MaxPages,

        [Parameter()]
        [switch]
        $All,

        [Parameter()]
        [string]
        $SiteUrl
    )

    # https://docs.gitlab.com/ee/api/runners.html#list-runners-jobs
    $Params = @{
        HttpMethod = 'GET'
        Path       = "runners/$RunnerId/jobs"
        MaxPages   = Get-GitlabMaxPages -MaxPages:$MaxPages -All:$All
        SiteUrl    = $SiteUrl
    }

    Invoke-GitlabApi @Params | New-WrapperObject 'Gitlab.RunnerJob'
}

function Update-GitlabRunner {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory, Position=0, ValueFromPipelineByPropertyName)]
        [string]
        $RunnerId,

        [Parameter()]
        [string]
        $Id,

        [Parameter()]
        [string]
        $Description,

        [Parameter()]
        [object]
        [ValidateSet($null, 'true', 'false')]
        $Active,

        [Parameter()]
        [string]
        $Tags,

        [Parameter()]
        [object]
        [ValidateSet($null, 'true', 'false')]
        $RunUntaggedJobs,

        [Parameter()]
        [object]
        [ValidateSet($null, 'true', 'false')]
        $Locked,

        [Parameter()]
        [string]
        [ValidateSet('not_protected', 'ref_protected')]
        $AccessLevel,

        [Parameter()]
        [uint]
        $MaximumTimeoutSeconds,

        [Parameter()]
        [string]
        $SiteUrl
    )

    $Params = @{
        HttpMethod = 'PUT'
        Path       = "runners/$RunnerId"
        Query      = @{}
        SiteUrl    = $SiteUrl
    }
    if ($Description) {
        $Params.Query.description = $Description
    }
    if ($Tags) {
        $Params.Query.tag_list = $Tags
    }
    if ($AccessLevel) {
        $Params.Query.access_level = $Tags
    }
    if ($MaximumTimeoutSeconds) {
        if ($MaximumTimeoutSeconds -lt 600) {
            throw "maximum_timeout must be >= 600"
        }
        if ($MaximumTimeoutSeconds -gt [int]::MaxValue) {
            throw "maximum_timeout must be <= $([int]::MaxValue)"
        }
        $Params.Query.maximum_timeout = $MaximumTimeoutSeconds
    }

    if ($Active) {
        $Params.Query.active = $Active
    }
    if ($RunUntaggedJobs) {
        $Params.Query.run_untagged = $RunUntaggedJobs
    }
    if ($Locked) {
        $Params.Query.locked = $Locked
    }

    if ($PSCmdlet.ShouldProcess("$($Params.Path)", "update ($($Params.Query | ConvertTo-Json))")) {
        # https://docs.gitlab.com/ee/api/runners.html#update-runners-details
        Invoke-GitlabApi @Params | New-WrapperObject 'Gitlab.Runner'
    }
}
function Suspend-GitlabRunner {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory, Position=0, ValueFromPipelineByPropertyName)]
        [string]
        $RunnerId,

        [Parameter()]
        [string]
        $SiteUrl
    )

    Update-GitlabRunner $RunnerId -Active $false -SiteUrl $SiteUrl -WhatIf:$WhatIfPreference
}

function Resume-GitlabRunner {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory, Position=0, ValueFromPipelineByPropertyName)]
        [string]
        $RunnerId,

        [Parameter()]
        [string]
        $SiteUrl
    )

    Update-GitlabRunner $RunnerId -Active $true -SiteUrl $SiteUrl -WhatIf:$WhatIfPreference
}

function Remove-GitlabRunner {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory, Position=0, ValueFromPipelineByPropertyName)]
        [Alias('Id')]
        [string]
        $RunnerId,

        [Parameter()]
        [string]
        $SiteUrl
    )

    $Runner = Get-GitlabRunner -RunnerId $RunnerId

    if ($PSCmdlet.ShouldProcess("runner $($Runner.Id) [$($Runner.Status)] ($($Runner.Summary))", "delete")) {
        # https://docs.gitlab.com/ee/api/runners.html#delete-a-runner-by-id
        if (Invoke-GitlabApi DELETE "runners/$($Runner.Id)") {
            Write-Host "Runner $($Runner.Id) deleted"
        }
    }
}
