# Feedbackskärm

En feedbackterminal av samma typ som står vid utgången på Elgiganten — fem
ansikten, ett tryck, klart — plus översikten där man ser vad folk faktiskt svarat.

| Steg | Vad | Fil | Status |
|---|---|---|---|
| 1 | Skärmen kunden trycker på | `index.html` (+ `forslag-a/b/c.html`) | ✅ live |
| 2 | Databasen svaren hamnar i | `schema.sql` | ✅ live (Supabase, Frankfurt) |
| 3 | Översikten byrån tittar på | `dashboard.html` | ✅ live |

Allt är fristående HTML utan beroenden; gemensam skärmlogik ligger i
`kiosk.js`. Databasen är Postgres hos Supabase, projektet
**supabase-rose-lamp** (`yykoaoildtqyclpregug`), uppkopplat i sidornas `DB`-block.

## Öppna översikten

Det är **två sidor**. Skärmen ligger på startsidan, översikten en nivå in:

```
din-adress.se                  →  skärmen kunden trycker på
din-adress.se/dashboard.html   →  översikten
```

Man behöver inte minnas adressen: **fem tryck på loggan** på skärmen
öppnar den dolda rutan, och där finns knappen **Öppna översikten →**.

Ange sedan åtkomstkoden.

> **Åtkomstkoden står inte här — repot är publikt.** Den lagras bara som
> bcrypt-hash i databasen. Byt den med en rad SQL (avsnitt 2 i `schema.sql`).

Knappen **Visa med exempeldata** öppnar översikten utan databas — bra när
man vill visa utseendet utan nät.

## Statistik per dag, vecka, månad och år

Fliken **Statistik** visar valfri **dag, vecka, månad eller år**. Bläddra med
‹ › (eller piltangenterna), hoppa till ett datum med **Gå till**, och tillbaka
med **Idag**. Nyckeltalen jämförs med perioden före. Allt räknas i svensk tid.

**Enskilda svar** längst ned listar periodens svar. Felklick rättas direkt:
tryck på rätt ansikte för att ändra betyget, **Ta bort** för att radera, eller
**+ Lägg till svar** för ett svar i efterhand (märks *Tillagt*). Eventsvar
rörs inte här — de hör till eventet.

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
sak utan kod: lägga till ett svar (och fråga vilken skärm som ska visas).
Läsa, ändra, radera — stängt, eller bakom åtkomstkoden. Verifierat mot
databasen som `anon`: tabellerna ger permission denied, fel kod ger 28000
(HTTP 403).

**Översikten** läser aldrig tabellen direkt — den anropar funktionen
`hamta_statistik(kod, dagar)`, som verifierar koden mot bcrypt-hashen och
bara lämnar ut färdiga siffror: per dag, per timme, fördelning, totaler.

## Den dolda rutan på skärmen

**Fem tryck på loggan** (eller tangenten `S`) visar antal svar, kö-läge och
om databasen svarar. Kunden ser den aldrig. Tangenterna `1`–`5` fungerar
som ansiktena när man testar.

## Nollställa

Databasen startade tom. Rensa svar, event och skärmval (koden behålls):

```sql
truncate svar, event restart identity;
update installningar set skarm = 'standard' where id = 1;
```

## Lägga upp det på riktigt

1. **Sidorna** — valfri statisk host (Vercel-import av det här repot
   funkar rakt av; Cloudflare Pages/Netlify likaså). `index.html` blir
   startsidan, översikten nås på `/dashboard.html`.
2. **Plattan** — öppna adressen och lås i kioskläge:
   iPad → Guidad åtkomst · Android → Fästa appar / kiosk-app.
3. **Hos en riktig kund** — skapa nytt Supabase-projekt i kundens namn
   (region Frankfurt för EU-data), kör `schema.sql`, byt URL + nyckel i
   `DB`-blocken (`kiosk.js`, `dashboard.html`, `event-skarmar.html`,
   `oversikt-period.html`) och sätt en åtkomstkod.

## Kostnad

0 kr/mån vid de här volymerna. En rad är ~50 byte; gratisnivån rymmer
hundratals miljoner. Jämför med HappyOrNot: ca 1 500–3 000 kr/mån.
