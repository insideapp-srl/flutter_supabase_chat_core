# Automates the manual "Create a Supabase project" steps from the README:
# creates a new project (or points at an existing one) via the Supabase CLI,
# fetches its ref/anon key, writes example/lib/supabase_options_for_test.dart
# (already gitignored) and a project-secrets.local.json reference file
# (gitignored too -- never commit it), then optionally runs the SQL scripts
# against the database via `supabase link` + `supabase db query --linked`.
#
# That path deliberately avoids a raw psql/TCP connection: `supabase link`
# defaults to Supavisor's IPv4-compatible pooler and resolves the right
# regional shard for you, where a direct `db.<ref>.supabase.co` connection is
# IPv6-only and simply hangs forever on a network without working IPv6 (a
# real case hit while developing this script). `supabase db query --linked`
# then runs each SQL file through that same linked connection.
#
# Requires: supabase CLI (logged in via `supabase login`). psql is only
# needed for the separate manual step-by-step procedure in MIGRATION.md.
param(
    [string]$ProjectName,
    [string]$OrgId,
    [string]$Region
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# Pin `supabase link`'s local state (./supabase/.temp/...) to the repo root
# regardless of the caller's current directory, via the CLI's own --workdir
# flag -- see the SqlFiles loop below.
$repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)

try {
    Get-Command supabase -ErrorAction Stop | Out-Null
}
catch {
    Write-Error "supabase CLI was not found. See https://supabase.com/docs/guides/cli/getting-started"
    exit 1
}

try {
    # Only stdout is redirected here -- redirecting a native command's
    # stderr (e.g. with `*>`) makes PowerShell 5.1 treat it as a terminating
    # error under $ErrorActionPreference = 'Stop', which would abort the
    # script on the very "not logged in" message we're checking for.
    supabase projects list | Out-Null
}
catch {
    # Not logged in yet -- fall through to the login flow below.
}
if ($LASTEXITCODE -ne 0) {
    Write-Host "Not logged in to the Supabase CLI -- opening the login flow..."
    supabase login
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Supabase login failed."
        exit 1
    }
}

# Renders $Options under $Prompt and lets the user move through them with
# the Up/Down arrow keys, confirming with Enter. Returns the chosen 0-based
# index.
function Select-FromList {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][string[]]$Options
    )
    $selected = 0
    $padWidth = (($Options | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum) + 6
    $drawn = $false
    while ($true) {
        if ($drawn) {
            [Console]::SetCursorPosition(0, [Console]::CursorTop - ($Options.Count + 1))
        }
        $drawn = $true
        Write-Host $Prompt
        for ($i = 0; $i -lt $Options.Count; $i++) {
            if ($i -eq $selected) {
                Write-Host ("  > " + $Options[$i]).PadRight($padWidth) -ForegroundColor Cyan
            }
            else {
                Write-Host ("    " + $Options[$i]).PadRight($padWidth)
            }
        }
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::UpArrow -and $selected -gt 0) { $selected-- }
        elseif ($key.Key -eq [ConsoleKey]::DownArrow -and $selected -lt ($Options.Count - 1)) { $selected++ }
        elseif ($key.Key -eq [ConsoleKey]::Enter) { return $selected }
    }
}

# Skip the create-vs-existing menu when called with -ProjectName (keeps
# scripted/non-interactive usage of the old parameters working).
$useExisting = $false
if (-not $ProjectName) {
    $actionIndex = Select-FromList -Prompt "What do you want to do?" -Options @("Create a new project", "Use an existing project")
    if ($actionIndex -eq 1) { $useExisting = $true }
}

