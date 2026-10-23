-- OPTIONAL: schedules the cleanup-media Edge Function (supabase/functions/
-- cleanup-media), which deletes the storage objects of deleted messages
-- queued in chats.media_pending_deletion. Without it, deleted messages'
-- files simply stay in the bucket (the queue keeps growing, nothing breaks).
--
-- Prerequisites:
--   1. Deploy the function:  supabase functions deploy cleanup-media
--   2. Store the project URL and a service role key in Vault, once (run in
--      the SQL editor, replacing the placeholders -- never commit real keys):
--
--        select vault.create_secret('https://<project-ref>.supabase.co', 'chats_project_url');
--        select vault.create_secret('<service-role-key>', 'chats_service_role_key');
--
-- Then run this file. It schedules the call every 15 minutes through pg_cron
-- + pg_net (both available on Supabase), reading the secrets at run time.
-- Re-running it is safe (the job is replaced).

CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_cron;

DO $do$
BEGIN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'chats-cleanup-media') THEN
        PERFORM cron.unschedule('chats-cleanup-media');
    END IF;

    PERFORM cron.schedule(
        'chats-cleanup-media',
        '*/15 * * * *',
        $sql$
        SELECT net.http_post(
            url := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'chats_project_url')
                   || '/functions/v1/cleanup-media',
            headers := jsonb_build_object(
                'Content-Type', 'application/json',
                'Authorization', 'Bearer ' || (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'chats_service_role_key')
            ),
            body := '{}'::jsonb
        )
        -- Same rows cleanup-media picks up: rows left aside after too many
        -- failed attempts (see "lastError") don't keep the job firing.
        WHERE EXISTS (SELECT 1 FROM chats.media_pending_deletion WHERE "processedAt" IS NULL AND attempts < 5);
        $sql$
    );
END
$do$;
