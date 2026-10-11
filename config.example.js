// Copia in config.js (o generalo con scripts/make-config.sh).
// La anon key è pubblica per design: i dati sono protetti dalla RLS, non dal segreto.
window.RHINO_CONFIG = {
  url: "https://<project-ref>.supabase.co",
  anonKey: "<anon key>"
};
