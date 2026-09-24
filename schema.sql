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
--  5. Styrning från översikten
--
--  Översikten väljer skärm (original, A, B, C) och startar,
--  ändrar och avslutar event. Plattan läser via skarm_lage().
--  Finns också fristående i migrering-styrning.sql.
-- ---------------------------------------------------------

-- Vilken skärm plattan ska visa när inget event pågår
alter table installningar
  add column if not exists skarm text not null default 'standard'
  constraint skarm_giltig check (skarm in ('standard','a','b','c'));


-- Kodkontroll, delad av alla skrivande funktioner. Inte
-- anropbar utifrån — bara från funktionerna nedan.
create or replace function public.krav_kod(kod text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  ratt text;
begin
  select kod_hash into ratt from public.installningar where id = 1;
  if kod is null or ratt is null
     or extensions.crypt(kod, ratt) is distinct from ratt then
    perform pg_sleep(0.4);
    raise exception 'fel åtkomstkod' using errcode = '28000';
  end if;
end;
$$;

revoke all on function public.krav_kod(text) from public, anon, authenticated;


-- Det plattan frågar efter var 15:e sekund
create or replace function public.skarm_lage()
returns jsonb
language sql
security definer
set search_path = ''
stable
as $$
  select jsonb_build_object(
    'skarm', coalesce((select skarm from public.installningar where id = 1), 'standard'),
    'event', public.aktivt_event()
  );
$$;

revoke all on function public.skarm_lage() from public;
grant execute on function public.skarm_lage() to anon;


-- Byt skärm
create or replace function public.satt_skarm(kod text, p_skarm text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.krav_kod(kod);
  if p_skarm is null or p_skarm not in ('standard','a','b','c') then
    raise exception 'okänd skärm' using errcode = '22023';
  end if;
  update public.installningar set skarm = p_skarm where id = 1;
  return public.skarm_lage();
end;
$$;

revoke all on function public.satt_skarm(text, text) from public;
grant execute on function public.satt_skarm(text, text) to anon;


-- Lista event med resultat (senaste 180 dagarna + allt kommande)
create or replace function public.lista_event(kod text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.krav_kod(kod);
  return (
    select coalesce(jsonb_agg(to_jsonb(x) order by x.start_tid desc), '[]'::jsonb)
    from (
      select e.id, e.namn, e.typ, e.start_tid, e.slut_tid, e.extra,
             now() between e.start_tid and e.slut_tid as pagar,
             (select count(*) from public.svar s
               where s.enhet = 'event:' || e.id) as betyg_antal,
             (select round(avg(s.betyg)::numeric, 2) from public.svar s
               where s.enhet = 'event:' || e.id) as betyg_snitt,
             (select coalesce(jsonb_object_agg(v.betyg, v.n), '{}'::jsonb)
                from (select s.betyg, count(*) as n from public.svar s
                       where s.enhet = 'val:' || e.id group by s.betyg) v) as roster
      from public.event e
      where e.slut_tid > now() - interval '180 days'
      order by e.start_tid desc
      limit 50
    ) x
  );
end;
$$;

revoke all on function public.lista_event(text) from public;
grant execute on function public.lista_event(text) to anon;


-- Skapa (p_id null) eller ändra ett event. Startar det nu
-- avslutas andra pågående event, så det nya tar över direkt.
create or replace function public.spara_event(
  kod       text,
  p_namn    text,
  p_typ     text,
  p_start   timestamptz,
  p_slut    timestamptz,
  p_extra   jsonb  default '{}'::jsonb,
  p_id      bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  nytt bigint;
begin
  perform public.krav_kod(kod);

  p_start := coalesce(p_start, now());
  p_extra := coalesce(p_extra, '{}'::jsonb);
  if jsonb_typeof(p_extra) <> 'object' or length(p_extra::text) > 8000 then
    raise exception 'ogiltigt innehåll' using errcode = '22023';
  end if;
  if p_slut is null or p_slut <= p_start then
    raise exception 'sluttiden måste vara efter starttiden' using errcode = '22023';
  end if;

  if p_id is null then
    insert into public.event (namn, typ, start_tid, slut_tid, extra)
    values (p_namn, p_typ, p_start, p_slut, p_extra)
    returning id into nytt;
  else
    update public.event
       set namn = p_namn, typ = p_typ, start_tid = p_start,
           slut_tid = p_slut, extra = p_extra
     where id = p_id
    returning id into nytt;
    if nytt is null then
      raise exception 'eventet finns inte' using errcode = '22023';
    end if;
  end if;

  if p_start <= now() and p_slut > now() then
    update public.event
       set slut_tid = greatest(now(), start_tid + interval '1 second')
     where id <> nytt
       and now() between start_tid and slut_tid;
  end if;

  return jsonb_build_object('id', nytt);
end;
$$;

revoke all on function public.spara_event(text, text, text, timestamptz, timestamptz, jsonb, bigint) from public;
grant execute on function public.spara_event(text, text, text, timestamptz, timestamptz, jsonb, bigint) to anon;


-- Avsluta ett pågående event nu, eller ta bort ett kommande.
-- Avslutade event med svar ligger kvar så resultaten syns.
create or replace function public.avsluta_event(kod text, p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.krav_kod(kod);

  delete from public.event where id = p_id and start_tid > now();

  update public.event
     set slut_tid = greatest(now(), start_tid + interval '1 second')
   where id = p_id and now() between start_tid and slut_tid;

  return public.skarm_lage();
end;
$$;

revoke all on function public.avsluta_event(text, bigint) from public;
grant execute on function public.avsluta_event(text, bigint) to anon;

comment on function public.satt_skarm(text, text)   is 'Anropbar för anon: kräver åtkomstkod.';
comment on function public.lista_event(text)        is 'Anropbar för anon: kräver åtkomstkod.';
comment on function public.avsluta_event(text, bigint) is 'Anropbar för anon: kräver åtkomstkod.';
comment on function public.spara_event(text, text, text, timestamptz, timestamptz, jsonb, bigint)
  is 'Anropbar för anon: kräver åtkomstkod.';


-- ---------------------------------------------------------
--  Demodata ligger i databasen (60 dagar bakåt). Rensa allt
--  äldre än idag med:
--
--    delete from svar where tid < current_date;
-- ---------------------------------------------------------
