# https://docs.gitlab.com/ee/api/pipelines.html#list-project-pipelines
function Get-GitlabPipeline {

    [Alias('pipeline')]
    [Alias('pipelines')]
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipelineByPropertyName)]
        [string]
        $ProjectId='.',

        [Parameter()]
        [Alias('Branch')]
        [string]
        $Ref,

        [Parameter(Position=0)]
        [string]
        $PipelineId,

        [Parameter()]
        [string]
        $Url,

        [Parameter()]
        [ValidateSet('running', 'pending', 'finished', 'branches', 'tags')]
        [string]
        $Scope,

        [Parameter()]
        [ValidateSet('created', 'waiting_for_resource', 'preparing', 'pending', 'running', 'success', 'failed', 'canceled', 'skipped', 'manual', 'scheduled')]
        [string]
        $Status,

        [Parameter()]
        [ValidateSet('push', 'web', 'trigger', 'schedule', 'api', 'external', 'pipeline', 'chat', 'webide', 'merge_request_event', 'external_pull_request_event', 'parent_pipeline', 'ondemand_dast_scan', 'ondemand_dast_validation')]
        [string]
        $Source,

        [Parameter()]
        [string]
        $Username,

        [Parameter()]
        [switch]
        $Mine,

        [Parameter()]
        [switch]
        $Latest,

        [Parameter()]
        [switch]
        $IncludeTestReport,

        [Parameter()]
        [Alias('FetchUpstream')]
        [switch]
        $FetchDownstream,

        [Parameter()]
        [int]
        $MaxPages = 1,

        [Parameter()]
        [string]
        $SiteUrl
    )

    $GitlabApiParameters = @{
        HttpMethod = 'GET'
        SiteUrl    = $SiteUrl
    }

    if ($Url) {
        $Resource   = $Url | Get-GitlabResourceFromUrl
        $ProjectId  = $Resource.ProjectId
        $PipelineId = $Resource.ResourceId
    } else {
        $Query = @{}

        if($Ref) {
            if($Ref -eq '.') {
                $LocalContext = Get-LocalGitContext
                $Ref = $LocalContext.Branch
            }
            $Query.ref = $Ref
        }
        if ($Scope) {
            $Query.scope = $Scope
        }
        if ($Status) {
            $Query.status = $Status
        }
        if ($Source) {
            $Query.source = $Source
        }
        if ($Mine) {
            $Query.username = $(Get-GitlabUser -Me).Username
        } elseif ($Username) {
            $Query.username = $Username
        }

        $GitlabApiParameters.Query = $Query
        $GitlabApiParameters.MaxPages = $MaxPages
    }

    $Project = Get-GitlabProject -ProjectId $ProjectId

    $GitlabApiParameters.Path = if ($PipelineId) {
        "projects/$($Project.Id)/pipelines/$PipelineId"
    } else {
        "projects/$($Project.Id)/pipelines"
    }

    $Pipelines = Invoke-GitlabApi @GitlabApiParameters | New-WrapperObject 'Gitlab.Pipeline'

    if ($IncludeTestReport) {
        $Pipelines | ForEach-Object {
            try {
                $TestReport = Invoke-GitlabApi GET "projects/$($_.ProjectId)/pipelines/$($_.Id)/test_report" -SiteUrl $SiteUrl | New-WrapperObject 'Gitlab.TestReport'
            }
            catch {
                $TestReport = $Null
            }

            $_ | Add-Member -MemberType 'NoteProperty' -Name 'TestReport' -Value $TestReport
        }
    }

    if ($Latest) {
        $Pipelines = $Pipelines | Sort-Object -Descending Id | Select-Object -First 1
    }

    if ($FetchDownstream) {
        # the API doesn't currently expose this, so working around using GraphQL
        # https://gitlab.com/gitlab-org/gitlab/-/issues/21495
        foreach ($Pipeline in $Pipelines) {

            # NOTE: have to stitch this together because of https://gitlab.com/gitlab-org/gitlab/-/issues/350686
            $Bridges = Get-GitlabPipelineBridge -ProjectId $Project.Id  -PipelineId $Pipeline.Id -SiteUrl $SiteUrl

            # NOTE: once 14.6 is more available, iid is included in pipeline APIs which would make this simpler (not have to search by sha)
            $Query = @"
            { project(fullPath: "$($Project.PathWithNamespace)") { id pipelines (sha: "$($Pipeline.Sha)") { nodes { id downstream { nodes { id project { fullPath } } } upstream { id project { fullPath } } } } } }
"@
            $Nodes = $(Invoke-GitlabGraphQL -Query $Query -SiteUrl $SiteUrl).Project.pipelines.nodes
            $MatchingResult = $Nodes | Where-Object id -Match "gid://gitlab/Ci::Pipeline/$($Pipeline.Id)"
            if ($MatchingResult.downstream) {
                $DownstreamList = $MatchingResult.downstream.nodes | ForEach-Object {
                    if ($_.id -match "/(?<PipelineId>\d+)") {
                        try {
                            Get-GitlabPipeline -ProjectId $_.project.fullPath -PipelineId $Matches.PipelineId -SiteUrl $SiteUrl
                        }
                        catch {
                            $Null
                        }
                    }
                } | Where-Object { $_ }
                $DownstreamMap = @{}

                foreach ($Downstream in $DownstreamList) {
                    $MatchingBridge = $Bridges | Where-Object { $_.DownstreamPipeline.id -eq $Downstream.Id }
                    $DownstreamMap[$MatchingBridge.Name] = $Downstream
                }
                $Pipeline | Add-Member -MemberType 'NoteProperty' -Name 'Downstream' -Value $DownstreamMap
            }
            if ($MatchingResult.upstream.id -match '\/(?<PipelineId>\d+)') {
                try {
                    $Upstream = Get-GitlabPipeline -ProjectId $MatchingResult.upstream.project.fullPath -PipelineId $Matches.PipelineId -SiteUrl $SiteUrl
                    $Pipeline | Add-Member -MemberType 'NoteProperty' -Name 'Upstream' -Value $Upstream
                }
                catch {
                }
            }
        }
    }

    $Pipelines
}

function Get-GitlabPipelineVariable {
    param(
        [Parameter()]
        [string]
        $ProjectId = '.',

        [Parameter(Position=0, Mandatory, ValueFromPipelineByPropertyName)]
        [string]
        $PipelineId,

        [Parameter(Position=1)]
        [string]
        $Variable,

        [Parameter()]
        [ValidateSet('KeyValuePairs', 'Object')]
        [string]
        $As = 'KeyValuePairs',

        [Parameter()]
        [string]
        $SiteUrl
    )

    $Project = Get-GitlabProject $ProjectId

    # https://docs.gitlab.com/ee/api/pipelines.html#get-variables-of-a-pipeline
    $KeyValues = Invoke-GitlabApi GET "projects/$($Project.Id)/pipelines/$PipelineId/variables" -SiteUrl $SiteUrl

    if ($Variable) {
        $KeyValues | Where-Object Key -eq $Variable | Select-Object -ExpandProperty Value
    } else {
        if ($As -eq 'KeyValuePairs') {
            $KeyValues | New-WrapperObject 'Gitlab.PipelineVariable'
        } elseif ($As -eq 'Object') {
            $Obj = New-Object PSObject
            $KeyValues.Key | ForEach-Object {
                $Obj | Add-Member -NotePropertyName $_ -NotePropertyValue $($KeyValues | Where-Object Key -eq $_ | Select-Object -ExpandProperty Value)
            }
            $Obj
        }
    }
}

