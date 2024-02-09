param(
    [string]$hostname,
    [int]$port,
    [string]$database,
    [string]$user
)

try {
    Get-Command psql.exe -ErrorAction Stop
}
catch {
    Write-Error "psql was not found. Please ensure PostgreSQL is installed and that psql is in your PATH."
    exit
}

$psqlCommand = "psql -U $user -h $hostname -p $port -d $database"

Invoke-Expression "$psqlCommand -f .\sql\01_database_schema.sql"
Invoke-Expression "$psqlCommand -f .\sql\02_database_trigger.sql"
Invoke-Expression "$psqlCommand -f .\sql\03_database_policy.sql"
Invoke-Expression "$psqlCommand -f .\sql\04_storage.sql"
