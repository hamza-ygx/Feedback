-- =========================================================
--  Feedbackskärm — styrning från översikten
--
--  Kör en gång: Supabase → SQL Editor → klistra in → Run.
--  Går att köra om utan skada. Samma innehåll ligger som
--  avsnitt 5 i schema.sql.
--
--  Ger översikten två nya saker:
--    • välja vilken skärm plattan visar (original, A, B, C)
--    • starta, ändra och avsluta event direkt — inte bara via SQL
--
--  Plattan läser allt via skarm_lage() (publik, bara läge +
--  pågående event). Allt som ändrar kräver åtkomstkoden.
-- =========================================================


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