function Get-GitlabPipelineSchedule {

    [CmdletBinding(DefaultParameterSetName='ByProjectId')]
    [Alias('schedule')]
    [Alias('schedules')]
    param (
        [Parameter(ParameterSetName='ByProjectId', ValueFromPipelineByPropertyName)]
        [Parameter(ParameterSetName='ByPipelineScheduleId')]
        [string]
        $ProjectId = '.',

        [Parameter(ParameterSetName='ByPipelineScheduleId', Mandatory)]
        [Alias('Id')]
        [int]
        $PipelineScheduleId,

        [Parameter(ParameterSetName='ByProjectId')]
        [string]
        [ValidateSet('active', 'inactive')]
        $Scope,

        [Parameter(ParameterSetName='ByProjectId', ValueFromPipelineByPropertyName)]
        [switch]
        $IncludeVariables,

        [Parameter()]
        [string]
        $SiteUrl
    )

    $Project = Get-GitlabProject -ProjectId $ProjectId

    $GitlabApiArguments = @{
        HttpMethod = 'GET'
        # https://docs.gitlab.com/ee/api/pipeline_schedules.html#get-all-pipeline-schedules
        Path       = "projects/$($Project.Id)/pipeline_schedules"
        Query      = @{}
        SiteUrl    = $SiteUrl
    }

    switch ($PSCmdlet.ParameterSetName) {
        ByPipelineScheduleId {
            $GitlabApiArguments.Path += "/$PipelineScheduleId"
        }
        ByProjectId {
            if($Scope) {
                $GitlabApiArguments.Query.scope = $Scope
            }
        }
        default { throw "Parameterset $($PSCmdlet.ParameterSetName) is not implemented"}
    }

    $Wrapper = Invoke-GitlabApi @GitlabApiArguments | New-WrapperObject 'Gitlab.PipelineSchedule'
    $Wrapper | Add-Member -NotePropertyMembers @{ Project = $Project }

    if ($IncludeVariables) {
        # only returned by the single schedule API so have to fetch them individually
        # (https://docs.gitlab.com/ee/api/pipeline_schedules.html#get-a-single-pipeline-schedule)
        $Wrapper = $Wrapper | ForEach-Object { Get-GitlabPipelineSchedule -ProjectId $_.ProjectId -PipelineScheduleId $_.Id }
    } 

    $Wrapper | Sort-Object NextRunAtSortable
}

