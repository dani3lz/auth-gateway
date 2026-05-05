-- Prevent deletion of protected admin users (and the last remaining user).
-- Applied to the standalone Supabase Postgres after the Supabase init scripts
-- have created the auth schema. setup.sh runs this in step 3b.
--
-- To mark a user as protected:
--   UPDATE auth.users
--   SET raw_app_meta_data = raw_app_meta_data || '{"is_protected":true}'::jsonb
--   WHERE email = 'admin@example.com';
--
-- To unprotect:
--   UPDATE auth.users
--   SET raw_app_meta_data = raw_app_meta_data - 'is_protected'
--   WHERE email = 'admin@example.com';

CREATE OR REPLACE FUNCTION auth.prevent_protected_user_delete()
RETURNS TRIGGER AS $func$
BEGIN
  IF COALESCE((OLD.raw_app_meta_data->>'is_protected')::boolean, false) THEN
    RAISE EXCEPTION 'Cannot delete protected user %', OLD.email
      USING HINT = 'Set raw_app_meta_data.is_protected=false first';
  END IF;
  IF (SELECT COUNT(*) FROM auth.users) <= 1 THEN
    RAISE EXCEPTION 'Refusing to delete the last remaining user (would lock everyone out)';
  END IF;
  RETURN OLD;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS prevent_protected_user_delete ON auth.users;
CREATE TRIGGER prevent_protected_user_delete
  BEFORE DELETE ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION auth.prevent_protected_user_delete();
