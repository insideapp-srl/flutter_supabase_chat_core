---
id: supabase-triggers
title: Database Triggers
---

This is an example of a triggers that sets room's `lastMessages` to the most recent message sent once recieved in Firestore.

```sql
    CREATE OR REPLACE FUNCTION chats.update_last_messages()
        RETURNS TRIGGER AS $$
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
    
    CREATE TRIGGER update_last_messages_trigger
        AFTER INSERT ON chats.messages
        FOR EACH ROW
    EXECUTE FUNCTION chats.update_last_messages();
```

"This trigger, on the other hand, is responsible for setting the message status to `sent` when it is added to the `messages` table:

```sql
CREATE OR REPLACE FUNCTION set_message_status_to_sent()
RETURNS TRIGGER AS $$
BEGIN
NEW.status := 'sent';
RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_status_before_insert
BEFORE INSERT ON chats.messages
FOR EACH ROW EXECUTE FUNCTION set_message_status_to_sent();
```