# https://docs.gitlab.com/ee/api/pipeline_schedules.html#create-a-new-pipeline-schedule
function New-GitlabPipelineSchedule {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(ValueFromPipelineByPropertyName)]
        [string]
        $ProjectId = '.',

        [Parameter(ValueFromPipelineByPropertyName)]
        [Alias('Branch')]
        [string]
        $Ref,

        [Parameter(Mandatory)]
        [string]
        $Description,

        [Parameter(Mandatory)]
        [string]
        $Cron,

        [Parameter()]
        # TZInfo::Timezone.all_identifiers
        [ValidateSet("Africa/Abidjan", "Africa/Accra", "Africa/Addis_Ababa", "Africa/Algiers", "Africa/Asmara", "Africa/Asmera", "Africa/Bamako", "Africa/Bangui", "Africa/Banjul", "Africa/Bissau", "Africa/Blantyre", "Africa/Brazzaville", "Africa/Bujumbura", "Africa/Cairo", "Africa/Casablanca", "Africa/Ceuta", "Africa/Conakry", "Africa/Dakar", "Africa/Dar_es_Salaam", "Africa/Djibouti", "Africa/Douala", "Africa/El_Aaiun", "Africa/Freetown", "Africa/Gaborone", "Africa/Harare", "Africa/Johannesburg", "Africa/Juba", "Africa/Kampala", "Africa/Khartoum", "Africa/Kigali", "Africa/Kinshasa", "Africa/Lagos", "Africa/Libreville", "Africa/Lome", "Africa/Luanda", "Africa/Lubumbashi", "Africa/Lusaka", "Africa/Malabo", "Africa/Maputo", "Africa/Maseru", "Africa/Mbabane", "Africa/Mogadishu", "Africa/Monrovia", "Africa/Nairobi", "Africa/Ndjamena", "Africa/Niamey", "Africa/Nouakchott", "Africa/Ouagadougou", "Africa/Porto-Novo", "Africa/Sao_Tome", "Africa/Timbuktu", "Africa/Tripoli", "Africa/Tunis", "Africa/Windhoek", "America/Adak", "America/Anchorage", "America/Anguilla", "America/Antigua", "America/Araguaina", "America/Argentina/Buenos_Aires", "America/Argentina/Catamarca", "America/Argentina/ComodRivadavia", "America/Argentina/Cordoba", "America/Argentina/Jujuy", "America/Argentina/La_Rioja", "America/Argentina/Mendoza", "America/Argentina/Rio_Gallegos", "America/Argentina/Salta", "America/Argentina/San_Juan", "America/Argentina/San_Luis", "America/Argentina/Tucuman", "America/Argentina/Ushuaia", "America/Aruba", "America/Asuncion", "America/Atikokan", "America/Atka", "America/Bahia", "America/Bahia_Banderas", "America/Barbados", "America/Belem", "America/Belize", "America/Blanc-Sablon", "America/Boa_Vista", "America/Bogota", "America/Boise", "America/Buenos_Aires", "America/Cambridge_Bay", "America/Campo_Grande", "America/Cancun", "America/Caracas", "America/Catamarca", "America/Cayenne", "America/Cayman", "America/Chicago", "America/Chihuahua", "America/Ciudad_Juarez", "America/Coral_Harbour", "America/Cordoba", "America/Costa_Rica", "America/Creston", "America/Cuiaba", "America/Curacao", "America/Danmarkshavn", "America/Dawson", "America/Dawson_Creek", "America/Denver", "America/Detroit", "America/Dominica", "America/Edmonton", "America/Eirunepe", "America/El_Salvador", "America/Ensenada", "America/Fort_Nelson", "America/Fort_Wayne", "America/Fortaleza", "America/Glace_Bay", "America/Godthab", "America/Goose_Bay", "America/Grand_Turk", "America/Grenada", "America/Guadeloupe", "America/Guatemala", "America/Guayaquil", "America/Guyana", "America/Halifax", "America/Havana", "America/Hermosillo", "America/Indiana/Indianapolis", "America/Indiana/Knox", "America/Indiana/Marengo", "America/Indiana/Petersburg", "America/Indiana/Tell_City", "America/Indiana/Vevay", "America/Indiana/Vincennes", "America/Indiana/Winamac", "America/Indianapolis", "America/Inuvik", "America/Iqaluit", "America/Jamaica", "America/Jujuy", "America/Juneau", "America/Kentucky/Louisville", "America/Kentucky/Monticello", "America/Knox_IN", "America/Kralendijk", "America/La_Paz", "America/Lima", "America/Los_Angeles", "America/Louisville", "America/Lower_Princes", "America/Maceio", "America/Managua", "America/Manaus", "America/Marigot", "America/Martinique", "America/Matamoros", "America/Mazatlan", "America/Mendoza", "America/Menominee", "America/Merida", "America/Metlakatla", "America/Mexico_City", "America/Miquelon", "America/Moncton", "America/Monterrey", "America/Montevideo", "America/Montreal", "America/Montserrat", "America/Nassau", "America/New_York", "America/Nipigon", "America/Nome", "America/Noronha", "America/North_Dakota/Beulah", "America/North_Dakota/Center", "America/North_Dakota/New_Salem", "America/Nuuk", "America/Ojinaga", "America/Panama", "America/Pangnirtung", "America/Paramaribo", "America/Phoenix", "America/Port-au-Prince", "America/Port_of_Spain", "America/Porto_Acre", "America/Porto_Velho", "America/Puerto_Rico", "America/Punta_Arenas", "America/Rainy_River", "America/Rankin_Inlet", "America/Recife", "America/Regina", "America/Resolute", "America/Rio_Branco", "America/Rosario", "America/Santa_Isabel", "America/Santarem", "America/Santiago", "America/Santo_Domingo", "America/Sao_Paulo", "America/Scoresbysund", "America/Shiprock", "America/Sitka", "America/St_Barthelemy", "America/St_Johns", "America/St_Kitts", "America/St_Lucia", "America/St_Thomas", "America/St_Vincent", "America/Swift_Current", "America/Tegucigalpa", "America/Thule", "America/Thunder_Bay", "America/Tijuana", "America/Toronto", "America/Tortola", "America/Vancouver", "America/Virgin", "America/Whitehorse", "America/Winnipeg", "America/Yakutat", "America/Yellowknife", "Antarctica/Casey", "Antarctica/Davis", "Antarctica/DumontDUrville", "Antarctica/Macquarie", "Antarctica/Mawson", "Antarctica/McMurdo", "Antarctica/Palmer", "Antarctica/Rothera", "Antarctica/South_Pole", "Antarctica/Syowa", "Antarctica/Troll", "Antarctica/Vostok", "Arctic/Longyearbyen", "Asia/Aden", "Asia/Almaty", "Asia/Amman", "Asia/Anadyr", "Asia/Aqtau", "Asia/Aqtobe", "Asia/Ashgabat", "Asia/Ashkhabad", "Asia/Atyrau", "Asia/Baghdad", "Asia/Bahrain", "Asia/Baku", "Asia/Bangkok", "Asia/Barnaul", "Asia/Beirut", "Asia/Bishkek", "Asia/Brunei", "Asia/Calcutta", "Asia/Chita", "Asia/Choibalsan", "Asia/Chongqing", "Asia/Chungking", "Asia/Colombo", "Asia/Dacca", "Asia/Damascus", "Asia/Dhaka", "Asia/Dili", "Asia/Dubai", "Asia/Dushanbe", "Asia/Famagusta", "Asia/Gaza", "Asia/Harbin", "Asia/Hebron", "Asia/Ho_Chi_Minh", "Asia/Hong_Kong", "Asia/Hovd", "Asia/Irkutsk", "Asia/Istanbul", "Asia/Jakarta", "Asia/Jayapura", "Asia/Jerusalem", "Asia/Kabul", "Asia/Kamchatka", "Asia/Karachi", "Asia/Kashgar", "Asia/Kathmandu", "Asia/Katmandu", "Asia/Khandyga", "Asia/Kolkata", "Asia/Krasnoyarsk", "Asia/Kuala_Lumpur", "Asia/Kuching", "Asia/Kuwait", "Asia/Macao", "Asia/Macau", "Asia/Magadan", "Asia/Makassar", "Asia/Manila", "Asia/Muscat", "Asia/Nicosia", "Asia/Novokuznetsk", "Asia/Novosibirsk", "Asia/Omsk", "Asia/Oral", "Asia/Phnom_Penh", "Asia/Pontianak", "Asia/Pyongyang", "Asia/Qatar", "Asia/Qostanay", "Asia/Qyzylorda", "Asia/Rangoon", "Asia/Riyadh", "Asia/Saigon", "Asia/Sakhalin", "Asia/Samarkand", "Asia/Seoul", "Asia/Shanghai", "Asia/Singapore", "Asia/Srednekolymsk", "Asia/Taipei", "Asia/Tashkent", "Asia/Tbilisi", "Asia/Tehran", "Asia/Tel_Aviv", "Asia/Thimbu", "Asia/Thimphu", "Asia/Tokyo", "Asia/Tomsk", "Asia/Ujung_Pandang", "Asia/Ulaanbaatar", "Asia/Ulan_Bator", "Asia/Urumqi", "Asia/Ust-Nera", "Asia/Vientiane", "Asia/Vladivostok", "Asia/Yakutsk", "Asia/Yangon", "Asia/Yekaterinburg", "Asia/Yerevan", "Atlantic/Azores", "Atlantic/Bermuda", "Atlantic/Canary", "Atlantic/Cape_Verde", "Atlantic/Faeroe", "Atlantic/Faroe", "Atlantic/Jan_Mayen", "Atlantic/Madeira", "Atlantic/Reykjavik", "Atlantic/South_Georgia", "Atlantic/St_Helena", "Atlantic/Stanley", "Australia/ACT", "Australia/Adelaide", "Australia/Brisbane", "Australia/Broken_Hill", "Australia/Canberra", "Australia/Currie", "Australia/Darwin", "Australia/Eucla", "Australia/Hobart", "Australia/LHI", "Australia/Lindeman", "Australia/Lord_Howe", "Australia/Melbourne", "Australia/NSW", "Australia/North", "Australia/Perth", "Australia/Queensland", "Australia/South", "Australia/Sydney", "Australia/Tasmania", "Australia/Victoria", "Australia/West", "Australia/Yancowinna", "Brazil/Acre", "Brazil/DeNoronha", "Brazil/East", "Brazil/West", "CET", "CST6CDT", "Canada/Atlantic", "Canada/Central", "Canada/Eastern", "Canada/Mountain", "Canada/Newfoundland", "Canada/Pacific", "Canada/Saskatchewan", "Canada/Yukon", "Chile/Continental", "Chile/EasterIsland", "Cuba", "EET", "EST", "EST5EDT", "Egypt", "Eire", "Etc/GMT", "Etc/GMT+0", "Etc/GMT+1", "Etc/GMT+10", "Etc/GMT+11", "Etc/GMT+12", "Etc/GMT+2", "Etc/GMT+3", "Etc/GMT+4", "Etc/GMT+5", "Etc/GMT+6", "Etc/GMT+7", "Etc/GMT+8", "Etc/GMT+9", "Etc/GMT-0", "Etc/GMT-1", "Etc/GMT-10", "Etc/GMT-11", "Etc/GMT-12", "Etc/GMT-13", "Etc/GMT-14", "Etc/GMT-2", "Etc/GMT-3", "Etc/GMT-4", "Etc/GMT-5", "Etc/GMT-6", "Etc/GMT-7", "Etc/GMT-8", "Etc/GMT-9", "Etc/GMT0", "Etc/Greenwich", "Etc/UCT", "Etc/UTC", "Etc/Universal", "Etc/Zulu", "Europe/Amsterdam", "Europe/Andorra", "Europe/Astrakhan", "Europe/Athens", "Europe/Belfast", "Europe/Belgrade", "Europe/Berlin", "Europe/Bratislava", "Europe/Brussels", "Europe/Bucharest", "Europe/Budapest", "Europe/Busingen", "Europe/Chisinau", "Europe/Copenhagen", "Europe/Dublin", "Europe/Gibraltar", "Europe/Guernsey", "Europe/Helsinki", "Europe/Isle_of_Man", "Europe/Istanbul", "Europe/Jersey", "Europe/Kaliningrad", "Europe/Kiev", "Europe/Kirov", "Europe/Kyiv", "Europe/Lisbon", "Europe/Ljubljana", "Europe/London", "Europe/Luxembourg", "Europe/Madrid", "Europe/Malta", "Europe/Mariehamn", "Europe/Minsk", "Europe/Monaco", "Europe/Moscow", "Europe/Nicosia", "Europe/Oslo", "Europe/Paris", "Europe/Podgorica", "Europe/Prague", "Europe/Riga", "Europe/Rome", "Europe/Samara", "Europe/San_Marino", "Europe/Sarajevo", "Europe/Saratov", "Europe/Simferopol", "Europe/Skopje", "Europe/Sofia", "Europe/Stockholm", "Europe/Tallinn", "Europe/Tirane", "Europe/Tiraspol", "Europe/Ulyanovsk", "Europe/Uzhgorod", "Europe/Vaduz", "Europe/Vatican", "Europe/Vienna", "Europe/Vilnius", "Europe/Volgograd", "Europe/Warsaw", "Europe/Zagreb", "Europe/Zaporozhye", "Europe/Zurich", "Factory", "GB", "GB-Eire", "GMT", "GMT+0", "GMT-0", "GMT0", "Greenwich", "HST", "Hongkong", "Iceland", "Indian/Antananarivo", "Indian/Chagos", "Indian/Christmas", "Indian/Cocos", "Indian/Comoro", "Indian/Kerguelen", "Indian/Mahe", "Indian/Maldives", "Indian/Mauritius", "Indian/Mayotte", "Indian/Reunion", "Iran", "Israel", "Jamaica", "Japan", "Kwajalein", "Libya", "MET", "MST", "MST7MDT", "Mexico/BajaNorte", "Mexico/BajaSur", "Mexico/General", "NZ", "NZ-CHAT", "Navajo", "PRC", "PST8PDT", "Pacific/Apia", "Pacific/Auckland", "Pacific/Bougainville", "Pacific/Chatham", "Pacific/Chuuk", "Pacific/Easter", "Pacific/Efate", "Pacific/Enderbury", "Pacific/Fakaofo", "Pacific/Fiji", "Pacific/Funafuti", "Pacific/Galapagos", "Pacific/Gambier", "Pacific/Guadalcanal", "Pacific/Guam", "Pacific/Honolulu", "Pacific/Johnston", "Pacific/Kanton", "Pacific/Kiritimati", "Pacific/Kosrae", "Pacific/Kwajalein", "Pacific/Majuro", "Pacific/Marquesas", "Pacific/Midway", "Pacific/Nauru", "Pacific/Niue", "Pacific/Norfolk", "Pacific/Noumea", "Pacific/Pago_Pago", "Pacific/Palau", "Pacific/Pitcairn", "Pacific/Pohnpei", "Pacific/Ponape", "Pacific/Port_Moresby", "Pacific/Rarotonga", "Pacific/Saipan", "Pacific/Samoa", "Pacific/Tahiti", "Pacific/Tarawa", "Pacific/Tongatapu", "Pacific/Truk", "Pacific/Wake", "Pacific/Wallis", "Pacific/Yap", "Poland", "Portugal", "ROC", "ROK", "Singapore", "Turkey", "UCT", "US/Alaska", "US/Aleutian", "US/Arizona", "US/Central", "US/East-Indiana", "US/Eastern", "US/Hawaii", "US/Indiana-Starke", "US/Michigan", "US/Mountain", "US/Pacific", "US/Samoa", "UTC", "Universal", "W-SU", "WET", "Zulu")]
        [string]
        $CronTimezone = 'UTC',

        [Parameter()]
        [ValidateSet($null, 'true', 'false')]
        [string]
        $Active,

        [Parameter()]
        [string]
        $SiteUrl
    )

    $Project = Get-GitlabProject $ProjectId -SiteUrl $SiteUrl
    
    if ([string]::IsNullOrWhiteSpace($Ref)) {
        $Ref = $ProjectId -eq '.' -or $Ref -eq '.' ? $(Get-LocalGitContext).Branch : $Project.DefaultBranch
    }

    $Body = @{
        ref           = $Ref
        description   = $Description
        cron          = $Cron
        cron_timezone = $CronTimezone
    }
    if ($Active) {
        $Body.active = $Active
    }

    if ($PSCmdlet.ShouldProcess("$($Project.PathWithNamespace)", "create new schedule $($Body | ConvertTo-Json)")) {

        $GitlabApiArguments = @{
            HttpMethod = 'POST'
            Path       = "projects/$($Project.Id)/pipeline_schedules"
            Body       = $Body
            SiteUrl    = $SiteUrl
        }
        $Wrapper = Invoke-GitlabApi @GitlabApiArguments -WhatIf:$WhatIf | New-WrapperObject 'Gitlab.PipelineSchedule'
        $Wrapper | Add-Member -MemberType 'NoteProperty' -Name 'ProjectId' -Value $ProjectId
        $Wrapper
    }
}

