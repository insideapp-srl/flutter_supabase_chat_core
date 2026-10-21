#!/bin/bash
# Automates the manual "Create a Supabase project" steps from the README:
# creates a new project (or points at an existing one) via the Supabase CLI,
# fetches its ref/anon key, writes example/lib/supabase_options_for_test.dart
# (already gitignored) and a project-secrets.local.json reference file
# (gitignored too — never commit it), then optionally runs the SQL scripts
# against the database via `supabase link` + `supabase db query --linked`.
#
# That path deliberately avoids a raw psql/TCP connection: `supabase link`
# defaults to Supavisor's IPv4-compatible pooler and resolves the right
# regional shard for you, where a direct `db.<ref>.supabase.co` connection is
# IPv6-only and simply hangs forever on a network without working IPv6 (a
# real case hit while developing this script). `supabase db query --linked`
# then runs each SQL file through that same linked connection.
#
# Requires: supabase CLI (logged in via `supabase login`), jq. psql is only
# needed for the separate manual step-by-step procedure in MIGRATION.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Pin `supabase link`'s local state (./supabase/.temp/...) to the repo root
# regardless of the caller's current directory, via the CLI's own --workdir
# flag -- see the SQL_FILES loop below.
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

command -v supabase >/dev/null 2>&1 || {
    echo "supabase CLI not found. See https://supabase.com/docs/guides/cli/getting-started" >&2
    exit 1
}
command -v jq >/dev/null 2>&1 || {
    echo "jq not found. Install it (e.g. 'apt install jq', 'brew install jq') and re-run." >&2
    exit 1
}

if ! supabase projects list >/dev/null 2>&1; then
    echo "Not logged in to the Supabase CLI — opening the login flow..."
    supabase login
fi

