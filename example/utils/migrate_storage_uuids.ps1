# Moves chats_assets storage objects from their old bigint room-id folder
# (chats_assets/<old numeric id>/...) to the new uuid folder
# (chats_assets/<new uuid>/...) after 01_database_schema.sql converts
# chats.rooms to uuid ids. SQL alone can't rename objects in the storage
# backend, so this is a separate step using the Supabase CLI's Storage API
# (`supabase storage mv`) -- run it once, after 01_database_schema.sql,
# during the same maintenance window.
#
# Reads the old-id -> new-id mapping from chats.room_id_migration_map (left
# behind by 01_database_schema.sql for exactly this purpose).
#
# Requires: supabase CLI (logged in), psql.
param(
    [string]$hostname,
    [int]$port = 5432,
    [string]$database = "postgres",
    [string]$user = "postgres",
    [string]$ProjectRef
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$secretsFile = Join-Path $scriptDir "project-secrets.local.json"
$dbPassword = $null

if (-not $hostname -and (Test-Path $secretsFile)) {
    Write-Host "No -hostname given: reading connection info from $secretsFile"
    $secrets = Get-Content -Raw $secretsFile | ConvertFrom-Json
    $hostname = $secrets.db.host
    $port = $secrets.db.port
    $database = $secrets.db.database
    $user = $secrets.db.user
    $dbPassword = $secrets.db.password
    if (-not $ProjectRef) { $ProjectRef = $secrets.ref }
}

if (-not $hostname -or -not $ProjectRef) {
    Write-Error "Usage: .\migrate_storage_uuids.ps1 -hostname <db-host> -port <db-port> -database <db-name> -user <db-user> -ProjectRef <project-ref>`n(or run with no args from example\utils, if project-secrets.local.json is there)"
    exit 1
}

if (-not $dbPassword) {
    $securePassword = Read-Host "Database password for $user@$hostname" -AsSecureString
    $dbPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    )
}

try { Get-Command supabase -ErrorAction Stop | Out-Null }
catch { Write-Error "supabase CLI was not found. See https://supabase.com/docs/guides/cli/getting-started"; exit 1 }
try { Get-Command psql -ErrorAction Stop | Out-Null }
catch { Write-Error "psql was not found. Please ensure PostgreSQL is installed and in your PATH."; exit 1 }

Write-Host "Reading the old->new room id mapping from chats.room_id_migration_map..."
$env:PGPASSWORD = $dbPassword
$mapJson = & psql -h $hostname -p $port -d $database -U $user -Atc @"
SELECT coalesce(jsonb_agg(jsonb_build_object('old_id', old_id, 'new_id', new_id)), '[]')
FROM chats.room_id_migration_map;
"@ 2>$null
Remove-Item Env:\PGPASSWORD
if (-not $mapJson) { $mapJson = "[]" }

$map = @($mapJson | ConvertFrom-Json)
if ($map.Count -eq 0) {
    Write-Host "chats.room_id_migration_map is empty or doesn't exist -- nothing to migrate"
    Write-Host "(either this database never had bigint room ids, or 01_database_schema.sql hasn't converted any yet)."
    exit 0
}

Write-Host "Found $($map.Count) room(s) to check for chats_assets objects to move."
Write-Host ""

$moved = 0
$skipped = 0
foreach ($entry in $map) {
    $oldId = $entry.old_id
    $newId = $entry.new_id

    $lsOutput = $null
    try { $lsOutput = supabase storage ls "ss:///chats_assets/$oldId" --project-ref $ProjectRef 2>$null } catch {}

    if ($lsOutput) {
        Write-Host "Moving chats_assets/$oldId -> chats_assets/$newId"
        & supabase storage mv -r "ss:///chats_assets/$oldId" "ss:///chats_assets/$newId" --project-ref $ProjectRef
        $moved++
    }
    else {
        $skipped++
    }
}

Write-Host ""
Write-Host "Done: moved $moved room folder(s), $skipped had no chats_assets objects to move."