# https://docs.gitlab.com/ee/api/pipeline_schedules.html#edit-a-pipeline-schedule
function Update-GitlabPipelineSchedule {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(ValueFromPipelineByPropertyName)]
        [string]
        $ProjectId = '.',

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('Id')]
        [int]
        $PipelineScheduleId,

        [Parameter()]
        [string]
        $Description,

        [Parameter()]
        [Alias("Branch")]
        [string]
        $Ref,

        [Parameter()]
        [string]
        $Cron,

        [Parameter()]
        [string]
        # TZInfo::Timezone.all_identifiers
        [ValidateSet("Africa/Abidjan", "Africa/Accra", "Africa/Addis_Ababa", "Africa/Algiers", "Africa/Asmara", "Africa/Asmera", "Africa/Bamako", "Africa/Bangui", "Africa/Banjul", "Africa/Bissau", "Africa/Blantyre", "Africa/Brazzaville", "Africa/Bujumbura", "Africa/Cairo", "Africa/Casablanca", "Africa/Ceuta", "Africa/Conakry", "Africa/Dakar", "Africa/Dar_es_Salaam", "Africa/Djibouti", "Africa/Douala", "Africa/El_Aaiun", "Africa/Freetown", "Africa/Gaborone", "Africa/Harare", "Africa/Johannesburg", "Africa/Juba", "Africa/Kampala", "Africa/Khartoum", "Africa/Kigali", "Africa/Kinshasa", "Africa/Lagos", "Africa/Libreville", "Africa/Lome", "Africa/Luanda", "Africa/Lubumbashi", "Africa/Lusaka", "Africa/Malabo", "Africa/Maputo", "Africa/Maseru", "Africa/Mbabane", "Africa/Mogadishu", "Africa/Monrovia", "Africa/Nairobi", "Africa/Ndjamena", "Africa/Niamey", "Africa/Nouakchott", "Africa/Ouagadougou", "Africa/Porto-Novo", "Africa/Sao_Tome", "Africa/Timbuktu", "Africa/Tripoli", "Africa/Tunis", "Africa/Windhoek", "America/Adak", "America/Anchorage", "America/Anguilla", "America/Antigua", "America/Araguaina", "America/Argentina/Buenos_Aires", "America/Argentina/Catamarca", "America/Argentina/ComodRivadavia", "America/Argentina/Cordoba", "America/Argentina/Jujuy", "America/Argentina/La_Rioja", "America/Argentina/Mendoza", "America/Argentina/Rio_Gallegos", "America/Argentina/Salta", "America/Argentina/San_Juan", "America/Argentina/San_Luis", "America/Argentina/Tucuman", "America/Argentina/Ushuaia", "America/Aruba", "America/Asuncion", "America/Atikokan", "America/Atka", "America/Bahia", "America/Bahia_Banderas", "America/Barbados", "America/Belem", "America/Belize", "America/Blanc-Sablon", "America/Boa_Vista", "America/Bogota", "America/Boise", "America/Buenos_Aires", "America/Cambridge_Bay", "America/Campo_Grande", "America/Cancun", "America/Caracas", "America/Catamarca", "America/Cayenne", "America/Cayman", "America/Chicago", "America/Chihuahua", "America/Ciudad_Juarez", "America/Coral_Harbour", "America/Cordoba", "America/Costa_Rica", "America/Creston", "America/Cuiaba", "America/Curacao", "America/Danmarkshavn", "America/Dawson", "America/Dawson_Creek", "America/Denver", "America/Detroit", "America/Dominica", "America/Edmonton", "America/Eirunepe", "America/El_Salvador", "America/Ensenada", "America/Fort_Nelson", "America/Fort_Wayne", "America/Fortaleza", "America/Glace_Bay", "America/Godthab", "America/Goose_Bay", "America/Grand_Turk", "America/Grenada", "America/Guadeloupe", "America/Guatemala", "America/Guayaquil", "America/Guyana", "America/Halifax", "America/Havana", "America/Hermosillo", "America/Indiana/Indianapolis", "America/Indiana/Knox", "America/Indiana/Marengo", "America/Indiana/Petersburg", "America/Indiana/Tell_City", "America/Indiana/Vevay", "America/Indiana/Vincennes", "America/Indiana/Winamac", "America/Indianapolis", "America/Inuvik", "America/Iqaluit", "America/Jamaica", "America/Jujuy", "America/Juneau", "America/Kentucky/Louisville", "America/Kentucky/Monticello", "America/Knox_IN", "America/Kralendijk", "America/La_Paz", "America/Lima", "America/Los_Angeles", "America/Louisville", "America/Lower_Princes", "America/Maceio", "America/Managua", "America/Manaus", "America/Marigot", "America/Martinique", "America/Matamoros", "America/Mazatlan", "America/Mendoza", "America/Menominee", "America/Merida", "America/Metlakatla", "America/Mexico_City", "America/Miquelon", "America/Moncton", "America/Monterrey", "America/Montevideo", "America/Montreal", "America/Montserrat", "America/Nassau", "America/New_York", "America/Nipigon", "America/Nome", "America/Noronha", "America/North_Dakota/Beulah", "America/North_Dakota/Center", "America/North_Dakota/New_Salem", "America/Nuuk", "America/Ojinaga", "America/Panama", "America/Pangnirtung", "America/Paramaribo", "America/Phoenix", "America/Port-au-Prince", "America/Port_of_Spain", "America/Porto_Acre", "America/Porto_Velho", "America/Puerto_Rico", "America/Punta_Arenas", "America/Rainy_River", "America/Rankin_Inlet", "America/Recife", "America/Regina", "America/Resolute", "America/Rio_Branco", "America/Rosario", "America/Santa_Isabel", "America/Santarem", "America/Santiago", "America/Santo_Domingo", "America/Sao_Paulo", "America/Scoresbysund", "America/Shiprock", "America/Sitka", "America/St_Barthelemy", "America/St_Johns", "America/St_Kitts", "America/St_Lucia", "America/St_Thomas", "America/St_Vincent", "America/Swift_Current", "America/Tegucigalpa", "America/Thule", "America/Thunder_Bay", "America/Tijuana", "America/Toronto", "America/Tortola", "America/Vancouver", "America/Virgin", "America/Whitehorse", "America/Winnipeg", "America/Yakutat", "America/Yellowknife", "Antarctica/Casey", "Antarctica/Davis", "Antarctica/DumontDUrville", "Antarctica/Macquarie", "Antarctica/Mawson", "Antarctica/McMurdo", "Antarctica/Palmer", "Antarctica/Rothera", "Antarctica/South_Pole", "Antarctica/Syowa", "Antarctica/Troll", "Antarctica/Vostok", "Arctic/Longyearbyen", "Asia/Aden", "Asia/Almaty", "Asia/Amman", "Asia/Anadyr", "Asia/Aqtau", "Asia/Aqtobe", "Asia/Ashgabat", "Asia/Ashkhabad", "Asia/Atyrau", "Asia/Baghdad", "Asia/Bahrain", "Asia/Baku", "Asia/Bangkok", "Asia/Barnaul", "Asia/Beirut", "Asia/Bishkek", "Asia/Brunei", "Asia/Calcutta", "Asia/Chita", "Asia/Choibalsan", "Asia/Chongqing", "Asia/Chungking", "Asia/Colombo", "Asia/Dacca", "Asia/Damascus", "Asia/Dhaka", "Asia/Dili", "Asia/Dubai", "Asia/Dushanbe", "Asia/Famagusta", "Asia/Gaza", "Asia/Harbin", "Asia/Hebron", "Asia/Ho_Chi_Minh", "Asia/Hong_Kong", "Asia/Hovd", "Asia/Irkutsk", "Asia/Istanbul", "Asia/Jakarta", "Asia/Jayapura", "Asia/Jerusalem", "Asia/Kabul", "Asia/Kamchatka", "Asia/Karachi", "Asia/Kashgar", "Asia/Kathmandu", "Asia/Katmandu", "Asia/Khandyga", "Asia/Kolkata", "Asia/Krasnoyarsk", "Asia/Kuala_Lumpur", "Asia/Kuching", "Asia/Kuwait", "Asia/Macao", "Asia/Macau", "Asia/Magadan", "Asia/Makassar", "Asia/Manila", "Asia/Muscat", "Asia/Nicosia", "Asia/Novokuznetsk", "Asia/Novosibirsk", "Asia/Omsk", "Asia/Oral", "Asia/Phnom_Penh", "Asia/Pontianak", "Asia/Pyongyang", "Asia/Qatar", "Asia/Qostanay", "Asia/Qyzylorda", "Asia/Rangoon", "Asia/Riyadh", "Asia/Saigon", "Asia/Sakhalin", "Asia/Samarkand", "Asia/Seoul", "Asia/Shanghai", "Asia/Singapore", "Asia/Srednekolymsk", "Asia/Taipei", "Asia/Tashkent", "Asia/Tbilisi", "Asia/Tehran", "Asia/Tel_Aviv", "Asia/Thimbu", "Asia/Thimphu", "Asia/Tokyo", "Asia/Tomsk", "Asia/Ujung_Pandang", "Asia/Ulaanbaatar", "Asia/Ulan_Bator", "Asia/Urumqi", "Asia/Ust-Nera", "Asia/Vientiane", "Asia/Vladivostok", "Asia/Yakutsk", "Asia/Yangon", "Asia/Yekaterinburg", "Asia/Yerevan", "Atlantic/Azores", "Atlantic/Bermuda", "Atlantic/Canary", "Atlantic/Cape_Verde", "Atlantic/Faeroe", "Atlantic/Faroe", "Atlantic/Jan_Mayen", "Atlantic/Madeira", "Atlantic/Reykjavik", "Atlantic/South_Georgia", "Atlantic/St_Helena", "Atlantic/Stanley", "Australia/ACT", "Australia/Adelaide", "Australia/Brisbane", "Australia/Broken_Hill", "Australia/Canberra", "Australia/Currie", "Australia/Darwin", "Australia/Eucla", "Australia/Hobart", "Australia/LHI", "Australia/Lindeman", "Australia/Lord_Howe", "Australia/Melbourne", "Australia/NSW", "Australia/North", "Australia/Perth", "Australia/Queensland", "Australia/South", "Australia/Sydney", "Australia/Tasmania", "Australia/Victoria", "Australia/West", "Australia/Yancowinna", "Brazil/Acre", "Brazil/DeNoronha", "Brazil/East", "Brazil/West", "CET", "CST6CDT", "Canada/Atlantic", "Canada/Central", "Canada/Eastern", "Canada/Mountain", "Canada/Newfoundland", "Canada/Pacific", "Canada/Saskatchewan", "Canada/Yukon", "Chile/Continental", "Chile/EasterIsland", "Cuba", "EET", "EST", "EST5EDT", "Egypt", "Eire", "Etc/GMT", "Etc/GMT+0", "Etc/GMT+1", "Etc/GMT+10", "Etc/GMT+11", "Etc/GMT+12", "Etc/GMT+2", "Etc/GMT+3", "Etc/GMT+4", "Etc/GMT+5", "Etc/GMT+6", "Etc/GMT+7", "Etc/GMT+8", "Etc/GMT+9", "Etc/GMT-0", "Etc/GMT-1", "Etc/GMT-10", "Etc/GMT-11", "Etc/GMT-12", "Etc/GMT-13", "Etc/GMT-14", "Etc/GMT-2", "Etc/GMT-3", "Etc/GMT-4", "Etc/GMT-5", "Etc/GMT-6", "Etc/GMT-7", "Etc/GMT-8", "Etc/GMT-9", "Etc/GMT0", "Etc/Greenwich", "Etc/UCT", "Etc/UTC", "Etc/Universal", "Etc/Zulu", "Europe/Amsterdam", "Europe/Andorra", "Europe/Astrakhan", "Europe/Athens", "Europe/Belfast", "Europe/Belgrade", "Europe/Berlin", "Europe/Bratislava", "Europe/Brussels", "Europe/Bucharest", "Europe/Budapest", "Europe/Busingen", "Europe/Chisinau", "Europe/Copenhagen", "Europe/Dublin", "Europe/Gibraltar", "Europe/Guernsey", "Europe/Helsinki", "Europe/Isle_of_Man", "Europe/Istanbul", "Europe/Jersey", "Europe/Kaliningrad", "Europe/Kiev", "Europe/Kirov", "Europe/Kyiv", "Europe/Lisbon", "Europe/Ljubljana", "Europe/London", "Europe/Luxembourg", "Europe/Madrid", "Europe/Malta", "Europe/Mariehamn", "Europe/Minsk", "Europe/Monaco", "Europe/Moscow", "Europe/Nicosia", "Europe/Oslo", "Europe/Paris", "Europe/Podgorica", "Europe/Prague", "Europe/Riga", "Europe/Rome", "Europe/Samara", "Europe/San_Marino", "Europe/Sarajevo", "Europe/Saratov", "Europe/Simferopol", "Europe/Skopje", "Europe/Sofia", "Europe/Stockholm", "Europe/Tallinn", "Europe/Tirane", "Europe/Tiraspol", "Europe/Ulyanovsk", "Europe/Uzhgorod", "Europe/Vaduz", "Europe/Vatican", "Europe/Vienna", "Europe/Vilnius", "Europe/Volgograd", "Europe/Warsaw", "Europe/Zagreb", "Europe/Zaporozhye", "Europe/Zurich", "Factory", "GB", "GB-Eire", "GMT", "GMT+0", "GMT-0", "GMT0", "Greenwich", "HST", "Hongkong", "Iceland", "Indian/Antananarivo", "Indian/Chagos", "Indian/Christmas", "Indian/Cocos", "Indian/Comoro", "Indian/Kerguelen", "Indian/Mahe", "Indian/Maldives", "Indian/Mauritius", "Indian/Mayotte", "Indian/Reunion", "Iran", "Israel", "Jamaica", "Japan", "Kwajalein", "Libya", "MET", "MST", "MST7MDT", "Mexico/BajaNorte", "Mexico/BajaSur", "Mexico/General", "NZ", "NZ-CHAT", "Navajo", "PRC", "PST8PDT", "Pacific/Apia", "Pacific/Auckland", "Pacific/Bougainville", "Pacific/Chatham", "Pacific/Chuuk", "Pacific/Easter", "Pacific/Efate", "Pacific/Enderbury", "Pacific/Fakaofo", "Pacific/Fiji", "Pacific/Funafuti", "Pacific/Galapagos", "Pacific/Gambier", "Pacific/Guadalcanal", "Pacific/Guam", "Pacific/Honolulu", "Pacific/Johnston", "Pacific/Kanton", "Pacific/Kiritimati", "Pacific/Kosrae", "Pacific/Kwajalein", "Pacific/Majuro", "Pacific/Marquesas", "Pacific/Midway", "Pacific/Nauru", "Pacific/Niue", "Pacific/Norfolk", "Pacific/Noumea", "Pacific/Pago_Pago", "Pacific/Palau", "Pacific/Pitcairn", "Pacific/Pohnpei", "Pacific/Ponape", "Pacific/Port_Moresby", "Pacific/Rarotonga", "Pacific/Saipan", "Pacific/Samoa", "Pacific/Tahiti", "Pacific/Tarawa", "Pacific/Tongatapu", "Pacific/Truk", "Pacific/Wake", "Pacific/Wallis", "Pacific/Yap", "Poland", "Portugal", "ROC", "ROK", "Singapore", "Turkey", "UCT", "US/Alaska", "US/Aleutian", "US/Arizona", "US/Central", "US/East-Indiana", "US/Eastern", "US/Hawaii", "US/Indiana-Starke", "US/Michigan", "US/Mountain", "US/Pacific", "US/Samoa", "UTC", "Universal", "W-SU", "WET", "Zulu")]
        $CronTimezone,

        [Parameter()]
        [ValidateSet($null, 'false', 'true')]
        [string]
        $Active,

        [Parameter()]
        [string]
        $SiteUrl
    )

    $Project = Get-GitlabProject $ProjectId -SiteUrl $SiteUrl

    $GitlabApiArguments = @{
        HttpMethod = 'PUT'
        Path       = "projects/$($Project.Id)/pipeline_schedules/$PipelineScheduleId"
        Body       = @{}
        SiteUrl    = $SiteUrl
    }

    if ($Active) {
        $GitlabApiArguments.Body.active = $Active
    }
    if ($Description) {
        $GitlabApiArguments.Body.description = $Description
    }
    if ($Ref) {
        $GitlabApiArguments.Body.ref = $Ref
    }
    if ($Cron) {
        $GitlabApiArguments.Body.cron = $Cron
    }
    if ($CronTimezone) {
        $GitlabApiArguments.Body.cron_timezone = $CronTimezone
    }

    if ($PSCmdlet.ShouldProcess("$($GitlabApiArguments.Path)", "update schedule $($GitlabApiArguments.Body | ConvertTo-Json)")) {
        Invoke-GitlabApi @GitlabApiArguments -WhatIf:$WhatIf | New-WrapperObject 'Gitlab.PipelineSchedule'
    }
}