# Renders $1 as a heading and $2.. as a list the user can move through with
# the Up/Down arrow keys, confirming with Enter. Echoes the chosen 0-based
# index on stdout — everything else is drawn on stderr, so it's safe to
# capture with `idx=$(select_from_list ...)`.
select_from_list() {
    local prompt="$1"
    shift
    local options=("$@")
    local count=${#options[@]}
    local selected=0
    local key rest

    draw() {
        echo "$prompt" >&2
        local i
        for i in "${!options[@]}"; do
            if [[ $i -eq $selected ]]; then
                printf '  \033[36m> %s\033[0m\n' "${options[$i]}" >&2
            else
                printf '    %s\n' "${options[$i]}" >&2
            fi
        done
    }

    draw
    while true; do
        key=""
        IFS= read -rsn1 key </dev/tty || true
        if [[ $key == $'\x1b' ]]; then
            rest=""
            IFS= read -rsn2 -t 0.01 rest </dev/tty || true
            if [[ $rest == "[A" && $selected -gt 0 ]]; then
                selected=$((selected - 1))
            elif [[ $rest == "[B" && $selected -lt $((count - 1)) ]]; then
                selected=$((selected + 1))
            fi
            tput cuu "$((count + 1))" >&2
            tput ed >&2
            draw
        elif [[ -z "$key" ]]; then
            break
        fi
    done
    echo "$selected"
}

PROJECT_NAME_ARG="${1:-}"
ORG_ID_ARG="${2:-}"
REGION_ARG="${3:-}"

# Skip the create-vs-existing menu when called with a project name argument
# (keeps scripted/non-interactive usage of the old positional args working).
USE_EXISTING=0
if [[ -z "$PROJECT_NAME_ARG" ]]; then
    ACTIONS=("Create a new project" "Use an existing project")
    IDX="$(select_from_list "What do you want to do?" "${ACTIONS[@]}")"
    [[ "$IDX" -eq 1 ]] && USE_EXISTING=1
fi

if [[ "$USE_EXISTING" -eq 1 ]]; then
    PROJECTS_JSON="$(supabase projects list --output-format json)"
    # Normalize to a bare array regardless of whether this CLI version wraps
    # it as {"projects": [...]} (like "orgs list"/"api-keys" do) or not.
    PROJECTS_JSON="$(jq 'if (type == "object") and has("projects") then .projects else . end' <<<"$PROJECTS_JSON")"
    PROJECT_COUNT="$(jq 'length' <<<"$PROJECTS_JSON")"
    if [[ "$PROJECT_COUNT" -eq 0 ]]; then
        echo "No existing projects found." >&2
        exit 1
    fi
    mapfile -t PROJECT_LABELS < <(jq -r '.[] | "\(.name)  [\(.id)]  (\(.region // "?"))"' <<<"$PROJECTS_JSON")
    IDX="$(select_from_list "Select a project (↑/↓, Enter):" "${PROJECT_LABELS[@]}")"
    PROJECT_NAME="$(jq -r --argjson idx "$IDX" '.[$idx].name // empty' <<<"$PROJECTS_JSON")"
    PROJECT_REF="$(jq -r --argjson idx "$IDX" '.[$idx].id // empty' <<<"$PROJECTS_JSON")"
    ORG_ID="$(jq -r --argjson idx "$IDX" '.[$idx].organization_id // empty' <<<"$PROJECTS_JSON")"
    REGION="$(jq -r --argjson idx "$IDX" '.[$idx].region // empty' <<<"$PROJECTS_JSON")"
    DB_HOST="$(jq -r --argjson idx "$IDX" '.[$idx].database.host // empty' <<<"$PROJECTS_JSON")"
    [[ -z "$DB_HOST" ]] && DB_HOST="db.${PROJECT_REF}.supabase.co"

    echo
    echo "Supabase only shows a project's database password once, at creation time."
    read -rsp "Database password for '$PROJECT_NAME' (leave blank to skip preparing the database now): " DB_PASSWORD
    echo
else
    ORG_ID="$ORG_ID_ARG"
    if [[ -z "$ORG_ID" ]]; then
        ORGS_JSON="$(supabase orgs list --output-format json)"
        ORG_COUNT="$(jq '.organizations | length' <<<"$ORGS_JSON")"
        if [[ "$ORG_COUNT" -eq 0 ]]; then
            echo "No organizations found. Create one at https://supabase.com/dashboard/org first." >&2
            exit 1
        elif [[ "$ORG_COUNT" -eq 1 ]]; then
            ORG_ID="$(jq -r '.organizations[0].id' <<<"$ORGS_JSON")"
            echo "Using organization: $(jq -r '.organizations[0].name' <<<"$ORGS_JSON") ($ORG_ID)"
        else
            mapfile -t ORG_LABELS < <(jq -r '.organizations[] | "\(.name)  [\(.id)]"' <<<"$ORGS_JSON")
            IDX="$(select_from_list "Select an organization (↑/↓, Enter):" "${ORG_LABELS[@]}")"
            ORG_ID="$(jq -r --argjson idx "$IDX" '.organizations[$idx].id' <<<"$ORGS_JSON")"
        fi
    fi

    PROJECT_NAME="$PROJECT_NAME_ARG"
    if [[ -z "$PROJECT_NAME" ]]; then
        read -rp "Project name [demo-chat]: " PROJECT_NAME
        PROJECT_NAME="${PROJECT_NAME:-demo-chat}"
    fi

    # Keep in sync with the --region choices listed by `supabase projects create --help`.
    REGIONS=(ap-east-1 ap-northeast-1 ap-northeast-2 ap-south-1 ap-southeast-1 ap-southeast-2
        ca-central-1 eu-central-1 eu-central-2 eu-north-1 eu-west-1 eu-west-2 eu-west-3
        sa-east-1 us-east-1 us-east-2 us-west-1 us-west-2)

    REGION="$REGION_ARG"
    if [[ -z "$REGION" ]]; then
        IDX="$(select_from_list "Select a region (↑/↓, Enter):" "${REGIONS[@]}")"
        REGION="${REGIONS[$IDX]}"
    fi

    # The database password can only be set at creation time and Supabase
    # never shows it again — generate a strong one instead of asking for it,
    # it's saved in the secrets file below.
    DB_PASSWORD="$(openssl rand -base64 24)"

    echo "Creating project '$PROJECT_NAME' (this can take a minute)..."
    CREATE_JSON="$(supabase projects create "$PROJECT_NAME" --org-id "$ORG_ID" --db-password "$DB_PASSWORD" --region "$REGION" --output-format json)"

    PROJECT_REF="$(jq -r '.id // empty' <<<"$CREATE_JSON")"
    if [[ -z "$PROJECT_REF" ]]; then
        echo "Could not read the project ref from 'supabase projects create' output:" >&2
        echo "$CREATE_JSON" >&2
        exit 1
    fi

    DB_HOST="$(jq -r '.database.host // empty' <<<"$CREATE_JSON")"
    [[ -z "$DB_HOST" ]] && DB_HOST="db.${PROJECT_REF}.supabase.co"
fi

echo "Fetching API keys..."
KEYS_JSON="$(supabase projects api-keys --project-ref "$PROJECT_REF" --reveal --output-format json)"

# Projects can carry both the new key system (type "publishable"/"secret")
# and the legacy one (name "anon"/"service_role") during the migration
# window -- prefer the new type, falling back to the legacy name.
ANON_KEY="$(jq -r '
    ([.keys[] | select(.type=="publishable")] + [.keys[] | select(.name=="anon")])[0].api_key // empty
' <<<"$KEYS_JSON")"
SERVICE_KEY="$(jq -r '
    ([.keys[] | select(.type=="secret")] + [.keys[] | select(.name=="service_role")])[0].api_key // empty
' <<<"$KEYS_JSON")"

if [[ -z "$ANON_KEY" ]]; then
    echo "Could not find the anon/publishable key in the API keys response. Raw output:" >&2
    echo "$KEYS_JSON" >&2
    exit 1
fi

PROJECT_URL="https://${PROJECT_REF}.supabase.co"

OPTIONS_FILE="$SCRIPT_DIR/../lib/supabase_options_for_test.dart"
cat >"$OPTIONS_FILE" <<EOF
class SupabaseOptions {
  final String url;
  final String anonKey;

  SupabaseOptions({
    required this.url,
    required this.anonKey,
  });
}

final SupabaseOptions supabaseOptions = SupabaseOptions(
  url: '$PROJECT_URL',
  anonKey: '$ANON_KEY',
);
EOF
echo "Wrote $OPTIONS_FILE"

# main.dart imports the tracked supabase_options.dart (a placeholder
# template — never overwrite it with real secrets). main_test.dart is a
# generated, gitignored copy that imports supabase_options_for_test.dart
# instead, so `flutter run -t lib/main_test.dart` uses your real project
# without ever touching a tracked file.
MAIN_TEST_FILE="$SCRIPT_DIR/../lib/main_test.dart"
sed "s/'supabase_options.dart'/'supabase_options_for_test.dart'/" "$SCRIPT_DIR/../lib/main.dart" >"$MAIN_TEST_FILE"
echo "Wrote $MAIN_TEST_FILE — run the app with: flutter run -t lib/main_test.dart"

SECRETS_FILE="$SCRIPT_DIR/project-secrets.local.json"
jq -n \
    --arg name "$PROJECT_NAME" \
    --arg ref "$PROJECT_REF" \
    --arg org_id "$ORG_ID" \
    --arg region "$REGION" \
    --arg url "$PROJECT_URL" \
    --arg anon_key "$ANON_KEY" \
    --arg service_role_key "$SERVICE_KEY" \
    --arg db_host "$DB_HOST" \
    --arg db_password "$DB_PASSWORD" \
    '{
        _warning: "Contains secrets. Never commit this file (already gitignored).",
        name: $name, ref: $ref, org_id: $org_id, region: $region, url: $url,
        anon_key: $anon_key, service_role_key: $service_role_key,
        db: {host: $db_host, port: 5432, database: "postgres", user: "postgres", password: $db_password}
    }' >"$SECRETS_FILE"
