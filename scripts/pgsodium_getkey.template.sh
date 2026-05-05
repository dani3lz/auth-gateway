#!/bin/bash
# Returns the pgsodium server key. Required for Supabase Vault to encrypt secrets.
# setup.sh generates a fresh key per deployment and writes it into this script
# inside the Postgres container at /etc/postgresql-custom/pgsodium_getkey.sh.
# DO NOT commit a real key to the repo.
echo "REPLACE_WITH_RANDOM_64_HEX_CHARS_AT_DEPLOY_TIME"
