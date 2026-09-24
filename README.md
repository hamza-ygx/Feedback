# Feedbackskärm

En feedbackterminal av samma typ som står vid utgången på Elgiganten — fem
ansikten, ett tryck, klart — plus översikten där man ser vad folk faktiskt svarat.

| Steg | Vad | Fil | Status |
|---|---|---|---|
| 1 | Skärmen kunden trycker på | `index.html` | ✅ live |
| 2 | Databasen svaren hamnar i | `schema.sql` | ✅ live (Supabase, EU) |
| 3 | Översikten byrån tittar på | `dashboard.html` | ✅ live |

Allt är fristående HTML utan beroenden. Databasen är Postgres hos Supabase,
projektet **Feedback-dash**, redan uppkopplat i båda filerna.

## Öppna översikten

Det är **två sidor**. Skärmen ligger på startsidan, översikten en nivå in:

```
din-adress.se                  →  skärmen kunden trycker på
din-adress.se/dashboard.html   →  översikten
```

Man behöver inte minnas adressen: **fem tryck på loggan** på skärmen
öppnar den dolda rutan, och där finns knappen **Öppna översikten →**.

Ange sedan åtkomstkoden.

> **Åtkomstkod (demo): `RKJH-7293`**
>
> Koden lagras hashad i databasen — byt den innan något går till en riktig
> kund (en rad SQL, står i `schema.sql`). Att den står här är okej för en
> demo i ett privat repo, inte för drift.

Knappen **Visa med exempeldata** öppnar översikten utan databas — bra när
man vill visa utseendet utan nät.

## Styra skärmen från översikten

Fliken **Skärm & event** i översikten (`/dashboard.html#styrning`):

- **Skärmen i entrén** — välj Original, Förslag A, B eller C. Plattan
  byter själv inom 15 sekunder. Förslagsfilerna är bara skarpa när
  plattan öppnar dem (`?skarp=1`); öppnade direkt skriver de inget.
- **Live-event** — starta ett event direkt eller schemalägg det, byt
  mellan Betyg / Välkommen / Omröstning medan det pågår, förläng,
  redigera agenda och alternativ, avsluta. Plattan följer inom 15 s
  och går tillbaka till vald skärm när eventet är slut.
- **Event** — kommande och tidigare event med resultat (betyg, röster).

> **Kräver en databasuppdatering, en gång:** kör `migrering-styrning.sql`
> i Supabase → SQL Editor. Tills dess visar fliken en påminnelse och
> plattan fungerar som förut.

## Så hänger det ihop

```
[ Platta i entrén ]        [ Supabase Postgres ]        [ Översikten ]
   index.html      ──────►    tabellen svar      ◄──────  dashboard.html
   forslag-a/b/c   ◄──────    skarm_lage()       ◄──────  styr skärm + event
   ett tryck = en rad         RLS: insert-only            läser via funktion
   kö vid nätstrul            koden hashad (bcrypt)       som kräver åtkomstkod
```

**Skärmen** skriver varje tryck lokalt först, skickar sedan. Ligger nätet
nere köas raderna och går iväg vid nästa försök — vid start, när nätet
kommer tillbaka, var trettionde sekund. Ett wifi som hackar kostar inga svar.

**Nyckeln i sidorna är publik med flit.** Databasen tillåter den exakt en
sak: lägga till ett svar. Läsa, ändra, radera — stängt. Verifierat med
riktiga anrop: insert ger 201, select/update ger 401, fel kod ger 403.

**Översikten** läser aldrig tabellen direkt — den anropar funktionen
`hamta_statistik(kod, dagar)`, som verifierar koden mot bcrypt-hashen och
bara lämnar ut färdiga siffror: per dag, per timme, fördelning, totaler.

## Den dolda rutan på skärmen

**Fem tryck på loggan** (eller tangenten `S`) visar antal svar, kö-läge och
om databasen svarar. Kunden ser den aldrig. Tangenterna `1`–`5` fungerar
som ansiktena när man testar.

## Demodata

Databasen innehåller ca 630 genererade svar, 60 dagar bakåt: vardagar,
kontorstid, mest nöjda — och en tydlig svacka för ca 10 dagar sedan som
återhämtat sig. Bra att peka på i en demo. Rensa allt med:

```sql
delete from svar where tid < current_date;
```

## Lägga upp det på riktigt

1. **Sidorna** — valfri statisk host (Vercel-import av det här repot
   funkar rakt av; Cloudflare Pages/Netlify likaså). `index.html` blir
   startsidan, översikten nås på `/dashboard.html`.
2. **Plattan** — öppna adressen och lås i kioskläge:
   iPad → Guidad åtkomst · Android → Fästa appar / kiosk-app.
3. **Hos en riktig kund** — skapa nytt Supabase-projekt i kundens namn
   (region Frankfurt för EU-data), kör `schema.sql`, byt URL + nyckel i
   filernas `DB`-block, sätt en ny åtkomstkod, rensa demodata.

## Kostnad

0 kr/mån vid de här volymerna. En rad är ~50 byte; gratisnivån rymmer
hundratals miljoner. Jämför med HappyOrNot: ca 1 500–3 000 kr/mån.