chmod 600 "$SECRETS_FILE"

echo
echo "Project reference and secrets saved to: $SECRETS_FILE"
echo "This file is gitignored — never commit it."
echo

DB_PREPARED=0

# Order matters: 01 creates the schema/tables, 02 the triggers, 03 the RLS
# policies, 04 the storage bucket/policies, 05 the views, 99 the final
# permission grants.
SQL_FILES=(01_database_schema.sql 02_database_trigger.sql 03_database_policy.sql
    04_storage.sql 05_database_view.sql 99_database_schema_permission.sql)
LINK_CMD="supabase link --project-ref $PROJECT_REF -p '<db-password>' --workdir '$REPO_ROOT'"
RUN_CMDS="$(for f in "${SQL_FILES[@]}"; do echo "supabase db query --linked --file '$SCRIPT_DIR/sql/$f' --workdir '$REPO_ROOT'"; done)"
MANUAL_CMD="$LINK_CMD
$RUN_CMDS"

if [[ -z "$DB_PASSWORD" ]]; then
    echo "No database password provided — skipping database preparation. Run it yourself once you have it:"
    echo "  $MANUAL_CMD"
else
    read -rp "Run the database preparation scripts now? [Y/n] " RUN_PREPARE
    if [[ "${RUN_PREPARE:-Y}" != "n" && "${RUN_PREPARE:-Y}" != "N" ]]; then
        MAX_ATTEMPTS=24
        echo "Linking to the project (up to $((MAX_ATTEMPTS * 5))s — a freshly created project can take a minute or two to finish provisioning)..."
        LINKED=0
        for i in $(seq 1 "$MAX_ATTEMPTS"); do
            echo "  attempt $i/$MAX_ATTEMPTS..."
            if supabase link --project-ref "$PROJECT_REF" -p "$DB_PASSWORD" --workdir "$REPO_ROOT" >/dev/null 2>&1; then
                LINKED=1
                break
            fi
            [[ "$i" -lt "$MAX_ATTEMPTS" ]] && sleep 5
        done

        if [[ "$LINKED" -ne 1 ]]; then
            echo "Could not link to the project after $((MAX_ATTEMPTS * 5))s. Run the commands yourself once it's up:" >&2
            echo "  $MANUAL_CMD" >&2
        else
            FAILED=0
            for f in "${SQL_FILES[@]}"; do
                echo "Running $f..."
                if ! supabase db query --linked --file "$SCRIPT_DIR/sql/$f" --workdir "$REPO_ROOT"; then
                    echo "$f failed — stopping. Fix the error, then re-run the remaining files yourself:" >&2
                    echo "  $RUN_CMDS" >&2
                    FAILED=1
                    break
                fi
            done
            [[ "$FAILED" -eq 0 ]] && DB_PREPARED=1
        fi
    fi
fi

echo
if [[ "$DB_PREPARED" -eq 1 ]]; then
    echo "Done. In the Supabase dashboard, expose the 'chats' schema under Database > API Settings > Exposed schemas."
else
    echo "Project created, but the database was NOT prepared yet — run the command shown above once you can, then expose the 'chats' schema under Database > API Settings > Exposed schemas in the Supabase dashboard."
fi