if ($useExisting) {
    $projectsJson = supabase projects list --output-format json | Out-String
    $projectsParsed = $projectsJson | ConvertFrom-Json
    # Normalize regardless of whether this CLI version wraps the list as
    # {"projects": [...]} (like "orgs list"/"api-keys" do) or not.
    if ($projectsParsed.PSObject.Properties.Name -contains 'projects') {
        $projects = @($projectsParsed.projects)
    }
    else {
        $projects = @($projectsParsed)
    }
    if ($projects.Count -eq 0) {
        Write-Error "No existing projects found."
        exit 1
    }
    $labels = @($projects | ForEach-Object {
            $regionDisplay = if ($_.region) { $_.region } else { '?' }
            "$($_.name)  [$($_.id)]  ($regionDisplay)"
        })
    $index = Select-FromList -Prompt "Select a project (Up/Down, Enter):" -Options $labels
    $ProjectName = $projects[$index].name
    $ProjectRef = $projects[$index].id
    $OrgId = $projects[$index].organization_id
    $Region = $projects[$index].region
    $DbHost = $projects[$index].database.host
    if (-not $DbHost) { $DbHost = "db.$ProjectRef.supabase.co" }

    Write-Host ""
    Write-Host "Supabase only shows a project's database password once, at creation time."
    $securePassword = Read-Host "Database password for '$ProjectName' (leave blank to skip preparing the database now)" -AsSecureString
    $DbPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    )
}
else {
    if (-not $OrgId) {
        $orgsJson = supabase orgs list --output-format json | Out-String
        $orgs = @(($orgsJson | ConvertFrom-Json).organizations)
        if ($orgs.Count -eq 0) {
            Write-Error "No organizations found. Create one at https://supabase.com/dashboard/org first."
            exit 1
        }
        elseif ($orgs.Count -eq 1) {
            $OrgId = $orgs[0].id
            Write-Host "Using organization: $($orgs[0].name) ($OrgId)"
        }
        else {
            $labels = @($orgs | ForEach-Object { "$($_.name)  [$($_.id)]" })
            $index = Select-FromList -Prompt "Select an organization (Up/Down, Enter):" -Options $labels
            $OrgId = $orgs[$index].id
        }
    }

    if (-not $ProjectName) {
        $ProjectName = Read-Host "Project name [demo-chat]"
        if (-not $ProjectName) { $ProjectName = "demo-chat" }
    }

    # Keep in sync with the --region choices listed by `supabase projects create --help`.
    $Regions = @(
        'ap-east-1', 'ap-northeast-1', 'ap-northeast-2', 'ap-south-1', 'ap-southeast-1', 'ap-southeast-2',
        'ca-central-1', 'eu-central-1', 'eu-central-2', 'eu-north-1', 'eu-west-1', 'eu-west-2', 'eu-west-3',
        'sa-east-1', 'us-east-1', 'us-east-2', 'us-west-1', 'us-west-2'
    )
    if (-not $Region) {
        $index = Select-FromList -Prompt "Select a region (Up/Down, Enter):" -Options $Regions
        $Region = $Regions[$index]
    }

    # The database password can only be set at creation time and Supabase
    # never shows it again -- generate a strong one instead of asking for
    # it, it's saved in the secrets file below.
    $DbPassword = ([guid]::NewGuid().ToString("N") + [guid]::NewGuid().ToString("N")).Substring(0, 32)

    Write-Host "Creating project '$ProjectName' (this can take a minute)..."
    $createJson = supabase projects create $ProjectName --org-id $OrgId --db-password $DbPassword --region $Region --output-format json | Out-String
    $create = $createJson | ConvertFrom-Json

    $ProjectRef = $create.id
    if (-not $ProjectRef) {
        Write-Error "Could not read the project ref from 'supabase projects create' output:`n$createJson"
        exit 1
    }

    $DbHost = $create.database.host
    if (-not $DbHost) { $DbHost = "db.$ProjectRef.supabase.co" }
}

Write-Host "Fetching API keys..."
$keysJson = supabase projects api-keys --project-ref $ProjectRef --reveal --output-format json | Out-String
$keys = @(($keysJson | ConvertFrom-Json).keys)

# Projects can carry both the new key system (type "publishable"/"secret")
# and the legacy one (name "anon"/"service_role") during the migration
# window -- prefer the new type, falling back to the legacy name.
$anonKeyEntry = $keys | Where-Object { $_.type -eq 'publishable' } | Select-Object -First 1
if (-not $anonKeyEntry) {
    $anonKeyEntry = $keys | Where-Object { $_.name -eq 'anon' } | Select-Object -First 1
}
$serviceKeyEntry = $keys | Where-Object { $_.type -eq 'secret' } | Select-Object -First 1
if (-not $serviceKeyEntry) {
    $serviceKeyEntry = $keys | Where-Object { $_.name -eq 'service_role' } | Select-Object -First 1
}

if (-not $anonKeyEntry) {
    Write-Error "Could not find the anon/publishable key in the API keys response. Raw output:`n$keysJson"
    exit 1
}
$AnonKey = $anonKeyEntry.api_key
$ServiceKey = if ($serviceKeyEntry) { $serviceKeyEntry.api_key } else { "" }

$ProjectUrl = "https://$ProjectRef.supabase.co"

$optionsPath = Join-Path $scriptDir "..\lib\supabase_options_for_test.dart"
@"
class SupabaseOptions {
  final String url;
  final String anonKey;

  SupabaseOptions({
    required this.url,
    required this.anonKey,
  });
}

