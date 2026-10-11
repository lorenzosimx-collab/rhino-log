-- Rhino Log — schema allenamento.
-- Progetto Supabase "Fitness app" (vslmzhcxcgfzsateohix), tabelle con prefisso rhino_. Applicato l'11/10/2026 come migrazione rhinolog_schema.
-- Incolla in Supabase Dashboard → SQL Editor → Run. È idempotente: si può rilanciare.
--
-- Modello: una riga per sessione, una per serie, una per esercizio (connessione).
-- Convenzione unilaterali: side = 'sx' | 'dx'; bilaterali: side = 'both'.

create table if not exists rhino_sessions (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  date        date not null,
  day         text not null check (day in ('push', 'pull', 'legs', 'upper')),
  -- i 4 feedback di Lemme, 1-5
  voglia      smallint check (voglia  between 1 and 5),
  mood        smallint check (mood    between 1 and 5),
  energia     smallint check (energia between 1 and 5),
  rpe         smallint check (rpe     between 1 and 5),
  sonno_ore   numeric(3,1) check (sonno_ore between 0 and 24),
  risvegli    smallint check (risvegli >= 0),
  ginocchio   text check (ginocchio in ('nulla', 'lieve', 'presente')),
  -- DOMS: risposta del giorno dopo, 0 niente · 1 lievi · 2 medi · 3 forti
  doms_grado  smallint check (doms_grado between 0 and 3),
  doms_at     date,
  deload      boolean not null default false,
  note        text,
  saved_at    timestamptz not null default now(),
  created_at  timestamptz not null default now(),
  unique (user_id, date, day)
);

create table if not exists rhino_exercises (
  session_id  uuid not null references rhino_sessions (id) on delete cascade,
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  exercise    text not null,                       -- chiave da DAYS, es. 'peckfly'
  conn        smallint check (conn between 1 and 3), -- connessione col distretto target
  note        text,
  primary key (session_id, exercise)
);

create table if not exists rhino_sets (
  id          bigint generated always as identity primary key,
  session_id  uuid not null references rhino_sessions (id) on delete cascade,
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  exercise    text not null,
  set_no      smallint not null check (set_no >= 1),
  side        text not null default 'both' check (side in ('both', 'sx', 'dx')),
  kg          numeric(5,1) check (kg >= 0),
  reps        smallint check (reps >= 0),
  unique (session_id, exercise, set_no, side)
);

create index if not exists idx_rhino_sessions_user_date on rhino_sessions (user_id, date desc);
create index if not exists idx_rhino_sets_session on rhino_sets (session_id);
create index if not exists idx_rhino_sets_exercise on rhino_sets (user_id, exercise);

-- ---------- RLS: ognuno vede e scrive solo le proprie righe ----------
alter table rhino_sessions  enable row level security;
alter table rhino_exercises enable row level security;
alter table rhino_sets      enable row level security;

drop policy if exists "own rows" on rhino_sessions;
drop policy if exists "own rows" on rhino_exercises;
drop policy if exists "own rows" on rhino_sets;
create policy "own rows" on rhino_sessions  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "own rows" on rhino_exercises for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "own rows" on rhino_sets      for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- ---------- Salvataggio atomico ----------
-- L'app manda la sessione nello stesso JSON che usava l'artifact:
-- {date, day, feedback:{voglia,mood,energia,rpe}, sonno:{ore,risvegli}, ginocchio,
--  exercises:{<k>:{sets:[{kg,reps,kg2,reps2}], conn}}, doms:{grado,at}|null, deload, note}
-- Negli unilaterali il client manda sempre le chiavi kg2/reps2 (anche null): è così che
-- la funzione distingue SX/DX da 'both'. Serie con kg e reps entrambi vuoti non vengono scritte.
-- Upsert della sessione, poi serie ed esercizi riscritti da zero, tutto in una transazione.
-- security invoker: gira coi permessi dell'utente, quindi la RLS vale anche qui.
create or replace function rhino_save_session(p jsonb)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  sid uuid;
  ex  record;
  s   jsonb;
  i   int;
  uni boolean;
begin
  insert into rhino_sessions as t
    (date, day, voglia, mood, energia, rpe, sonno_ore, risvegli, ginocchio,
     doms_grado, doms_at, deload, note, saved_at)
  values (
    (p->>'date')::date,
    p->>'day',
    nullif(p#>>'{feedback,voglia}', '')::smallint,
    nullif(p#>>'{feedback,mood}', '')::smallint,
    nullif(p#>>'{feedback,energia}', '')::smallint,
    nullif(p#>>'{feedback,rpe}', '')::smallint,
    nullif(p#>>'{sonno,ore}', '')::numeric,
    nullif(p#>>'{sonno,risvegli}', '')::smallint,
    nullif(p->>'ginocchio', ''),
    nullif(p#>>'{doms,grado}', '')::smallint,
    nullif(p#>>'{doms,at}', '')::date,
    coalesce((p->>'deload')::boolean, false),
    nullif(p->>'note', ''),
    now()
  )
  on conflict (user_id, date, day) do update set
    voglia = excluded.voglia, mood = excluded.mood, energia = excluded.energia, rpe = excluded.rpe,
    sonno_ore = excluded.sonno_ore, risvegli = excluded.risvegli, ginocchio = excluded.ginocchio,
    doms_grado = coalesce(excluded.doms_grado, t.doms_grado),
    doms_at    = coalesce(excluded.doms_at, t.doms_at),
    deload = excluded.deload, note = excluded.note, saved_at = now()
  returning id into sid;

  delete from rhino_sets      where session_id = sid;
  delete from rhino_exercises where session_id = sid;

  for ex in select key, value from jsonb_each(coalesce(p->'exercises', '{}'::jsonb)) loop
    insert into rhino_exercises (session_id, exercise, conn, note)
    values (sid, ex.key, nullif(ex.value->>'conn', '')::smallint, nullif(ex.value->>'note', ''));

    i := 0;
    for s in select * from jsonb_array_elements(coalesce(ex.value->'sets', '[]'::jsonb)) loop
      i := i + 1;
      continue when s is null or jsonb_typeof(s) <> 'object';
      uni := (s ? 'kg2') or (s ? 'reps2');
      if coalesce(s->>'kg', s->>'reps') is not null then
        insert into rhino_sets (session_id, exercise, set_no, side, kg, reps)
        values (sid, ex.key, i, case when uni then 'sx' else 'both' end,
                nullif(s->>'kg', '')::numeric, nullif(s->>'reps', '')::smallint);
      end if;
      if uni and coalesce(s->>'kg2', s->>'reps2') is not null then
        insert into rhino_sets (session_id, exercise, set_no, side, kg, reps)
        values (sid, ex.key, i, 'dx',
                nullif(s->>'kg2', '')::numeric, nullif(s->>'reps2', '')::smallint);
      end if;
    end loop;
  end loop;

  return sid;
end;
$$;

revoke execute on function rhino_save_session(jsonb) from public, anon;
grant execute on function rhino_save_session(jsonb) to authenticated;

-- ---------- Vista piatta per l'analisi (una riga per serie) ----------
create or replace view rhino_log with (security_invoker = true) as
select s.date, s.day, st.exercise, st.set_no, st.side, st.kg, st.reps,
       e.conn, s.voglia, s.mood, s.energia, s.rpe, s.ginocchio, s.doms_grado, s.deload,
       s.user_id, s.id as session_id
from rhino_sessions s
join rhino_sets st on st.session_id = s.id
left join rhino_exercises e on e.session_id = s.id and e.exercise = st.exercise;
