#!/usr/bin/env bash
# Seeds a Supabase project with demo users and conversations, e.g. to try
# the example app or take screenshots:
#   tool/local_db.sh && tool/seed_demo.sh          # local stack
#   tool/seed_demo.sh --project-ref <ref>          # cloud project (CLI login)
# Every demo user signs in with password "Demo-password-1":
#   alice@demo.dev (main account), bob@demo.dev, carol@demo.dev,
#   dave@demo.dev, erin@demo.dev
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
PROJECT_REF=""
if [[ "${1:-}" == "--project-ref" ]]; then PROJECT_REF="${2:?--project-ref needs a ref}"; fi

if [[ -n "$PROJECT_REF" ]]; then
    # Cloud: keys from the CLI, SQL through the Management API (no password).
    API_URL="https://$PROJECT_REF.supabase.co"
    SERVICE_ROLE_KEY="$(supabase projects api-keys --project-ref "$PROJECT_REF" -o json 2>/dev/null |
        python -c "import sys,json;print(next(k['api_key'] for k in json.load(sys.stdin) if k['name']=='service_role'))")"
else
    eval "$(supabase status -o env 2>/dev/null | grep -E '^(API_URL|SERVICE_ROLE_KEY)=')"
fi

# Runs SQL (stdin, or -c) and prints the first column of each row.
sql() {
    if [[ -n "$PROJECT_REF" ]]; then
        local f; f="$(mktemp)"
        if [[ "${1:-}" == "-c" ]]; then printf '%s' "$2" > "$f"; else cat > "$f"; fi
        supabase db query --linked --project-ref "$PROJECT_REF" -f "$f" -o json 2>/dev/null |
            python -c "import sys,json;[print(list(r.values())[0]) for r in json.load(sys.stdin).get('rows') or []]"
        rm -f "$f"
    else
        psql "$DB_URL" -v ON_ERROR_STOP=1 -q -At "$@" | tr -d '\r'
    fi
}

create_user() {
    curl -sf -X POST "$API_URL/auth/v1/admin/users" \
        -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
        -H "apikey: $SERVICE_ROLE_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"$1\",\"password\":\"Demo-password-1\",\"email_confirm\":true,\"user_metadata\":{\"first_name\":\"$2\",\"last_name\":\"$3\"}}" \
        >/dev/null || echo "  ($1 already exists)"
}

echo "creating demo users"
create_user alice@demo.dev Alice Liddell
create_user bob@demo.dev Bob Marley
create_user carol@demo.dev Carol Danvers
create_user dave@demo.dev Dave Grohl
create_user erin@demo.dev Erin Brockovich

echo "creating conversations"
sql <<'SQL'
CREATE OR REPLACE FUNCTION pg_temp.uid(p_email text) RETURNS uuid
LANGUAGE sql AS $$ SELECT id FROM auth.users WHERE email = p_email $$;

CREATE OR REPLACE FUNCTION pg_temp.as_user(p_email text) RETURNS void
LANGUAGE sql AS $$
    SELECT set_config('request.jwt.claims',
        json_build_object('sub', pg_temp.uid(p_email), 'role', 'authenticated')::text, true);
$$;

-- Sends a message from p_email to p_room, p_minutes_ago minutes ago.
CREATE OR REPLACE FUNCTION pg_temp.say(p_room uuid, p_email text, p_text text,
                                      p_minutes_ago int, p_reply uuid DEFAULT NULL)
RETURNS uuid LANGUAGE sql AS $$
    INSERT INTO chats.messages ("roomId", "authorId", type, text, "createdAt", "replyToMessageId")
    VALUES (p_room, pg_temp.uid(p_email), 'text', p_text,
            now() - make_interval(mins => p_minutes_ago), p_reply::text)
    RETURNING id;
$$;

DO $$
DECLARE
    r_bob uuid; r_carol uuid; r_dave uuid; r_team uuid; r_trip uuid;
    m uuid; m2 uuid;
