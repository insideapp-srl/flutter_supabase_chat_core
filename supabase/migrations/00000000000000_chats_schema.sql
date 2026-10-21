-- Local development stack only (`supabase start`): PostgREST is configured to
-- expose the `chats` schema (see config.toml) and refuses to start if it
-- doesn't exist yet. The real schema is applied afterwards from
-- example/utils/sql by tool/local_db.sh, exactly as end users apply it.
CREATE SCHEMA IF NOT EXISTS chats;
