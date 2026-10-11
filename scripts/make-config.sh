#!/bin/zsh
# Genera config.js da ~/Sistemi/credenziali/supabase-rhinolog.env. Usa solo URL e anon key
# (pubblici per design); la service key resta nel file credenziali. Non stampa nulla.
set -e
ENV="$HOME/Sistemi/credenziali/supabase-rhinolog.env"
url=$(grep '^SUPABASE_URL=' "$ENV" | cut -d= -f2-)
key=$(grep '^SUPABASE_ANON_KEY=' "$ENV" | cut -d= -f2-)
[[ -n "$url" && -n "$key" ]] || { echo "SUPABASE_URL o SUPABASE_ANON_KEY vuoti in $ENV"; exit 1; }
printf 'window.RHINO_CONFIG = {\n  url: "%s",\n  anonKey: "%s"\n};\n' "$url" "$key" > "${0:A:h}/../config.js"
echo "config.js scritto"
