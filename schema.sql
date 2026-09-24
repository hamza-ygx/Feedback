-- =========================================================
--  Feedbackskärm — komplett databasuppsättning
--
--  Redan körd på projektet (som tre migrationer). Sparad här
--  så att allt går att återskapa från noll: klistra in allt
--  i Supabase → SQL Editor → Run.
--
--  Säkerhetsmodellen i en mening: den publika nyckeln får
--  göra EN sak (lägga till ett svar) — all läsning går genom
--  en funktion som kräver byråns åtkomstkod.
-- =========================================================


-- ---------------------------------------------------------
--  1. Tabellen terminalen skriver till
-- ---------------------------------------------------------

create table if not exists svar (
  id      bigint generated always as identity primary key,
  betyg   smallint    not null check (betyg between 1 and 5),
  tid     timestamptz not null default now(),
  enhet   text        not null default 'demo'
          constraint enhet_rimlig check (char_length(enhet) between 1 and 40)
);

create index if not exists svar_tid_idx on svar (tid desc);

alter table svar enable row level security;

drop policy if exists "terminalen far lagga till svar" on svar;

create policy "terminalen far lagga till svar"
  on svar
  for insert
  to anon
  with check (
    betyg between 1 and 5
    and tid > now() - interval '1 day'
    and tid < now() + interval '1 hour'
  );

-- "Automatically expose new tables" är avstängt i projektet, så
-- rättigheterna måste stå här uttryckligen. Insert och inget annat.
grant usage  on schema public to anon;
grant insert on table  svar   to anon;

-- Sammanställning per dag. security_invoker = vyn körs med anroparens
-- rättigheter och kan inte läcka tabellen. Ingen grant — avsiktligt.
create or replace view svar_per_dag
  with (security_invoker = true) as
select
  date_trunc('day', tid)::date as dag,
  enhet,
  count(*)                                     as antal,
  round(avg(betyg)::numeric, 2)                as snitt,
  count(*) filter (where betyg <= 2)           as missnojda,
  count(*) filter (where betyg >= 4)           as nojda
from svar
group by 1, 2
order by 1 desc;


-- ---------------------------------------------------------
--  2. Åtkomstkod och läsfunktion
--
--  Koden lagras hashad (bcrypt) — den syns inte ens för den
--  som läser databasen. Byt kod så här:
--
--    update installningar
--    set kod_hash = extensions.crypt('NY-KOD', extensions.gen_salt('bf'))
--    where id = 1;
-- ---------------------------------------------------------

create extension if not exists pgcrypto with schema extensions;

create table if not exists installningar (
  id       int  primary key default 1 check (id = 1),
  kod_hash text not null
);

alter table installningar enable row level security;
-- Inga policyer och inga grants: tabellen är helt stängd utåt.

insert into installningar (id, kod_hash)
values (1, extensions.crypt('RKJH-7293', extensions.gen_salt('bf')))
on conflict (id) do nothing;   -- skriver inte över en redan satt kod

create or replace function hamta_statistik(kod text, dagar int default 30)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  ratt text;
  fran date;
begin
  select kod_hash into ratt from public.installningar where id = 1;

  -- "is distinct from" i stället för <>: annars blir jämförelsen NULL
  -- (inte TRUE) när kod är null, och vakten utlöses aldrig. Hittat i
  -- stresstest — {"kod": null} gav full statistik.
  if kod is null or ratt is null
     or extensions.crypt(kod, ratt) is distinct from ratt then
    perform pg_sleep(0.4);           -- bromsar gissningar
    raise exception 'fel åtkomstkod' using errcode = '28000';
  end if;

  dagar := least(greatest(coalesce(dagar, 30), 1), 365);
  fran  := current_date - dagar + 1;

  return jsonb_build_object(
    'genererad', now(),
    'dagar',     dagar,

    'totalt', (
      select jsonb_build_object(
        'antal',     count(*),
        'snitt',     round(avg(betyg)::numeric, 2),
        'nojda',     count(*) filter (where betyg >= 4),
        'missnojda', count(*) filter (where betyg <= 2),
        'idag',      count(*) filter (where tid::date = current_date)
      )
      from public.svar where tid::date >= fran
        and enhet not like 'event:%' and enhet not like 'val:%'
    ),

    'per_dag', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'dag',       dag,
        'antal',     antal,
        'snitt',     snitt,
        'nojda',     nojda,
        'missnojda', missnojda
      ) order by dag), '[]'::jsonb)
      from (
        select tid::date as dag,
               count(*) as antal,
               round(avg(betyg)::numeric, 2) as snitt,
               count(*) filter (where betyg >= 4) as nojda,
               count(*) filter (where betyg <= 2) as missnojda
        from public.svar
        where tid::date >= fran
        and enhet not like 'event:%' and enhet not like 'val:%'
        group by 1
      ) d
    ),

    'fordelning', (
      select coalesce(jsonb_object_agg(betyg, antal), '{}'::jsonb)
      from (
        select betyg, count(*) as antal
        from public.svar
        where tid::date >= fran
        and enhet not like 'event:%' and enhet not like 'val:%'
        group by betyg
      ) f
    ),

    'per_timme', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'timme', timme, 'antal', antal, 'snitt', snitt
      ) order by timme), '[]'::jsonb)
      from (
        select extract(hour from tid)::int as timme,
               count(*) as antal,
               round(avg(betyg)::numeric, 2) as snitt
        from public.svar
        where tid::date >= fran
        and enhet not like 'event:%' and enhet not like 'val:%'
        group by 1
      ) h
    ),

    'per_enhet', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'enhet', enhet, 'antal', antal, 'snitt', snitt
      ) order by antal desc), '[]'::jsonb)
      from (
        select enhet, count(*) as antal,
               round(avg(betyg)::numeric, 2) as snitt
        from public.svar
        where tid::date >= fran
        and enhet not like 'event:%' and enhet not like 'val:%'
        group by enhet
      ) e
    )
  );
