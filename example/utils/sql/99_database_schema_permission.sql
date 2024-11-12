GRANT USAGE ON SCHEMA chats TO anon, authenticated, service_role;
GRANT ALL ON ALL TABLES IN SCHEMA chats TO anon, authenticated, service_role;
GRANT ALL ON ALL ROUTINES IN SCHEMA chats TO anon, authenticated, service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA chats TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA chats GRANT ALL ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA chats GRANT ALL ON ROUTINES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA chats GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;
