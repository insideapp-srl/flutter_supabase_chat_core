---
id: supabase-triggers
title: Database Triggers
---

This is an example of a triggers that sets room's `lastMessages` to the most recent message sent once recieved in Supabase.

```sql
CREATE OR REPLACE FUNCTION chats.update_last_messages()
    RETURNS TRIGGER
    SET search_path = ''
AS $$
DECLARE
    ts_in_milliseconds bigint;
BEGIN
    SELECT EXTRACT(epoch FROM NOW()) * 1000 INTO ts_in_milliseconds;
    UPDATE chats.rooms
    SET "updatedAt" = ts_in_milliseconds,
        "lastMessages" = jsonb_build_array(NEW)
    WHERE id = NEW."roomId";
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

drop trigger if exists update_last_messages_trigger on chats.messages;
CREATE TRIGGER update_last_messages_trigger
    AFTER INSERT OR UPDATE ON chats.messages
    FOR EACH ROW
EXECUTE FUNCTION chats.update_last_messages();
```

"This trigger, on the other hand, is responsible for setting the message status to `sent` when it is added to the `messages` table:

```sql
CREATE OR REPLACE FUNCTION chats.set_message_status_to_sent()
    RETURNS TRIGGER
    SET search_path = ''
AS $$
BEGIN
    NEW.status := 'sent';
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

drop trigger if exists update_status_before_insert on chats.messages;
CREATE TRIGGER update_status_before_insert
    BEFORE INSERT ON chats.messages
    FOR EACH ROW EXECUTE FUNCTION chats.set_message_status_to_sent();
```

"This trigger, is responsible for replicate `auth.users` table rows in `chats.users` table, this is to avoid exposing user data :

```sql

CREATE OR REPLACE FUNCTION chats.handle_new_user()
    RETURNS trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF SECURITY DEFINER
    SET search_path=public
    SET search_path = ''
AS $BODY$
DECLARE
    ts_in_milliseconds bigint;
BEGIN
    SELECT EXTRACT(epoch FROM NOW()) * 1000 INTO ts_in_milliseconds;
    insert into chats.users (id, "createdAt", "updatedAt", "lastSeen")
    values (new.id, ts_in_milliseconds, ts_in_milliseconds, ts_in_milliseconds);
    return new;
end;
$BODY$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
    after insert on auth.users
    for each row execute procedure chats.handle_new_user();

```