/* =========================================================
   Feedbackskärm — gemensam motor för alla skärmar

   index.html och forslag-a/b/c.html ritar var sin design;
   allt annat bor här:
     • svaren sparas lokalt först och köas till databasen
     • plattan frågar var 15:e sekund vilken skärm den ska
       visa och om ett event pågår — och byter själv

   Förslagsfilerna startar bara motorn med ?skarp=1. Öppnade
   som vanliga förslag skriver de aldrig till databasen.
   ========================================================= */

(function(){
  "use strict";

  /* =====================================================
     INSTÄLLNINGAR — det enda som ska ändras i den här filen

     Lämnas de tomma fungerar skärmen ändå — svaren sparas
     då bara lokalt i plattan.
     ===================================================== */

  var DB = {
    url:   "https://yykoaoildtqyclpregug.supabase.co",
    nyckel:"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inl5a29hb2lsZHRxeWNscHJlZ3VnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTAyMjgxODksImV4cCI6MjEwNTgwNDE4OX0.eUIpJAsQ_QrMVCsPo6V__MfbEy3BbGa-DNYDBBA8Nj8",
    enhet: "entre"       // namn på den här skärmen
  };

  /* ===================================================== */

  var SKARMAR = {
    standard: "index.html",
    a:        "forslag-a.html?skarp=1",
    b:        "forslag-b.html?skarp=1",
    c:        "forslag-c.html?skarp=1"
  };

  var LAGER     = "rkjh.feedback.v1";
  var SKARMVAL  = "rkjh.skarm";
  var TAK       = 500;          // så lagret inte växer i all oändlighet
  var KOLL_MS   = 15 * 1000;    // hur snabbt plattan märker ändringar från översikten

  var igang  = false;
  var egen   = "standard";
  var status = { lage:"av", text:"Databas: inte inkopplad" };

  function hdr(extra){
    var h = {
      "apikey":        DB.nyckel,
      "Authorization": "Bearer " + DB.nyckel,
      "Content-Type":  "application/json"
    };
    for (var k in extra) h[k] = extra[k];
    return h;
  }

  function bas(){ return DB.url.replace(/\/+$/, ""); }

  /* -------------------------------------------------------
     Lagring

     Varje svar skrivs ALLTID ner lokalt först, direkt, innan
     något nät är inblandat. Sen försöker vi skicka. Lyckas
     det inte ligger raden kvar i kön och går iväg nästa gång
     nätet är uppe — inget svar kan försvinna för att wifit
     hackar mitt i en kö. Kön delas av alla skärmar, så ett
     skärmbyte mitt i en kö tappar ingenting.
     ------------------------------------------------------- */

  function spara(betyg){
    if (!igang) return;
    var alla = las();

    alla.push({
      id:      Date.now() + "-" + Math.random().toString(36).slice(2, 8),
      betyg:   betyg,
      tid:     new Date().toISOString(),
      enhet:   DB.enhet,
      skickad: false
    });

    skriv(stada(alla));
    skicka();
  }

  /* Håller lagret under taket — men kastar bara rader som redan
     är skickade. Något som ligger kvar i kön får aldrig gallras
     bort, hur länge nätet än har varit nere.                    */

  function stada(alla){
    if (alla.length <= TAK) return alla;

    var overskott = alla.length - TAK;
    var kvar = [];

    for (var i = 0; i < alla.length; i++){
      if (overskott > 0 && alla[i].skickad){ overskott--; continue; }
      kvar.push(alla[i]);
    }
    return kvar;
  }

  /* Minnet är sanningen under pågående session; lagret är ett
     bästa-försök för att överleva omstart.                      */

  var minne = null;

  function las(){
    if (minne !== null) return minne;
    try { minne = JSON.parse(localStorage.getItem(LAGER) || "[]"); }
    catch(e){ minne = []; }
    return minne;
  }

  function skriv(alla){
    minne = alla;
    try { localStorage.setItem(LAGER, JSON.stringify(alla)); } catch(e){}
  }

  function rensa(){
    minne = [];
    try { localStorage.removeItem(LAGER); } catch(e){}
  }

  /* -------------------------------------------------------
     Skicka kön till databasen
     ------------------------------------------------------- */

  var skickar = false;

  function skicka(){
    if (skickar) return;
    if (!DB.url || !DB.nyckel){
      satt("av", "Databas: inte inkopplad");
      return;
    }

    var ko = las().filter(function(r){ return !r.skickad; });

    if (!ko.length){
      satt("ok", "Databas: allt skickat");
      return;
    }

    if (!navigator.onLine){
      satt("ko", "Nätet nere — " + ko.length + " i kö");
      return;
    }

    skickar = true;

    fetch(bas() + "/rest/v1/svar", {
      method: "POST",
      headers: hdr({ "Prefer":"return=minimal" }),
      body: JSON.stringify(ko.map(function(r){
        return { betyg:r.betyg, tid:r.tid, enhet:r.enhet };
      }))
    })
    .then(function(svar){
      if (!svar.ok) throw new Error("HTTP " + svar.status);

      // Bocka av exakt de rader som följde med anropet.
      var klara = {};
      ko.forEach(function(r){ klara[r.id] = true; });

      var nu = las();
      nu.forEach(function(r){ if (klara[r.id]) r.skickad = true; });
      skriv(nu);

      satt("ok", "Databas: allt skickat");
    })
    .catch(function(fel){
      satt("fel", "Kunde inte skicka — " + ko.length + " i kö");
      if (window.console) console.warn("[feedback]", fel.message);
    })
    .then(function(){ skickar = false; });
  }

  function satt(lage, text){
    status.lage = lage;
    status.text = text;
  }

  /* -------------------------------------------------------
     Skärmval och eventläge

     Översikten bestämmer. Pågår ett event byter plattan till
     eventskärmen; annars till den skärm som är vald. Svaret
     cachas så att en omstart utan nät ändå hamnar rätt. Når
     vi inte nätet händer ingenting — den skärm som visas är
     alltid det säkra läget.
     ------------------------------------------------------- */

  var gammalDb = false;   // skarm_lage() saknas: migreringen inte körd än

  function byt(url){
    location.replace(url);
  }

  function folj(lage){
    if (!lage) return;
    if (lage.event && lage.event.id){
      byt("event-skarmar.html?auto=1");
      return;
    }
    var mal = SKARMAR[lage.skarm] ? lage.skarm : "standard";
    try { localStorage.setItem(SKARMVAL, mal); } catch(e){}
    if (mal !== egen) byt(SKARMAR[mal]);
  }

  function rpc(namn){
    return fetch(bas() + "/rest/v1/rpc/" + namn, {
      method: "POST", headers: hdr(), body: "{}"
    });
  }

  function kolla(){
    if (!DB.url || !DB.nyckel) return;

    if (gammalDb){
      rpc("aktivt_event")
        .then(function(r){ return r.ok ? r.json() : null; })
        .then(function(e){ if (e && e.id) byt("event-skarmar.html?auto=1"); })
        .catch(function(){});
      return;
    }

    rpc("skarm_lage")
      .then(function(r){
        if (r.status === 404){ gammalDb = true; kolla(); return null; }
        return r.ok ? r.json() : null;
      })
      .then(folj)
      .catch(function(){});
  }

  /* -------------------------------------------------------
     Start
     ------------------------------------------------------- */

  function start(opt){
    if (igang) return;
    igang = true;
    egen = (opt && opt.skarm) || "standard";

    var cachad = null;
    try { cachad = localStorage.getItem(SKARMVAL); } catch(e){}
    if (cachad && SKARMAR[cachad] && cachad !== egen){
      byt(SKARMAR[cachad]);
      return;
    }

    skicka();
    window.addEventListener("online", function(){ skicka(); kolla(); });
    setInterval(skicka, 30000);

    kolla();
    setInterval(kolla, KOLL_MS);

    document.addEventListener("contextmenu", function(e){ e.preventDefault(); });
    document.addEventListener("dblclick",    function(e){ e.preventDefault(); });
  }

  window.Kiosk = {
    start:  start,
    svara:  spara,
    las:    las,
    rensa:  rensa,
    status: function(){ return status; },
    satt:   satt,
    kopplad: function(){ return !!(DB.url && DB.nyckel); }
  };
})();
