// cleanup-media: deletes the storage objects of deleted chat messages.
//
// Deleting a message removes its row immediately; when it referenced a file
// in Supabase Storage, the chats.queue_media_for_deletion trigger records the
// object in chats.media_pending_deletion, because SQL alone can't delete
// objects from the storage backend. This function drains that queue: it
// removes each queued object through the Storage API and marks the row as
// processed.
//
// Invoke it periodically (see example/utils/sql/06_cleanup_media_schedule.sql
// for a pg_cron + pg_net schedule), or manually:
//   curl -X POST "$SUPABASE_URL/functions/v1/cleanup-media" \
//        -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY"
//
// It deletes with the service role, which bypasses storage RLS, so it only
// trusts what a deleted message may own: the trigger queues only attachments
// of the chat assets bucket inside the message's own room folder, and this
// function checks that again (CHAT_ASSETS_BUCKET, `<room folder>/<file>`)
// before deleting -- anything else is marked processed without touching
// Storage. Calling it only drains that queue earlier, and it is idempotent.
//
// A row whose deletion keeps failing is retried MAX_ATTEMPTS times, then left
// aside with its last error ("lastError"), so it can never block the objects
// queued after it.
import { createClient } from "jsr:@supabase/supabase-js@2";

const BATCH_SIZE = 500;
const MAX_ATTEMPTS = 5;
const SCHEMA = Deno.env.get("CHAT_SCHEMA") ?? "chats";
const ASSETS_BUCKET = Deno.env.get("CHAT_ASSETS_BUCKET") ?? "chats_assets";
// `<room uuid or legacy v1 bigint id>/<file name>`, nothing else.
const SAFE_PATH = /^(?:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9]{1,18})\/[^/]+$/i;

interface PendingRow {
  id: string;
  bucketId: string;
  path: string;
  attempts: number;
}

const isSafe = (row: PendingRow) =>
  row.bucketId === ASSETS_BUCKET &&
  SAFE_PATH.test(row.path) &&
  row.path.split("/").every((segment) => segment !== "." && segment !== "..");

Deno.serve(async (req) => {
  if (req.method !== "POST" && req.method !== "GET") {
    return Response.json({ error: "method not allowed" }, { status: 405 });
  }

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) {
    return Response.json(
      { error: "SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY not configured" },
      { status: 500 },
    );
  }

  const supabase = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const queue = () => supabase.schema(SCHEMA).from("media_pending_deletion");

  const { data, error } = await queue()
    .select("id, bucketId, path, attempts")
    .is("processedAt", null)
    .lt("attempts", MAX_ATTEMPTS)
    .order("createdAt", { ascending: true })
    .limit(BATCH_SIZE);

  if (error) {
    console.error("cleanup-media: cannot read the queue", error);
    return Response.json({ error: error.message }, { status: 500 });
  }

  const rows = (data ?? []) as PendingRow[];
  const now = () => new Date().toISOString();
  const processed: string[] = [];
  const failures: { id: string; error: string }[] = [];

  // Rows outside the chat assets folders are never deleted: closed as is.
  const rejected = rows.filter((row) => !isSafe(row));
  for (const row of rejected) {
    const { error: closeError } = await queue()
      .update({ processedAt: now(), lastError: "rejected: not a chat attachment path" })
      .eq("id", row.id);
    if (closeError) {
      console.error(`cleanup-media: cannot close rejected row ${row.id}`, closeError);
      failures.push({ id: row.id, error: closeError.message });
    }
  }

  const safe = rows.filter(isSafe);
  if (safe.length > 0) {
    // Storage's remove() treats already-missing objects as success, so a
    // retried batch never gets stuck on a file deleted by a previous run.
    const { error: batchError } = await supabase.storage
      .from(ASSETS_BUCKET)
      .remove(safe.map((r) => r.path));
    if (!batchError) {
      processed.push(...safe.map((r) => r.id));
    } else {
      // One bad row must not fail the others: retry them one by one.
      console.error("cleanup-media: batch remove failed, retrying per object", batchError);
      for (const row of safe) {
        const { error: rowError } = await supabase.storage
          .from(ASSETS_BUCKET)
          .remove([row.path]);
        if (!rowError) {
          processed.push(row.id);
          continue;
        }
        failures.push({ id: row.id, error: rowError.message });
        const { error: countError } = await queue()
          .update({ attempts: row.attempts + 1, lastError: rowError.message })
          .eq("id", row.id);
        if (countError) {
          console.error(`cleanup-media: cannot record the failure of ${row.id}`, countError);
        }
      }
    }
  }

  if (processed.length > 0) {
    const { error: updateError } = await queue()
      .update({ processedAt: now(), lastError: null })
      .in("id", processed);
    if (updateError) {
      console.error("cleanup-media: cannot mark rows processed", updateError);
      return Response.json({ error: updateError.message }, { status: 500 });
    }
  }

  return Response.json({
    processed: processed.length,
    rejected: rejected.length,
    failed: failures,
    more: rows.length === BATCH_SIZE,
  }, { status: failures.length > 0 ? 207 : 200 });
});
