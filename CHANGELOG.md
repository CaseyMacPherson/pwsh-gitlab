# Changelog

All notable changes to GitlabCli are recorded here, newest first.

## [Unreleased]

### Changes
- `Get-GitlabBranch` reports a branch's tip-commit date as `UpdatedAt`, the name every other type uses for the same thing. Scripts reading `LastUpdated` need updating.
- Listings come back sorted without each cmdlet arranging it. A type that defines its own `SortKey` (issues, merge requests) is sorted by it; anything else with a last-updated timestamp comes back most recent first. Passing `-Sort` or `-OrderBy` leaves the server's ordering intact.

## [1.172.3] - 2026-09-12

### Bug Fixes
- Paged requests keep their authentication past the first page. On PowerShell 7.6, anything using `-All` over more than one page of results could come back truncated or fail with a 401: https://github.com/chris-peterson/pwsh-gitlab/pull/167
- Setting `$env:GITLAB_URL` without `$env:GITLAB_ACCESS_TOKEN` now names the missing token instead of failing with an unexplained "Could not resolve GitLab site": https://github.com/chris-peterson/pwsh-gitlab/pull/159

## [1.172.2] - 2026-06-29

### Bug Fixes
- https://github.com/chris-peterson/pwsh-gitlab/pull/158 - Thanks @rnebular
