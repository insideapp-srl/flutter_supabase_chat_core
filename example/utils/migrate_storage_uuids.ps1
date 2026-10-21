# Moves the chat attachments uploaded by v1 to the v2 room folders, after
# 01_database_schema.sql migrated a v1 database:
#   chats_assets/<old numeric room id>/<file> -> chats_assets/<room uuid>/<file>
#
#   .\migrate_storage_uuids.ps1 -hostname <host> -port <port> -database <database> -user <user> `
#       -apiUrl <api url> [-bucket <bucket>] [-dryRun] [-yes]
#
#   -apiUrl  Supabase API URL: https://<project-ref>.supabase.co, or the Kong
#            URL of a self-hosted instance (local stack: http://127.0.0.1:54321)
#   -bucket  attachments bucket (default chats_assets)
#   -dryRun  only print what would be moved
#   -yes     drop chats.room_id_migration_map at the end without asking
#
# Reads the database password from $env:PGPASSWORD and the service role (or
# secret) key from $env:SUPABASE_SERVICE_ROLE_KEY, asking for them when unset.
#
# For each room still using its old folder it:
#   1. copies the objects to the new folder (Storage API, server side);
#   2. rewrites the URLs of the room in one transaction: messages.source and
#      rooms."imageUrl" (the "lastMessages" snapshot follows by trigger);
#   3. deletes the old objects, only once every copy exists.
# A failure stops the script and nothing is lost: run it again, it resumes
# from where it stopped. Until a room is moved its old URLs keep working
# (the storage policies resolve the old folders through
# chats.room_id_migration_map). When no room is left, the map is no longer
# needed and is dropped (asking first, unless -yes).
#
# Requires: psql.
param(
    [Parameter(Mandatory = $true)][string]$hostname,
    [Parameter(Mandatory = $true)][int]$port,
    [Parameter(Mandatory = $true)][string]$database,
    [Parameter(Mandatory = $true)][string]$user,
    [Parameter(Mandatory = $true)][string]$apiUrl,
    [string]$bucket = 'chats_assets',
    [switch]$dryRun,
    [switch]$yes
)
$ErrorActionPreference = 'Stop'

if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
    Write-Error "psql was not found. Please ensure PostgreSQL is installed and that psql is in your PATH."
    exit 1
}
if ($bucket -notmatch '^[A-Za-z0-9_.-]+$') {
    Write-Error "invalid bucket name: $bucket"
    exit 1
}
$apiUrl = $apiUrl.TrimEnd('/')

