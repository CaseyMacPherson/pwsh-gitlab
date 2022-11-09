# https://docs.gitlab.com/ee/api/commits.html#list-repository-commits
function Get-GitlabCommit {
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipelineByPropertyName)]
        [string]
        $ProjectId = '.',

        [Alias('Until')]
        [Parameter()]
        [ValidateScript({ValidateGitlabDateFormat $_})]
        [string]
        $Before,

        [Alias('Since')]
        [Parameter()]
        [ValidateScript({ValidateGitlabDateFormat $_})]
        [string]
        $After,

        [Alias('Branch')]
        [Parameter()]
        [string]
        $Ref,

        [Parameter()]
        [string]
        $Sha,

        [Parameter()]
        [uint]
        $MaxPages = 1,

        [Parameter()]
        [string]
        $SiteUrl
    )

    $Project = Get-GitlabProject $ProjectId

    $Url = "projects/$($Project.Id)/repository/commits"
    $Query = @{}
    if ($Before) {
        $Query.until = $Before
    }
    if ($After) {
        $Query.since = $After
    }
    if ($Ref) {
        $Query.ref_name = $Ref
    }
    if ($Sha) {
        $Url += "/$Sha"
    }

    Invoke-GitlabApi GET $Url -Query $Query -MaxPages $MaxPages -SiteUrl $SiteUrl | New-WrapperObject 'Gitlab.Commit'
}
