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
// Safe to call by anyone holding a valid JWT: it only ever deletes objects
// whose message is already gone, and it is idempotent.
import { createClient } from "jsr:@supabase/supabase-js@2";

const BATCH_SIZE = 500;
const SCHEMA = Deno.env.get("CHAT_SCHEMA") ?? "chats";

interface PendingRow {
  id: string;
  bucketId: string;
  path: string;
}

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

  const { data, error } = await supabase
    .schema(SCHEMA)
    .from("media_pending_deletion")
    .select("id, bucketId, path")
    .is("processedAt", null)
    .order("createdAt", { ascending: true })
    .limit(BATCH_SIZE);

  if (error) {
    console.error("cleanup-media: cannot read the queue", error);
    return Response.json({ error: error.message }, { status: 500 });
  }

  const rows = (data ?? []) as PendingRow[];
  const byBucket = new Map<string, PendingRow[]>();
  for (const row of rows) {
    const list = byBucket.get(row.bucketId) ?? [];
    list.push(row);
    byBucket.set(row.bucketId, list);
  }

  const processed: string[] = [];
  const failures: { bucketId: string; error: string }[] = [];

  for (const [bucketId, bucketRows] of byBucket) {
    // Storage's remove() treats already-missing objects as success, so a
    // retried batch never gets stuck on a file deleted by a previous run.
    const { error: removeError } = await supabase.storage
      .from(bucketId)
      .remove(bucketRows.map((r) => r.path));
    if (removeError) {
      console.error(`cleanup-media: cannot remove from ${bucketId}`, removeError);
      failures.push({ bucketId, error: removeError.message });
      continue;
    }
    processed.push(...bucketRows.map((r) => r.id));
  }

  if (processed.length > 0) {
    const { error: updateError } = await supabase
      .schema(SCHEMA)
      .from("media_pending_deletion")
      .update({ processedAt: new Date().toISOString() })
      .in("id", processed);
    if (updateError) {
      console.error("cleanup-media: cannot mark rows processed", updateError);
      return Response.json({ error: updateError.message }, { status: 500 });
    }
  }

  return Response.json({
    processed: processed.length,
    failed: failures,
    more: rows.length === BATCH_SIZE,
  }, { status: failures.length > 0 ? 207 : 200 });
});