function Read-Secret([string]$prompt) {
    $secure = Read-Host $prompt -AsSecureString
    return [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}
if (-not $env:PGPASSWORD) { $env:PGPASSWORD = Read-Secret "Password for $user@$hostname" }
$serviceKey = $env:SUPABASE_SERVICE_ROLE_KEY
if (-not $serviceKey) { $serviceKey = Read-Secret 'Service role (or secret) key' }

# File names travel through psql's output: keep them UTF-8 end to end.
$env:PGCLIENTENCODING = 'UTF8'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

# Runs a query and returns its output lines (unaligned, tuples only).
function Invoke-Sql([string]$query) {
    $lines = $query | & psql -h $hostname -p $port -d $database -U $user -v ON_ERROR_STOP=1 -X -q -At
    if ($LASTEXITCODE -ne 0) { throw "psql failed (exit code $LASTEXITCODE)" }
    return @($lines | Where-Object { $_ -ne '' })
}

# Legacy JWT keys go in Authorization too; the new sb_secret_ keys only in
# apikey (the gateway turns them into a service role JWT).
$headers = @{ apikey = $serviceKey }
if ($serviceKey.StartsWith('eyJ')) { $headers.Authorization = "Bearer $serviceKey" }

# POST/DELETE a JSON body to the Storage API, failing with its error message.
function Invoke-Storage([string]$method, [string]$path, [string]$body) {
    try {
        Invoke-RestMethod -Method $method -Uri "$apiUrl/storage/v1/$path" -Headers $headers `
            -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
    }
    catch {
        throw "Storage API $method $path failed: $($_.Exception.Message) $($_.ErrorDetails.Message)"
    }
}

if ((Invoke-Sql "SELECT to_regclass('chats.room_id_migration_map') IS NOT NULL") -ne 't') {
    Write-Host "chats.room_id_migration_map doesn't exist: no v1 room to move."
    exit 0
}

# Rooms with objects in their old folder, or URLs still pointing there.
$rooms = Invoke-Sql @"
SELECT m.old_id || ' ' || m.new_id
FROM chats.room_id_migration_map m
WHERE EXISTS (SELECT 1 FROM storage.objects o
              WHERE o.bucket_id = '$bucket' AND o.name LIKE m.old_id || '/%')
   OR EXISTS (SELECT 1 FROM chats.messages x
              WHERE x."roomId" = m.new_id AND x.source LIKE '%/$bucket/' || m.old_id || '/%')
   OR EXISTS (SELECT 1 FROM chats.rooms r
              WHERE r.id = m.new_id AND r."imageUrl" LIKE '%/$bucket/' || m.old_id || '/%')
ORDER BY m.old_id;
"@

$roomCount = 0
$objectCount = 0
foreach ($room in $rooms) {
    $oldId, $newId = $room -split ' '
    # Both come from the map (bigint, uuid): checked anyway, since they are
    # spliced into the SQL below.
    if ($oldId -notmatch '^[0-9]+$' -or $newId -notmatch '^[0-9a-f-]{36}$') {
        throw "unexpected map row: $room"
    }
    $oldPrefix = "$oldId/"
    $newPrefix = "$newId/"
    $from = $oldPrefix.Length + 1

    # Objects of the old folder not copied yet (a previous run may have
    # stopped half way), as Storage API copy requests: Postgres builds the
    # JSON, so any file name is escaped correctly.
    $copies = Invoke-Sql @"
SELECT json_build_object('bucketId', o.bucket_id, 'sourceKey', o.name,
                         'destinationKey', '$newPrefix' || substr(o.name, $from))
FROM storage.objects o
WHERE o.bucket_id = '$bucket' AND o.name LIKE '$oldPrefix%'
  AND NOT EXISTS (SELECT 1 FROM storage.objects d
                  WHERE d.bucket_id = '$bucket'
                    AND d.name = '$newPrefix' || substr(o.name, $from))
ORDER BY o.name;
"@
    Write-Host "room $oldId -> ${newId}: $($copies.Count) object(s) to copy"
    $roomCount++
    $objectCount += $copies.Count
    if ($dryRun) { continue }

    # 1. Copy.
    foreach ($body in $copies) { Invoke-Storage 'POST' 'object/copy' $body }

    # 2. Rewrite the URLs of the room, all or nothing.
    Invoke-Sql @"
BEGIN;
UPDATE chats.messages
SET source = replace(source, '/$bucket/$oldPrefix', '/$bucket/$newPrefix')
WHERE "roomId" = '$newId' AND source LIKE '%/$bucket/$oldPrefix%';
UPDATE chats.rooms
SET "imageUrl" = replace("imageUrl", '/$bucket/$oldPrefix', '/$bucket/$newPrefix')
WHERE id = '$newId' AND "imageUrl" LIKE '%/$bucket/$oldPrefix%';
COMMIT;
"@ | Out-Null

    # 3. Delete the old objects, once every one of them has its copy.
    $missing = Invoke-Sql @"
SELECT count(*) FROM storage.objects o
WHERE o.bucket_id = '$bucket' AND o.name LIKE '$oldPrefix%'
  AND NOT EXISTS (SELECT 1 FROM storage.objects d
                  WHERE d.bucket_id = '$bucket'
                    AND d.name = '$newPrefix' || substr(o.name, $from));
"@
    if ($missing -ne '0') { throw "room ${oldId}: $missing object(s) without a copy, old folder kept" }
    # The Storage API deletes at most 1000 objects per request.
    $deletes = Invoke-Sql @"
SELECT json_build_object('prefixes', json_agg(name ORDER BY name))
FROM (SELECT name, (row_number() OVER (ORDER BY name) - 1) / 1000 AS batch
      FROM storage.objects
      WHERE bucket_id = '$bucket' AND name LIKE '$oldPrefix%') o
GROUP BY batch ORDER BY batch;
"@
    foreach ($body in $deletes) { Invoke-Storage 'DELETE' "object/$bucket" $body }
}

if ($dryRun) {
    Write-Host "dry run: $roomCount room(s), $objectCount object(s) to copy"
    exit 0
}
Write-Host "moved $roomCount room(s), $objectCount object(s) copied in this run"

# Nothing points at the old folders any more: the map is no longer needed.
$left = Invoke-Sql @"
SELECT count(*) FROM chats.room_id_migration_map m
WHERE EXISTS (SELECT 1 FROM storage.objects o
              WHERE o.bucket_id = '$bucket' AND o.name LIKE m.old_id || '/%')
   OR EXISTS (SELECT 1 FROM chats.messages x
              WHERE x."roomId" = m.new_id AND x.source LIKE '%/$bucket/' || m.old_id || '/%');
"@
if ($left -ne '0') {
    Write-Error "$left room(s) still use their old folder: chats.room_id_migration_map kept"
    exit 1
}
if (-not $yes) {
    $answer = Read-Host 'Every attachment is in its v2 folder. Drop chats.room_id_migration_map? [y/N]'
    if ($answer -notmatch '^[Yy]$') {
        Write-Host 'chats.room_id_migration_map kept'
        exit 0
    }
}
Invoke-Sql 'DROP TABLE chats.room_id_migration_map' | Out-Null
Write-Host 'chats.room_id_migration_map dropped'
