drop trigger if exists on_auth_user_created on auth.users;
DROP function if exists chats.handle_new_user;

CREATE OR REPLACE FUNCTION chats.handle_new_user()
    RETURNS trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF SECURITY DEFINER
    SET search_path=public
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

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure chats.handle_new_user();

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