end;
$$;

revoke all on function hamta_statistik(text, int) from public;
grant execute on function hamta_statistik(text, int) to anon;

comment on function public.hamta_statistik(text, int) is
  'Avsiktligt anropbar för anon: kräver åtkomstkod (bcrypt-verifierad) och lämnar bara ut aggregerad statistik.';


-- ---------------------------------------------------------
--  3. Eventläge
--
--  Byrån lägger in ett event med start- och sluttid. Skärmen
--  i entrén frågar aktivt_event() med jämna mellanrum: pågår
--  något nu? Om ja byter den själv till eventskärmen, och
--  byter tillbaka när eventet är slut. Ingen rör plattan.
--
--  Eventsvar taggas i enhet ('event:<id>' för betyg,
--  'val:<id>' för omröstningar) och filtreras bort ur den
--  dagliga statistiken av hamta_statistik ovan.
-- ---------------------------------------------------------

create table if not exists event (
  id        bigint generated always as identity primary key,
  namn      text not null check (char_length(namn) between 1 and 80),
  typ       text not null check (typ in ('betyg','valkommen','omrostning')),
  start_tid timestamptz not null,
  slut_tid  timestamptz not null,
  extra     jsonb not null default '{}'::jsonb,
  check (slut_tid > start_tid)
);

alter table event enable row level security;
-- Inga policyer och inga grants: tabellen är stängd utåt.
-- Skärmen läser via funktionen, som bara lämnar ut det event
-- som pågår just nu — aldrig framtida eller gamla.

create or replace function aktivt_event()
returns jsonb
language sql
security definer
set search_path = ''
stable
as $$
  select coalesce(
    (select jsonb_build_object(
       'id', id, 'namn', namn, 'typ', typ,
       'start_tid', start_tid, 'slut_tid', slut_tid, 'extra', extra)
     from public.event
     where now() between start_tid and slut_tid
     order by start_tid desc
     limit 1),
    'null'::jsonb);
$$;

revoke all on function aktivt_event() from public;
grant execute on function aktivt_event() to anon;

-- Exempel på att lägga in ett event (extra styr innehållet på
-- skärmen; typ styr vilken skärm som visas):
--
--   insert into event (namn, typ, start_tid, slut_tid, extra)
--   values ('Frukostseminarium — Nya 3:12-reglerna', 'valkommen',
--           '2026-09-10 07:30+02', '2026-09-10 10:30+02',
--           '{"plats":"Brogatan 9, plan 2","wifi":"RKJH-Gäst",
--             "agenda":[{"tid":"08:00","punkt":"Kaffe och smörgås"}],
--             "fraga":"Vad vill ni se härnäst?",
--             "alternativ":["Skatteplanering","Generationsskifte"]}');


-- ---------------------------------------------------------
--  4. Städning
--
--  rls_auto_enable() skapas av projektinställningen "Enable
--  automatic RLS" och behöver aldrig nås via API:et.
-- ---------------------------------------------------------

do $$
begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'rls_auto_enable') then
    revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
  end if;
end $$;


-- ---------------------------------------------------------
--  Demodata ligger i databasen (60 dagar bakåt). Rensa allt
--  äldre än idag med:
--
--    delete from svar where tid < current_date;
-- ---------------------------------------------------------
