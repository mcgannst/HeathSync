-- Privileges and row security. Re-applied by scripts/db.sh after every migration run, so it must be safe to repeat.
-- psql variables: app (read-write API role), mcp (read-only MCP role).
--
-- The MCP role can only SELECT health tables, and row security limits it to the user named in the
-- transaction-local setting healthsync.user_id. The MCP server sets that from the OAuth token, so
-- one family member's connector can never read another's rows, even if a query forgets a WHERE clause.

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO :"app";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO :"app";
REVOKE INSERT, UPDATE, DELETE ON schema_migrations FROM :"app";

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM :"mcp";
GRANT SELECT ON samples, workouts, daily_summaries TO :"mcp";
GRANT SELECT (id, display_name, time_zone, last_sync_at) ON users TO :"mcp";

ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE samples ENABLE ROW LEVEL SECURITY;
ALTER TABLE workouts ENABLE ROW LEVEL SECURITY;
ALTER TABLE daily_summaries ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS app_all ON users;
CREATE POLICY app_all ON users TO :"app" USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS mcp_own ON users;
CREATE POLICY mcp_own ON users FOR SELECT TO :"mcp"
    USING (id = nullif(current_setting('healthsync.user_id', true), '')::int);

DROP POLICY IF EXISTS app_all ON samples;
CREATE POLICY app_all ON samples TO :"app" USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS mcp_own ON samples;
CREATE POLICY mcp_own ON samples FOR SELECT TO :"mcp"
    USING (user_id = nullif(current_setting('healthsync.user_id', true), '')::int);

DROP POLICY IF EXISTS app_all ON workouts;
CREATE POLICY app_all ON workouts TO :"app" USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS mcp_own ON workouts;
CREATE POLICY mcp_own ON workouts FOR SELECT TO :"mcp"
    USING (user_id = nullif(current_setting('healthsync.user_id', true), '')::int);

DROP POLICY IF EXISTS app_all ON daily_summaries;
CREATE POLICY app_all ON daily_summaries TO :"app" USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS mcp_own ON daily_summaries;
CREATE POLICY mcp_own ON daily_summaries FOR SELECT TO :"mcp"
    USING (user_id = nullif(current_setting('healthsync.user_id', true), '')::int);
