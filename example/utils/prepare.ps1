# Applies the chat schema to a Supabase/Postgres database:
#   .\prepare.ps1 -hostname <host> -port <port> -database <database> -user <user>
# Asks for the database password once (or reads $env:PGPASSWORD), and stops at
# the first failing script so the database is never left half prepared. Every
# script is idempotent: re-running is safe, also to migrate a v1 database.
param(
    [Parameter(Mandatory = $true)][string]$hostname,
    [Parameter(Mandatory = $true)][int]$port,
    [Parameter(Mandatory = $true)][string]$database,
    [Parameter(Mandatory = $true)][string]$user
)

if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
    Write-Error "psql was not found. Please ensure PostgreSQL is installed and that psql is in your PATH."
    exit 1
}

if (-not $env:PGPASSWORD) {
    $secure = Read-Host "Password for $user@$hostname" -AsSecureString
    $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}

$sqlDir = Join-Path $PSScriptRoot 'sql'
$files = @(
    '01_database_schema.sql', '02_database_trigger.sql', '03_database_policy.sql',
    '04_storage.sql', '05_database_view.sql', '99_database_schema_permission.sql'
)
foreach ($file in $files) {
    Write-Host "applying $file"
    & psql -U $user -h $hostname -p $port -d $database -v ON_ERROR_STOP=1 -q -f (Join-Path $sqlDir $file)
    if ($LASTEXITCODE -ne 0) {
        Write-Error "$file failed (exit code $LASTEXITCODE): the remaining scripts were not applied."
        exit $LASTEXITCODE
    }
}
Write-Host "done"
