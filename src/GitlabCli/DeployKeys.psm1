function Get-GitlabDeployKey {
  param(
    [Parameter()]
    [string]
    $DeployKeyId,

    [Parameter()]
    [string]
    $SiteUrl
  )

  $GitlabAPIParams = @{
      Method = 'GET'
      Path   = "deploy_keys"
  }

  if($PSBoundParameters.ContainsKey('DeployKeyId')) {
      $GitlabAPIParams.Path += "/$DeployKeyId"
  }

  Invoke-GitlabApi @GitlabAPIParams -SiteUrl $SiteUrl -Verbose:$VerbosePreference | New-WrapperObject 'Gitlab.DeployKey'
}