function Enable-GitlabPipelineSchedule {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(ValueFromPipelineByPropertyName)]
        [string]
        $ProjectId = '.',

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('Id')]
        [int]
        $PipelineScheduleId,

        [Parameter()]
        [string]
        $SiteUrl
    )

    $Project = Get-GitlabProject $ProjectId -SiteUrl $SiteUrl

    if ($PSCmdlet.ShouldProcess("$($Project.PathWithNamespace)", "enable pipeline schedule $PipelineScheduleId")) {
        Update-GitlabPipelineSchedule -ProjectId $ProjectId -PipelineScheduleId $PipelineScheduleId -Active true -SiteUrl $SiteUrl
    }
}

function Disable-GitlabPipelineSchedule {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(ValueFromPipelineByPropertyName)]
        [string]
        $ProjectId = '.',

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('Id')]
        [int]
        $PipelineScheduleId,

        [Parameter()]
        [string]
        $SiteUrl
    )

    $Project = Get-GitlabProject $ProjectId -SiteUrl $SiteUrl

    if ($PSCmdlet.ShouldProcess("$($Project.PathWithNamespace)", "disable pipeline schedule $PipelineScheduleId")) {
        Update-GitlabPipelineSchedule -ProjectId $ProjectId -PipelineScheduleId $PipelineScheduleId -Active false -SiteUrl $SiteUrl
    }
}