BEGIN
    PERFORM pg_temp.as_user('alice@demo.dev');
    r_bob   := chats.create_room('direct', ARRAY[pg_temp.uid('bob@demo.dev')]);
    r_carol := chats.create_room('direct', ARRAY[pg_temp.uid('carol@demo.dev')]);
    r_dave  := chats.create_room('direct', ARRAY[pg_temp.uid('dave@demo.dev')]);
    r_team  := chats.create_room('group', ARRAY[pg_temp.uid('bob@demo.dev'), pg_temp.uid('carol@demo.dev'), pg_temp.uid('erin@demo.dev')], 'Product team');
    r_trip  := chats.create_room('group', ARRAY[pg_temp.uid('dave@demo.dev'), pg_temp.uid('erin@demo.dev')], 'Weekend trip 🏔️');

    -- Bob: yesterday + today, with a reply and a reaction.
    m := pg_temp.say(r_bob, 'bob@demo.dev', 'Hey Alice! Are we still on for tomorrow?', 1500);
    PERFORM pg_temp.say(r_bob, 'alice@demo.dev', 'Yes! 10:00 at the usual place ☕', 1495, m);
    PERFORM pg_temp.say(r_bob, 'bob@demo.dev', 'Perfect, see you there', 1490);
    m2 := pg_temp.say(r_bob, 'bob@demo.dev', 'I just pushed the new build, can you take a look?', 25);
    PERFORM pg_temp.say(r_bob, 'alice@demo.dev', 'On it 👀', 20, m2);
    PERFORM pg_temp.say(r_bob, 'bob@demo.dev', 'Thanks! Let me know if anything looks off', 3);
    UPDATE chats.messages SET reactions = jsonb_build_object('👍', jsonb_build_array(pg_temp.uid('bob@demo.dev')::text)) WHERE id = m;

    -- Carol: already read conversation.
    PERFORM pg_temp.say(r_carol, 'carol@demo.dev', 'Did you see the launch video?', 300);
    PERFORM pg_temp.say(r_carol, 'alice@demo.dev', 'Amazing work, congrats to the whole team 🎉', 290);

    -- Dave: an older chat.
    PERFORM pg_temp.say(r_dave, 'dave@demo.dev', 'Concert tickets are booked 🎸', 4000);
    PERFORM pg_temp.say(r_dave, 'alice@demo.dev', 'Can''t wait!', 3990);

    -- Product team: busy group with a pinned message.
    m := pg_temp.say(r_team, 'alice@demo.dev', 'Release checklist is in the shared drive, please tick your items by Friday', 600);
    UPDATE chats.messages SET pinned = true WHERE id = m;
    PERFORM pg_temp.say(r_team, 'erin@demo.dev', 'Done with QA on Android ✅', 120);
    PERFORM pg_temp.say(r_team, 'carol@demo.dev', 'iOS too. One crash on iPad, fixing it now', 60);
    PERFORM pg_temp.say(r_team, 'bob@demo.dev', 'Backend migration ran fine on staging', 12);
    PERFORM pg_temp.say(r_team, 'erin@demo.dev', 'Great, ship it Friday?', 5);

    -- Weekend trip: muted group, pinned on top.
    PERFORM pg_temp.say(r_trip, 'dave@demo.dev', 'Who''s bringing the tent?', 200);
    PERFORM pg_temp.say(r_trip, 'erin@demo.dev', 'I have one for 3 people', 180);
    UPDATE chats.room_members SET "mutedUntil" = 'infinity', "pinnedAt" = now()
    WHERE "roomId" = r_trip AND "userId" = pg_temp.uid('alice@demo.dev');

    -- Alice read everything up to an hour ago: the latest messages stay unread.
    UPDATE chats.room_members SET "lastReadAt" = now() - interval '15 minutes'
    WHERE "userId" = pg_temp.uid('alice@demo.dev');
    UPDATE chats.messages SET status = 'seen'
    WHERE "authorId" = pg_temp.uid('alice@demo.dev');
END
$$;
SQL
echo "adding a voice message"
ROOM_ID=$(sql -c "select rm.\"roomId\" from chats.room_members rm join chats.rooms r on r.id = rm.\"roomId\" where r.type = 'direct' and rm.\"userId\" = (select id from auth.users where email = 'bob@demo.dev') and rm.\"roomId\" in (select \"roomId\" from chats.room_members where \"userId\" = (select id from auth.users where email = 'alice@demo.dev')) limit 1")
TMP_WAV="$(mktemp).wav"
# 3s of a gently pulsing 440 Hz tone, 16 kHz mono 16-bit PCM.
python - "$TMP_WAV" <<'PY'
import math, struct, sys, wave
rate, seconds = 16000, 3
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
    frames = bytearray()
    for i in range(rate * seconds):
        t = i / rate
        env = 0.35 + 0.35 * math.sin(2 * math.pi * 1.5 * t) ** 2
        frames += struct.pack("<h", int(32767 * env * math.sin(2 * math.pi * 440 * t)))
    w.writeframes(bytes(frames))
PY
OBJECT="$ROOM_ID/demo-voice.wav"
curl -sf -X POST "$API_URL/storage/v1/object/chats_assets/$OBJECT"     -H "Authorization: Bearer $SERVICE_ROLE_KEY" -H "Content-Type: audio/wav"     -H "x-upsert: true" --data-binary "@$TMP_WAV" >/dev/null
rm -f "$TMP_WAV"
sql -c "insert into chats.messages (\"roomId\", \"authorId\", type, source, duration, size, waveform, \"createdAt\")
  values ('$ROOM_ID', (select id from auth.users where email = 'bob@demo.dev'), 'audio',
          '$API_URL/storage/v1/object/authenticated/chats_assets/$OBJECT', 3000, 96044,
          '[0.35,0.5,0.7,0.62,0.4,0.36,0.55,0.75,0.68,0.45,0.35,0.52,0.72,0.66,0.42,0.36,0.56,0.74,0.65,0.44,0.35,0.5,0.7,0.6]',
          now() - interval '1 minute')"

echo "done: sign in as alice@demo.dev / Demo-password-1"
