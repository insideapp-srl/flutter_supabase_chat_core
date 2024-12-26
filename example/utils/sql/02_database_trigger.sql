
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


CREATE OR REPLACE FUNCTION chats.update_last_messages()
    RETURNS TRIGGER
    SET search_path = ''
AS $$
DECLARE
    latest_message jsonb;
    ts_in_milliseconds bigint;
BEGIN
        SELECT jsonb_build_object(
            'id', id,
            'createdAt', "createdAt",
            'metadata', metadata,
            'duration', duration,
            'mimeType', "mimeType",
            'name', name,
            'remoteId', "remoteId",
            'repliedMessage', "repliedMessage",
            'roomId', "roomId",
            'showStatus', "showStatus",
            'size', size,
            'status', status,
            'type', type,
            'updatedAt', "updatedAt",
            'uri', uri,
            'waveForm', "waveForm",
            'isLoading', "isLoading",
            'height', height,
            'width', width,
            'previewData', "previewData",
            'authorId', "authorId",
            'text', text
        )
        INTO latest_message
        FROM chats.messages
        WHERE "roomId" = NEW."roomId"
        ORDER BY "createdAt" DESC
        LIMIT 1;
        IF latest_message IS DISTINCT FROM (SELECT "lastMessages" FROM chats.rooms WHERE id = NEW."roomId") THEN
                SELECT EXTRACT(epoch FROM NOW()) * 1000 INTO ts_in_milliseconds;
                UPDATE chats.rooms
                SET "updatedAt" = ts_in_milliseconds,
                    "lastMessages" = jsonb_build_array(latest_message)
                WHERE id = NEW."roomId";
        END IF;
        RETURN NEW;
END;
$$ LANGUAGE plpgsql;

drop trigger if exists update_last_messages_trigger on chats.messages;
CREATE TRIGGER update_last_messages_trigger
    AFTER INSERT OR UPDATE ON chats.messages
    FOR EACH ROW
EXECUTE FUNCTION chats.update_last_messages();

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