final SupabaseOptions supabaseOptions = SupabaseOptions(
  url: '$ProjectUrl',
  anonKey: '$AnonKey',
);
"@ | Out-File -FilePath $optionsPath -Encoding utf8
Write-Host "Wrote $optionsPath"

# main.dart imports the tracked supabase_options.dart (a placeholder
# template -- never overwrite it with real secrets). main_test.dart is a
# generated, gitignored copy that imports supabase_options_for_test.dart
# instead, so `flutter run -t lib/main_test.dart` uses your real project
# without ever touching a tracked file.
$mainTestPath = Join-Path $scriptDir "..\lib\main_test.dart"
(Get-Content -Raw (Join-Path $scriptDir "..\lib\main.dart")) `
    -replace "'supabase_options\.dart'", "'supabase_options_for_test.dart'" |
    Out-File -FilePath $mainTestPath -Encoding utf8
Write-Host "Wrote $mainTestPath -- run the app with: flutter run -t lib/main_test.dart"

$secrets = [ordered]@{
    _warning = "Contains secrets. Never commit this file (already gitignored)."
    name     = $ProjectName
    ref      = $ProjectRef
    org_id   = $OrgId
    region   = $Region
    url      = $ProjectUrl
    anon_key = $AnonKey
    service_role_key = $ServiceKey
    db       = [ordered]@{
        host     = $DbHost
        port     = 5432
        database = "postgres"
        user     = "postgres"
        password = $DbPassword
    }
}
$secretsPath = Join-Path $scriptDir "project-secrets.local.json"
$secrets | ConvertTo-Json -Depth 5 | Out-File -FilePath $secretsPath -Encoding utf8

Write-Host ""
Write-Host "Project reference and secrets saved to: $secretsPath"
Write-Host "This file is gitignored -- never commit it."
Write-Host ""

$dbPrepared = $false

# Order matters: 01 creates the schema/tables, 02 the triggers, 03 the RLS
# policies, 04 the storage bucket/policies, 05 the views, 99 the final
# permission grants.
$SqlFiles = @(
    '01_database_schema.sql', '02_database_trigger.sql', '03_database_policy.sql',
    '04_storage.sql', '05_database_view.sql', '99_database_schema_permission.sql'
)
$linkCommand = "supabase link --project-ref $ProjectRef -p '<db-password>' --workdir '$repoRoot'"
$runCommands = ($SqlFiles | ForEach-Object { "supabase db query --linked --file '$scriptDir\sql\$_' --workdir '$repoRoot'" }) -join "`n  "
$manualCommand = "$linkCommand`n  $runCommands"

if (-not $DbPassword) {
    Write-Host "No database password provided -- skipping database preparation. Run it yourself once you have it:"
    Write-Host "  $manualCommand"
}
else {
    $runPrepare = Read-Host "Run the database preparation scripts now? [Y/n]"
    if ($runPrepare -ne 'n' -and $runPrepare -ne 'N') {
        $maxAttempts = 24
        Write-Host "Linking to the project (up to $($maxAttempts * 5)s -- a freshly created project can take a minute or two to finish provisioning)..."
        $linked = $false
        for ($i = 1; $i -le $maxAttempts; $i++) {
            Write-Host "  attempt $i/$maxAttempts..."
            try {
                supabase link --project-ref $ProjectRef -p $DbPassword --workdir $repoRoot 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) { $linked = $true; break }
            }
            catch {
                # Not ready yet -- keep retrying.
            }
            if ($i -lt $maxAttempts) { Start-Sleep -Seconds 5 }
        }

        if (-not $linked) {
            Write-Warning "Could not link to the project after $($maxAttempts * 5)s. Run the commands yourself once it's up:"
            Write-Host "  $manualCommand"
        }
        else {
            $failed = $false
            foreach ($sqlFile in $SqlFiles) {
                Write-Host "Running $sqlFile..."
                $path = Join-Path $scriptDir "sql\$sqlFile"
                supabase db query --linked --file $path --workdir $repoRoot | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "$sqlFile failed -- stopping. Fix the error, then re-run the remaining files yourself:"
                    Write-Host "  $runCommands"
                    $failed = $true
                    break
                }
            }
            $dbPrepared = -not $failed
        }
    }
}

Write-Host ""
if ($dbPrepared) {
    Write-Host "Done. In the Supabase dashboard, expose the 'chats' schema under Database > API Settings > Exposed schemas."
}
else {
    Write-Host "Project created, but the database was NOT prepared yet -- run the command shown above once you can, then expose the 'chats' schema under Database > API Settings > Exposed schemas in the Supabase dashboard."
}