# https://docs.gitlab.com/ee/api/pipeline_schedules.html#delete-a-pipeline-schedule
function Remove-GitlabPipelineSchedule {
    param (
        [Parameter(Mandatory=$false, ValueFromPipelineByPropertyName=$true)]
        [string]
        $ProjectId = '.',

        [Parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
        [Alias('Id')]
        [int]
        $PipelineScheduleId,

        [Parameter(Mandatory=$false)]
        [string]
        $SiteUrl,

        [switch]
        [Parameter(Mandatory=$false)]
        $WhatIf
    )

    $Project = Get-GitlabProject -SiteUrl $SiteUrl

    $GitlabApiArguments = @{
        HttpMethod = 'DELETE'
        Path       = "projects/$($Project.Id)/pipeline_schedules/$PipelineScheduleId"
        SiteUrl    = $SiteUrl
    }

    Invoke-GitlabApi @GitlabApiArguments -WhatIf:$WhatIf
}

#https://docs.gitlab.com/ee/api/pipeline_schedules.html#pipeline-schedule-variables
# This behavior isn't part of the api, but a nested structure on getting a PipelineSchedule itself JUST by Id
function Get-GitlabPipelineScheduleVariable {
    param (
        [Parameter(Mandatory=$false)]
        [string]
        $ProjectId="." ,

        [Parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
        [int]
        $PipelineScheduleId,

        [Parameter(Mandatory=$false)]
        $Key,

        [Parameter(Mandatory=$false)]
        [string]
        $SiteUrl,

        [switch]
        [Parameter(Mandatory=$false)]
        $WhatIf
    )

    $Project = Get-GitlabProject $ProjectId -SiteUrl $SiteUrl
    $PipelineSchedule = Get-GitlabPipelineSchedule -ProjectId $Project.Id -PipelineScheduleId $PipelineScheduleId

    $Wrapper = $PipelineSchedule.Variables | New-WrapperObject "Gitlab.PipelineScheduleVariable"
    $Wrapper | Add-Member -MemberType 'NoteProperty' -Name 'ProjectId' -Value $Project.Id
    $Wrapper | Add-Member -MemberType 'NoteProperty' -Name 'PipelineScheduleId' -Value $PipelineSchedule.Id

    if($Key) {
        $Wrapper = $Wrapper | Where-Object { $_.Key -eq $Key } 
    }

    $Wrapper
}

function New-GitlabPipelineScheduleVariable {
    param (
        [Parameter(Mandatory=$false)]
        [string]
        $ProjectId="." ,

        [Parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
        [int]
        $PipelineScheduleId,

        [Parameter(Mandatory=$true)]
        [ValidatePattern("[A-Za-z0-9_]")]
        [string]
        $Key,

        [Parameter(Mandatory=$true)]
        [string]
        $Value,

        [Parameter(Mandatory=$false)]
        [ValidateSet("env_var","file")]
        [string]
        $VariableType="env_var",
     
        [Parameter(Mandatory=$false)]
        [string]
        $SiteUrl,

        [switch]
        [Parameter(Mandatory=$false)]
        $WhatIf
    )

    $Project = Get-GitlabProject $ProjectId -SiteUrl $SiteUrl
    $PipelineSchedule = Get-GitlabPipelineSchedule -ProjectId $Project.Id -PipelineScheduleId $PipelineScheduleId

    $Body = @{
        "key"           = $Key
        "value"         = $Value
        "variable_type" = $VariableType
    }

    $GitlabApiArguments = @{
        HttpMethod = "POST"
        Path       = "projects/$($Project.Id)/pipeline_schedules/$($PipelineSchedule.Id)/variables"
        SiteUrl    = $SiteUrl
        Body       = $Body
    }

    Invoke-GitlabApi @GitlabApiArguments -WhatIf:$WhatIf | New-WrapperObject "Gitlab.PipelineScheduleVariable"
    $Wrapper | Add-Member -MemberType 'NoteProperty' -Name 'ProjectId' -Value $Project.Id
    $Wrapper | Add-Member -MemberType 'NoteProperty' -Name 'PipelineScheduleId' -Value $PipelineSchedule.Id
}

function Update-GitlabPipelineScheduleVariable {
    param (
        [Parameter(Mandatory=$false, ValueFromPipelineByPropertyName=$true)]
        [string]
        $ProjectId="." ,

        [Parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
        [int]
        $PipelineScheduleId,

        [Parameter(Mandatory=$true)]
        [ValidateLength(255)]
        [ValidatePattern("[A-Za-z0-9_]")]
        [string]
        $Key,

        [Parameter(Mandatory=$true)]
        [string]
        $Value,

        [Parameter(Mandatory=$false)]
        [ValidateSet("env_var","file")]
        [string]
        $VariableType="env_var",
     
        [Parameter(Mandatory=$false)]
        [string]
        $SiteUrl,

        [switch]
        [Parameter(Mandatory=$false)]
        $WhatIf
    )

    $Project = Get-GitlabProject $ProjectId -SiteUrl $SiteUrl
    $PipelineSchedule = Get-GitlabPipelineSchedule -ProjectId $ProjectId -PipelineScheduleId $PipelineScheduleId

    $Body = @{
        "key"           = $Key
        "value"         = $Value
        "variable_type" = $VariableType
    }

    $GitlabApiArguments = @{
        HttpMethod = "PUT"
        Path       = "projects/$($Project.Id)/pipeline_schedules/$($PipelineSchedule.Id)/variables/$($Key)"
        SiteUrl    = $SiteUrl
        Body       = $Body
    }

    Invoke-GitlabApi @GitlabApiArguments -WhatIf:$WhatIf | New-WrapperObject "Gitlab.PipelineScheduleVariable"
    $Wrapper | Add-Member -MemberType 'NoteProperty' -Name 'ProjectId' -Value $Project.Id
    $Wrapper | Add-Member -MemberType 'NoteProperty' -Name 'PipelineScheduleId' -Value $PipelineSchedule.Id
}

function Remove-GitlabPipelineScheduleVariable {
    param (
        [Parameter(Mandatory=$false)]
        [string]
        $ProjectId="." ,

        [Parameter(Mandatory=$true)]
        [int]
        $PipelineScheduleId,

        [Parameter(Mandatory=$true)]
        [string]
        $Key
    )

    $Project = Get-GitlabProject $ProjectId -SiteUrl $SiteUrl
    $PipelineSchedule = Get-GitlabPipelineSchedule -ProjectId $ProjectId -PipelineScheduleId $PipelineScheduleId


    $GitlabApiArguments = @{
        HttpMethod = "DELETE"
        Path       = "projects/$($Project.Id)/pipeline_schedules/$($PipelineSchedule.Id)/$($Key)"
        SiteUrl    = $SiteUrl
    }

    Invoke-GitlabApi @GitlabApiArguments -WhatIf:$WhatIf | New-WrapperObject "Gitlab.PipelineScheduleVariable"
    $Wrapper | Add-Member -MemberType 'NoteProperty' -Name 'ProjectId' -Value $Project.Id
    $Wrapper | Add-Member -MemberType 'NoteProperty' -Name 'PipelineScheduleId' -Value $PipelineSchedule.Id
}

# https://docs.gitlab.com/ee/api/pipeline_schedules.html#run-a-scheduled-pipeline-immediately
function New-GitlabScheduledPipeline {
    param (
        [Parameter(Mandatory=$false, ValueFromPipelineByPropertyName=$true)]
        [string]
        $ProjectId = '.',

        [Parameter(Position=0, Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
        [int]
        $PipelineScheduleId,

        [Parameter(Mandatory=$false)]
        [string]
        $SiteUrl,

        [switch]
        [Parameter(Mandatory=$false)]
        $WhatIf
    )

    $Project = Get-GitlabProject -SiteUrl $SiteUrl

    $GitlabApiArguments = @{
        HttpMethod = 'POST'
        Path       = "projects/$($Project.Id)/pipeline_schedules/$PipelineScheduleId/play"
        SiteUrl    = $SiteUrl
    }

    Invoke-GitlabApi @GitlabApiArguments -WhatIf:$WhatIf | Select-Object -ExpandProperty 'message'
}

# https://docs.gitlab.com/ee/api/jobs.html#list-pipeline-bridges
function Get-GitlabPipelineBridge {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$false, ValueFromPipelineByPropertyName=$true)]
        [string]
        $ProjectId = '.',

        [Parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
        [string]
        $PipelineId,

        [Parameter(Mandatory=$false)]
        [string]
        [ValidateSet("created","pending","running","failed","success","canceled","skipped","manual")]
        $Scope,

        [Parameter(Mandatory=$false)]
        [string]
        $SiteUrl,

        [switch]
        [Parameter(Mandatory=$false)]
        $WhatIf
    )
    $ProjectId = $(Get-GitlabProject -ProjectId $ProjectId).Id

    $GitlabApiArguments = @{
        HttpMethod = "GET"
        Path       = "projects/$ProjectId/pipelines/$PipelineId/bridges"
        Query      = @{}
        SiteUrl    = $SiteUrl
    }

    if($Scope) {
        $GitlabApiArguments['Query']['scope'] = $Scope
    }

    Invoke-GitlabApi @GitlabApiArguments -WhatIf:$WhatIf | New-WrapperObject "Gitlab.PipelineBridge"
}

function New-GitlabPipeline {
    [CmdletBinding(SupportsShouldProcess)]
    [Alias('build')]
    param (
        [Parameter(ValueFromPipelineByPropertyName)]
        [string]
        $ProjectId = '.',

        [Parameter()]
        [Alias('Branch')]
        [string]
        $Ref,

        [Parameter()]
        [Alias('vars')]
        $Variables,

        [Parameter()]
        [switch]
        $Wait,

        [Parameter()]
        [switch]
        $Follow,

        [Parameter()]
        [string]
        $SiteUrl
    )

    $Project = Get-GitlabProject -ProjectId $ProjectId
    $ProjectId = $Project.Id

    if (-not $Ref) {
        $Local = Get-LocalGitContext
        if ($Local.Project -eq $Project.PathWithNamespace) {
            $Ref = $Local.Branch
        } else {
            $Ref = $Project.DefaultBranch
        }
    }

    $Request = @{
        ref = $Ref
    }

    if ($Variables) {
        $Request.variables = $Variables | ConvertTo-GitlabVariables -Type 'env_var'
    }

    $GitlabApiArguments = @{
        HttpMethod = "POST"
        Path       = "projects/$ProjectId/pipeline"
        Body       = $Request
        SiteUrl    = $SiteUrl
    }

    if ($PSCmdlet.ShouldProcess("$($Project.PathWithNamespace)", "create new pipeline $($Request | ConvertTo-Json)")) {
        $Pipeline = Invoke-GitlabApi @GitlabApiArguments | New-WrapperObject 'Gitlab.Pipeline'

        if ($Wait) {
            Write-Host "$($Pipeline.Id) created..."
            while ($True) {
                Start-Sleep -Seconds 5
                $Jobs = $Pipeline | Get-GitlabJob -IncludeTrace |
                    Where-Object { $_.Status -ne 'manual' -and $_.Status -ne 'skipped' -and $_.Status -ne 'created' } |
                    Sort-Object CreatedAt

                if ($Jobs) {
                    Clear-Host
                    Write-Host "$($Pipeline.WebUrl)"
                    Write-Host
                    $Jobs |
                        Where-Object { $_.Status -eq 'success' } |
                            ForEach-Object {
                                Write-Host "[$($_.Name)] ✅" -ForegroundColor DarkGreen
                            }
                    $Jobs |
                        Where-Object { $_.Status -eq 'failed' } |
                            ForEach-Object {
                                Write-Host "[$($_.Name)] ❌" -ForegroundColor DarkRed
                        }
                    Write-Host

                    $InProgress = $Jobs |
                        Where-Object { $_.Status -ne 'success' -and $_.Status -ne 'failed' }
                    if ($InProgress) {
                        $InProgress |
                            ForEach-Object {
                                Write-Host "[$($_.Name)] ⏳" -ForegroundColor DarkYellow
                                $RecentProgress = $_.Trace -split "`n" | Select-Object -Last 15
                                $RecentProgress | ForEach-Object {
                                    Write-Host "  $_"
                            }
                        }
                    }
                    else {
                        break;
                    }
                }
            }
        }

        if ($Follow) {
            Start-Process $Pipeline.WebUrl
        } else {
            $Pipeline
        }
    }
}

function Remove-GitlabPipeline {
    [CmdletBinding(SupportsShouldProcess)]

    param (
        [Parameter(ValueFromPipelineByPropertyName)]
        [string]
        $ProjectId = '.',

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('Id')]
        [string]
        $PipelineId,

        [Parameter()]
        [string]
        $SiteUrl
    )

    $Project = Get-GitlabProject $ProjectId -SiteUrl $SiteUrl
    $Pipeline = Get-GitlabPipeline -ProjectId $ProjectId -PipelineId $PipelineId -SiteUrl $SiteUrl

    if ($PSCmdlet.ShouldProcess("$($Project.PathWithNamespace)", "delete pipeline $PipelineId")) {
        Invoke-GitlabApi DELETE "projects/$($Project.Id)/pipelines/$($Pipeline.Id)" -SiteUrl $SiteUrl -WhatIf:$WhatIf | Out-Null
        Write-Host "$PipelineId deleted from $($Project.Name)"
    }
}