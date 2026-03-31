# Story: LLM Interaction Optimization

**Quelle:** E2E-Testplan Phase 3-5 (2026-03-31)
**Prioritaet:** High — reduziert Tool-Calls pro Session um ~50-60%
**Aufwand:** ~6-8h gesamt (11 unabhaengige Aenderungen in 2 Tiers)

## Kontext

Waehrend des vollstaendigen E2E-Tests (42 Free + 13 Pro Tools) wurden systematische
Ineffizienzen in der LLM-Tool-Interaktion beobachtet. Das Kernproblem ist nicht die
Geschwindigkeit einzelner Tools — die meisten antworten in 10-60ms. Das Kernproblem
ist die **Anzahl der Round-Trips** zwischen LLM und MCP-Server.

Jeder Round-Trip kostet:
- ~200-500ms MCP-Latenz (Netzwerk + Serialisierung)
- ~500ms-30s LLM-Denkzeit auf Anthropic's Seite (der eigentliche Killer)
- ~500-5000 Token im Context Window (besonders Screenshots und get_source)

In einer typischen 20-Minuten-Session mit UI-Automation werden ~60-80 Tool-Calls gemacht.
Davon sind ~30-40 vermeidbar: Orientierungs-Screenshots, get_source nur fuer Koordinaten,
WDA-Session-Management, Navigation als Multi-Step-Pattern.

Die Aenderungen sind in 2 Tiers organisiert:
- **Tier 1 (Low Hanging Fruit):** Kleine Aenderungen an bestehenden Tool-Parametern und Responses (~2-3h)
- **Tier 2 (Middle Hanging Fruit):** Neue Patterns und Composite-Operationen (~4-5h)

---

# Tier 1 — Low Hanging Fruit

Kleine, isolierte Aenderungen an bestehenden Tools. Jede ist in 15-30 Minuten
umsetzbar und sofort wirksam.

---

## 1. find_element: Frame im Response mitliefern

**Problem:**
`find_element` gibt nur `"element-4 found (15ms)"` zurueck. Fuer koordinatenbasierte Gesten braucht das LLM den Frame, muss aber `get_source` aufrufen und 3-15k chars JSON parsen.

**Ist-Zustand (4 Calls):**
```
find_element("Double Tap Zone")     → "element-4 found"
get_source(format: json)            → 3533 chars JSON
[LLM parst JSON, extrahiert Frame]
double_tap(x: 201, y: 403)
```

**Soll-Zustand (2 Calls):**
```
find_element("Double Tap Zone")     → "element-4 found — frame: {x:101, y:363, w:200, h:80}"
double_tap(x: 201, y: 403)
```

**Implementierung:**
- Nach erfolgreichem Find: WDA `GET /element/{id}/rect` aufrufen
- Response-String um ` — frame: {x:N, y:N, w:N, h:N}` erweitern
- Optional: `center: {x:N, y:N}` fuer sofortige Gesten-Nutzung
- Fallback: Wenn rect-Aufruf fehlschlaegt, bisheriges Format beibehalten

**Betroffene Dateien:**
- `Sources/SilbercueSwiftCore/Tools/UIAutomation/FindElementTool.swift`

**Akzeptanzkriterien:**
- [x] find_element Response enthaelt Frame (x, y, width, height)
- [x] find_elements Response enthaelt Frame pro Element
- [x] Kein Performance-Regression (rect-Lookup sollte <5ms sein)

---

## 2. Gesten-Tools: element_id als Alternative zu Koordinaten

**Problem:**
`double_tap`, `long_press`, `pinch` akzeptieren nur rohe Koordinaten. Das LLM muss Koordinaten schaetzen oder berechnen — fehleranfaellig. Erster `double_tap(x:200, y:490)` traf zwischen zwei Zonen. Erster `drag_and_drop` mit Koordinaten landete auf dem Homescreen.

`drag_and_drop` zeigt wie es besser geht — `source_element`/`target_element` funktionierte beim ersten Versuch.

**Soll:**
```
find_element("Double Tap Zone") → element-4
double_tap(element_id: "element-4")   // WDA holt Position intern
```

**Implementierung:**
- Optionalen `element_id` Parameter zu `double_tap`, `long_press`, `pinch` hinzufuegen
- Wenn gesetzt: WDA `GET /element/{id}/rect` → center berechnen → Geste ausfuehren
- Koordinaten bleiben als Fallback erhalten (nicht-breaking)
- Validierung: element_id XOR (x + y) muss gesetzt sein

**Betroffene Dateien:**
- `Sources/SilbercueSwiftCore/Tools/Pro/ProGestureTools.swift`

**Akzeptanzkriterien:**
- [x] double_tap(element_id: "...") funktioniert
- [x] long_press(element_id: "...") funktioniert
- [x] pinch(element_id: "...") funktioniert (center = element center)
- [x] Koordinaten-Parameter funktionieren weiterhin
- [x] Fehler wenn weder element_id noch Koordinaten angegeben

---

## 3. launch_app / build_run_sim: Auto-WDA-Session

**Problem:**
Nach jedem App-Start muss das LLM separat `wda_create_session` aufrufen. Vergisst es das, zeigt der naechste `find_element` oder `get_source` SpringBoard statt die App. Das passierte in der Test-Session und kostete einen Extra-Screenshot + Diagnose.

**Ist (2 Calls):**
```
launch_app(bundle_id: "com.silbercue.testharness")
wda_create_session(bundle_id: "com.silbercue.testharness")
```

**Soll (1 Call):**
```
launch_app(bundle_id: "com.silbercue.testharness")
// → App launched + WDA session created automatically
```

**Implementierung:**
- In `launch_app` und `build_run_sim`: Nach erfolgreichem Launch pruefen ob WDA laeuft
- Wenn ja: Automatisch `POST /session` mit dem launched bundle_id aufrufen
- Response um "WDA session: {id}" erweitern
- Kein Extra-Parameter noetig — WDA-Session-Update ist immer sinnvoll nach App-Launch
- Edge Case: WDA nicht erreichbar → Warning, kein Fehler

**Betroffene Dateien:**
- `Sources/SilbercueSwiftCore/Tools/Simulator/LaunchAppTool.swift`
- `Sources/SilbercueSwiftCore/Tools/Build/BuildRunSimTool.swift`

**Akzeptanzkriterien:**
- [x] launch_app erstellt automatisch WDA-Session wenn WDA erreichbar
- [x] build_run_sim erstellt automatisch WDA-Session wenn WDA erreichbar
- [x] Response zeigt Session-ID
- [x] Wenn WDA nicht laeuft: Warning in Response, kein Fehler
- [x] wda_create_session funktioniert weiterhin fuer manuelle Nutzung

---

## 4. Simulator-Disambiguierung: Booted bevorzugen

**Problem:**
`accessibility_check(simulator: "iPhone 16 Pro")` waehlte den shutdown iOS-18.2-Simulator (450E2523) statt den booted iOS-26.4 (51ACA7C0). Es gibt 5+ Simulatoren mit dem Namen "iPhone 16 Pro" in verschiedenen Runtimes.

**Aktuelle Logik:** Erster Match nach Name (vermutlich alphabetisch oder nach UDID).

**Soll-Logik (Prioritaet):**
1. Exakter UDID-Match → sofort
2. Name-Match + Booted → bevorzugt
3. Name-Match + gleiche Runtime wie default/zuletzt verwendet → naechste Prioritaet
4. Name-Match + Shutdown → letzte Option

**Implementierung:**
- In `SmartContext` / Simulator-Resolution: Nach Name-Match sortieren nach Boot-Status
- Wenn mehrere booted: Warning mit Liste ausgeben

**Betroffene Dateien:**
- `Sources/SilbercueSwiftCore/SmartContext/` (Simulator-Resolution-Logik)

**Akzeptanzkriterien:**
- [x] `simulator: "iPhone 16 Pro"` waehlt den gebooteten wenn einer laeuft
- [x] Wenn keiner gebootet: waehlt den mit neuester Runtime
- [x] Wenn mehrere gebootet: Warning mit Optionen

---

## 5. multi_device_check: Dark Mode mit 1 Simulator erlauben

**Problem:**
`multi_device_check(simulators: "iPhone 16 Pro", dark_mode: true)` gibt Fehler "Need at least 2 simulators". Dark-Mode-Test auf einem einzelnen Geraet ist aber ein haeufiger Use Case.

**Soll:**
- `dark_mode: true` mit 1 Simulator erlauben → Light + Dark Screenshots + Diff
- Device-Vergleich weiterhin 2+ Simulatoren erfordern
- Layout Score basiert dann nur auf Light-vs-Dark-Diff

**Implementierung:**
- Validierung aendern: `simulators.count >= 2` nur wenn kein Modifier (dark_mode/landscape) aktiv
- Wenn 1 Simulator + dark_mode: Light screenshotten, Appearance umschalten, Dark screenshotten, Diff berechnen

**Betroffene Dateien:**
- `Sources/SilbercueSwiftCore/Tools/Pro/MultiDeviceCheckTool.swift`

**Akzeptanzkriterien:**
- [ ] 1 Simulator + dark_mode → Light + Dark Screenshots + Diff
- [ ] 1 Simulator + landscape → Portrait + Landscape Screenshots
- [ ] 1 Simulator ohne Modifier → Fehler (unveraendert)
- [ ] 2+ Simulatoren → Verhalten unveraendert

---

# Tier 2 — Middle Hanging Fruit

Groessere Aenderungen, die neue Patterns einfuehren oder bestehende Tool-Responses
grundlegend erweitern. Jede ist in 30-60 Minuten umsetzbar. Die Kombinationswirkung
mit Tier 1 ist ueberproportional — Tier 1 reduziert Calls pro Muster, Tier 2
eliminiert ganze Muster.

---

## 6. Screenshot nach Action: Inline-Verifikation

**Was es ist:**
Ein optionaler `screenshot: true` Parameter auf allen Action-Tools, der automatisch
nach der Aktion einen Screenshot macht und ihn in der Response mitliefert.

**Warum das wichtig ist:**
Das haeufigste Muster in der gesamten E2E-Session war "Action + Verifikation":

```
click_element("element-3")    → "Clicked (35ms)"
screenshot()                  → [Image, 12ms]
[LLM denkt 2-10s: "OK, sieht richtig aus"]
```

Das passierte mindestens 12x in einer einzigen Session. Jedes Mal sind das 2 Tool-Calls
statt 1, plus die LLM-Denkzeit zwischen den Calls. Die LLM-Denkzeit ist der teuerste
Teil — das Modell muss entscheiden "OK, die Aktion ist durch, jetzt brauche ich einen
Screenshot", was trivial ist aber trotzdem einen kompletten Inference-Zyklus kostet.

**Wie es danach aussieht:**
```
click_element("element-3", screenshot: true)
→ "Clicked (35ms)" + [Inline Screenshot]
```

Ein Call, eine Antwort, das LLM sieht sofort das Ergebnis.

**Was sich aendert:**
Optionalen `screenshot` Boolean-Parameter zu allen Action-Tools hinzufuegen:
`click_element`, `double_tap`, `long_press`, `swipe`, `pinch`, `drag_and_drop`,
`type_text`, `handle_alert`. Wenn `true`: Nach der Aktion 200ms warten (UI-Animation),
dann Screenshot machen und als zweites Content-Element in der MCP-Response anhaengen
(Text + Image).

**Betroffene Dateien:**
- Alle Action-Tool-Dateien in `Sources/SilbercueSwiftCore/Tools/`
- Empfehlung: Shared Helper `ActionWithScreenshot` der die Logik kapselt

**Akzeptanzkriterien:**
- [x] click_element(screenshot: true) liefert Screenshot in der Response
- [x] Alle 8 Action-Tools unterstuetzen den Parameter
- [x] Default ist false (kein Breaking Change)
- [x] Screenshot-Delay ist konfigurierbar (default 200ms)
- [x] Response enthaelt sowohl Text- als auch Image-Content

**Geschaetzte Ersparnis:** 10-15 Tool-Calls pro Session

---

## 7. Screenshot-Aufloesung: Quality-Parameter

**Was es ist:**
Ein `quality` Parameter auf dem Screenshot-Tool, der zwischen voller Retina-Aufloesung
und einer kompakten Vorschau umschalten kann.

**Warum das wichtig ist:**
Jeder Screenshot in der E2E-Session war 1206x2622 Pixel (3x Retina), 115-380KB gross.
Wir haben ~20 Screenshots gemacht — das sind potentiell 3-7MB Bilddaten im Context Window.

Das Context Window hat ein Limit. Wenn es voll wird, komprimiert Claude Code aeltere
Nachrichten. Das bedeutet: Je groesser die Screenshots, desto frueher verliert das LLM
Kontext ueber fruehere Entscheidungen und Ergebnisse.

Fuer 90% aller Screenshot-Zwecke (UI-Verifikation, "bin ich auf dem richtigen Screen?",
"hat sich der Zaehler geaendert?") reicht die halbe Aufloesung voellig aus. Text ist
bei 603x1311 (1x Punkte) immer noch problemlos lesbar. Nur fuer Visual Regression
(pixel-perfekter Vergleich) braucht man die volle Aufloesung.

**Wie es danach aussieht:**
```
screenshot()                    → 1206x2622, ~200KB  (default, wie bisher)
screenshot(quality: "compact")  → 603x1311,  ~50KB   (75% kleiner)
screenshot(quality: "full")     → 1206x2622, ~200KB  (explizit volle Qualitaet)
```

**Was sich aendert:**
Nach dem Screenshot-Capture ein `CGImage` Resize-Schritt:
- `"compact"`: Bild auf 1x Punktegroesse skalieren (Breite/3, Hoehe/3)
- `"full"` oder default: Keine Aenderung
- JPEG-Qualitaet bei compact auf 80% setzen (weitere Groessenreduktion)

Wichtig: Der `quality` Parameter sollte auch von Item 6 (Screenshot nach Action)
genutzt werden. Actions die `screenshot: true` setzen sollten automatisch `compact`
verwenden, weil der Screenshot dort nur zur Verifikation dient.

**Betroffene Dateien:**
- `Sources/SilbercueSwiftCore/Tools/Screenshot/ScreenshotTool.swift`
- Screenshot-Capture-Pipeline (CGImage Resize vor Base64-Encoding)

**Akzeptanzkriterien:**
- [x] screenshot(quality: "compact") liefert ~1/4 der Pixelzahl
- [x] Text ist bei compact-Qualitaet lesbar (manuell verifizieren)
- [x] Default-Verhalten ist unveraendert
- [x] Dategroesse bei compact ist <60KB (typisch)
- [x] Visual Regression Tools (save_baseline, compare_visual) nutzen immer full

**Geschaetzte Ersparnis:** ~75% weniger Context-Window-Verbrauch pro Screenshot

---

## 8. get_source: Pruned Mode

**Was es ist:**
Ein neues Format `"pruned"` fuer get_source, das die View-Hierarchie auf die
semantisch relevanten Elemente reduziert.

**Warum das wichtig ist:**
`get_source(format: json)` lieferte in der E2E-Session 3.500-15.000 Zeichen.
80% davon waren tief verschachtelte Container-Elemente vom Typ `"Other"` ohne
Label, Identifier oder Value — also ohne jede Information die das LLM braucht.

Das LLM muss diesen gesamten JSON-Blob in sein Context Window laden und dann
die 5-10 relevanten Elemente herausfiltern. Das ist nicht nur langsam (Token-Verbrauch),
sondern auch fehleranfaellig — das LLM kann in der Tiefe der Verschachtelung
die Uebersicht verlieren.

Der Pruned Mode gibt dem LLM genau das was es braucht: Eine flache Liste aller
interagierbaren oder informativen Elemente mit ihrem Frame.

**Wie es danach aussieht:**

Vorher (3.500+ chars, verschachtelt):
```json
{"type":"Other","children":[{"type":"Other","children":[{"type":"Other",
"children":[{"type":"StaticText","identifier":"tap-count","label":"Tap Count: 0",
"frame":{"x":108,"y":183,"width":185,"height":40}}...]}]}]}
```

Nachher mit `get_source(format: "pruned")` (~500 chars, flach):
```json
[
  {"type":"NavigationBar","label":"Button Tests","frame":{"x":0,"y":62,"w":402,"h":106}},
  {"type":"Button","id":"BackButton","label":"Test Harness","frame":{"x":16,"y":62,"w":44,"h":44}},
  {"type":"StaticText","id":"tap-count","label":"Tap Count: 0","frame":{"x":108,"y":183,"w":185,"h":40}},
  {"type":"Button","id":"btn-tap","label":"Tap Me","frame":{"x":150,"y":244,"w":101,"h":58}},
  {"type":"StaticText","id":"zone-doubletap","label":"Double Tap Zone","frame":{"x":101,"y":363,"w":200,"h":80}},
  {"type":"StaticText","id":"zone-longpress","label":"Long Press Zone","frame":{"x":101,"y":503,"w":200,"h":80}},
  {"type":"Button","id":"btn-reset","label":"Reset","frame":{"x":179,"y":803,"w":43,"h":20}}
]
```

7 Elemente statt ~50 verschachtelte Nodes. Jedes mit Frame, sofort nutzbar.

**Was sich aendert:**
Tree-Walk ueber die WDA-Hierarchie mit Filterbedingung:
- Element behalten wenn: `label != nil` ODER `identifier != nil` ODER `value != nil`
- Element behalten wenn: Typ ist Button, TextField, StaticText, Switch, Slider, Cell,
  Image (mit Label), NavigationBar, Alert, Sheet
- Alles andere (Container, Window, "Other" ohne Attribute) ueberspringen
- Kinder von behaltenen Elementen weiter traversieren
- Ausgabe als flaches Array (keine Verschachtelung), sortiert nach y-Position (top-to-bottom)

**Betroffene Dateien:**
- `Sources/SilbercueSwiftCore/Tools/UIAutomation/GetSourceTool.swift`

**Akzeptanzkriterien:**
- [x] get_source(format: "pruned") liefert flaches Array
- [x] Nur Elemente mit Label/Identifier/Value oder interagierbare Typen
- [x] Jedes Element hat Frame
- [x] Ausgabe ist 80-90% kleiner als JSON-Format (91% erreicht: 12105→1102 chars)
- [x] Bestehende Formate (json, xml, description) sind unveraendert

**Geschaetzte Ersparnis:** 80-90% weniger Token wenn Seitenstruktur abgefragt wird

---

## 9. Composite: navigate_and_verify

**Was es ist:**
Ein neues Tool `navigate` das den haeufigsten Multi-Call-Flow in einen einzigen
Aufruf zusammenfasst: Element finden → antippen → warten → Screenshot machen.

**Warum das wichtig ist:**
Navigation war das haeufigste Multi-Step-Pattern in der gesamten E2E-Session.
Jede Navigation zu einem neuen Screen sah so aus:

```
find_element("Drag & Drop Tests")   → element-6       [Call 1]
click_element("element-6")          → Clicked          [Call 2]
screenshot()                        → [Image]          [Call 3]
[LLM prueft: "Bin ich am richtigen Ort?"]
```

Manchmal sogar 4-5 Calls wenn zuerst der Back-Button gefunden werden musste.
In der E2E-Session gab es mindestens 6 solche Navigationen. Das sind 18+ Calls
die eigentlich 6 sein koennten.

**Wie es danach aussieht:**
```
navigate(target: "Drag & Drop Tests")
→ "Navigated via tap on 'Drag & Drop Tests' (element-6, 35ms). Settled 300ms."
  + [Inline Screenshot]
```

Ein Call, der Screenshot zeigt sofort ob die Navigation erfolgreich war.

**Was sich aendert:**
Neues Tool `navigate` das intern orchestriert:
1. `find_element(predicate: "label == '{target}'")` — Element suchen
2. `click_element(element_id)` — Antippen
3. `usleep(300_000)` — 300ms fuer Animation warten
4. `screenshot(quality: "compact")` — Ergebnis aufnehmen
5. Alles in einer Response buendeln

Optionale Parameter:
- `back: true` — Zuerst den Back-Button finden und tippen (zurueck navigieren), dann target suchen
- `settle_ms: 500` — Wartezeit anpassen (z.B. fuer langsame Animationen)
- `scroll: true` — SmartScroll nutzen wenn target nicht sichtbar

**Betroffene Dateien:**
- Neues Tool: `Sources/SilbercueSwiftCore/Tools/UIAutomation/NavigateTool.swift`
- ToolRegistry: Registrierung im Free-Tier (Navigation ist Basis-Funktionalitaet)

**Akzeptanzkriterien:**
- [ ] navigate(target: "X") findet Element, tippt, wartet, screenshottet
- [ ] navigate(target: "X", back: true) navigiert erst zurueck dann vorwaerts
- [ ] navigate(target: "X", scroll: true) nutzt SmartScroll wenn noetig
- [ ] Fehlermeldung wenn Element nicht gefunden wird
- [ ] Screenshot nutzt compact-Qualitaet

**Geschaetzte Ersparnis:** 12-18 Tool-Calls pro Session mit UI-Navigation

---

## 10. State Footer in Tool-Responses

**Was es ist:**
Jede Tool-Response enthaelt eine einzeilige Statuszeile die dem LLM sagt
wo es sich gerade befindet — ohne einen Extra-Screenshot machen zu muessen.

**Warum das wichtig ist:**
Das LLM macht regelmaessig "Orientierungs-Screenshots" — reine Standortbestimmung
ohne inhaltliches Interesse am Screenshot. Nach dem Homescreen-Unfall in der
E2E-Session zum Beispiel:

```
screenshot()              → [380KB] "Ah, ich bin auf SpringBoard"
launch_app()              → "Launched"
screenshot()              → [150KB] "OK, App ist da"
wda_create_session()      → "Session created"
screenshot()              → [150KB] "Gut, Hauptmenue sichtbar"
```

3 Screenshots (680KB Context) nur um zu wissen wo man ist. Wenn jede Response
den aktuellen State mitteilt, faellt das weg:

```
launch_app()
→ "Launched com.silbercue.testharness"
  [state: app=testharness | screen=Test Harness | sim=iPhone 16 Pro (51AC)]
```

Das LLM weiss sofort: App laeuft, Hauptmenue ist sichtbar, richtiger Simulator.

**Was sich aendert:**
Nach jeder Tool-Ausfuehrung wird ein State-Footer angehaengt. Die Informationen
kommen aus bestehenden Caches — kein zusaetzlicher WDA-Call noetig:

- **App:** Aus WDA-Session-Cache (`bundleId` der aktiven Session)
- **Screen:** Aus dem letzten NavigationBar-Label (wenn bei letztem get_source/find_element gesehen)
  oder "unknown" wenn kein Cache vorhanden
- **Simulator:** Aus SmartContext-Default (Name + 4-char UDID)

Format: `[state: app=X | screen=Y | sim=Z]`

Wenn kein State verfuegbar (z.B. kein WDA, kein Simulator): Footer weglassen.
Der Footer soll helfen, nicht stoeren.

**Betroffene Dateien:**
- `Sources/SilbercueSwiftCore/Tools/` — Shared Response-Builder
- State-Cache Klasse die NavigationBar-Label und aktive App trackt

**Akzeptanzkriterien:**
- [ ] Action-Tools (click, tap, type, etc.) zeigen State-Footer
- [ ] Screenshot-Tool zeigt State-Footer
- [ ] Footer zeigt aktive App, aktuellen Screen, Simulator
- [ ] Footer fehlt wenn keine Daten verfuegbar (kein Crash)
- [ ] Kein zusaetzlicher WDA-Call fuer den Footer

**Geschaetzte Ersparnis:** 2-5 Orientierungs-Screenshots pro Session eliminiert

---

## 11. Parallel Find: Mehrere Elemente in einem Call

**Was es ist:**
Eine Erweiterung von `find_elements` die mehrere benannte Elemente in einem
Call sucht und alle mit Frame zurueckgibt.

**Warum das wichtig ist:**
Vor komplexeren Interaktionen (Drag & Drop, Vergleiche, Multi-Element-Checks)
braucht das LLM oft 2-4 separate find_element Calls:

```
find_element("drag-item-Echo")    → element-1     [Call 1]
find_element("drag-item-Alpha")   → element-2     [Call 2]
drag_and_drop(source: "element-1", target: "element-2")
```

Oder beim Verifizieren von Seitenzustand:
```
find_element("tap-count")         → element-3, label="Tap Count: 0"    [Call 1]
find_element("doubletap-count")   → element-4, label="Double Tap: 0"   [Call 2]
find_element("longpress-count")   → element-5, label="Long Press: 0"   [Call 3]
```

3 Calls die eigentlich 1 sein koennten.

**Wie es danach aussieht:**
```
find_elements(accessibility_ids: ["drag-item-Echo", "drag-item-Alpha"])
→ [
    {"id": "element-1", "accessibility_id": "drag-item-Echo", "frame": {...}},
    {"id": "element-2", "accessibility_id": "drag-item-Alpha", "frame": {...}}
  ]
```

**Was sich aendert:**
Neuer optionaler Parameter `accessibility_ids` (Array) auf `find_elements`.
Wenn gesetzt: Fuer jede ID einen WDA-Find ausfuehren (intern parallel via
DispatchGroup), Ergebnisse buendeln, Frame pro Element mitliefern.

WDA hat kein natives Batch-Find, aber der MCP-Server kann N Requests parallel
an den lokalen WDA-HTTP-Server schicken. Bei 3 Finds a 15ms ist das ~20ms
total statt 3x15ms = 45ms sequentiell.

**Betroffene Dateien:**
- `Sources/SilbercueSwiftCore/Tools/UIAutomation/FindElementsTool.swift`

**Akzeptanzkriterien:**
- [ ] find_elements(accessibility_ids: [...]) findet mehrere Elemente in einem Call
- [ ] Jedes gefundene Element hat Frame
- [ ] Nicht-gefundene IDs werden als Error in der Response aufgelistet (kein Abbruch)
- [ ] Performance: N parallele Finds statt sequentiell
- [ ] Bestehende find_elements Funktionalitaet (class name, predicate) bleibt unveraendert

**Geschaetzte Ersparnis:** 3-5 Tool-Calls pro Session bei Multi-Element-Szenarien

---

# Tier 3 — High Hanging Fruit: Orchestra/Operator-Architektur

Das fundamentale Problem hinter allen Tier-1/2-Optimierungen: **Das LLM ist der
Flaschenhals, nicht die Tools.**

Messwerte aus der E2E-Session:
- Durchschnittliche MCP-Tool-Antwortzeit: 10-60ms
- Durchschnittliche LLM-Denkzeit zwischen Calls: 2-30 Sekunden
- Extremfall: 30 Minuten zwischen Screenshot-Ergebnis und naechstem Tool-Call
- **99% der Wartezeit ist LLM-Processing, nicht Tool-Ausfuehrung**

Tier 1+2 reduzieren die *Anzahl* der Round-Trips. Aber jeder verbleibende Trip
geht durch das langsame Orchestrator-LLM (Opus/Sonnet). Das ist wie eine Autobahn
optimieren wenn das eigentliche Problem die Ampeln sind.

## Die Idee: Drei Geschwindigkeitsstufen

```
┌─────────────────────────────────────────────────────┐
│  OPUS / SONNET  (Orchestrator)                      │
│  "Teste alle Gesten auf der Button-Seite"           │
│  Denkt strategisch, plant, bewertet Ergebnisse      │
│  Geschwindigkeit: 2-30s pro Entscheidung            │
└──────────────┬──────────────────────────────────────┘
               │ Delegiert strukturierte Auftraege
               ▼
┌─────────────────────────────────────────────────────┐
│  HAIKU  (Operator)            [Optional]            │
│  "Counter zeigt 0, Zone ist bei y=403, tippe dort"  │
│  Trifft einfache Entscheidungen, reagiert auf Fehler│
│  Geschwindigkeit: 200-500ms pro Entscheidung        │
└──────────────┬──────────────────────────────────────┘
               │ Fuehrt Tool-Calls aus
               ▼
┌─────────────────────────────────────────────────────┐
│  MCP-SERVER  (Executor)                             │
│  Deterministisch, kein LLM noetig                   │
│  Fuehrt Sequenzen autonom aus, liefert Report       │
│  Geschwindigkeit: 10-60ms pro Tool                  │
└─────────────────────────────────────────────────────┘
```

Der Clou: **Nicht alles braucht ein LLM.** Es gibt drei Kategorien von Operationen:

### Kategorie A: Deterministisch (kein LLM noetig)

Feste Sequenzen die immer gleich ablaufen:
- "Navigiere zu Screen X" → find + click + wait + screenshot
- "Tippe auf Element Y und verifiziere Label Z" → find + action + find + check
- "Mache Screenshots in 3 Dynamic Type Groessen" → loop(set_size + relaunch + screenshot)

Diese Sequenzen koennen als **strukturierte Plaene** an den MCP-Server geschickt
werden. Der Server fuehrt sie intern aus — null LLM-Overhead, null Round-Trips.
Das ist de facto was accessibility_check und localization_check intern bereits tun.

### Kategorie B: Einfache Entscheidungen (Haiku)

Reaktion auf unerwartete Zustaende:
- "Ein Alert ist erschienen — was tun?" → Haiku liest Text, entscheidet accept/dismiss
- "Element nicht gefunden — scrollen oder Fehler?" → Haiku entscheidet
- "Screenshot sieht anders aus als erwartet — weitermachen oder abbrechen?"

Haiku ist 10-20x schneller als Opus und genuegt fuer diese Entscheidungen.

### Kategorie C: Strategische Planung (Opus/Sonnet)

Nur der Orchestrator braucht das grosse Modell:
- "Welche Tests sollen als naechstes laufen?"
- "Dieser Bug sieht komisch aus — wie debuggen wir?"
- "Das Layout ist kaputt — was ist die Ursache?"
- Ergebnis-Bewertung und Berichterstattung

---

## Konkreter Vorschlag: run_plan Tool

### Wie es heute funktioniert (E2E double_tap Test):

```
Opus: find_element("Button & Tap Tests")     [2s denken + 30ms tool]
Opus: click_element("element-3")             [2s denken + 35ms tool]
Opus: screenshot()                           [2s denken + 12ms tool]
Opus: "Ah, Button Tests Seite."              [3s denken]
Opus: find_element("Double Tap Zone")        [2s denken + 15ms tool]
Opus: get_source(json)                       [2s denken + 400ms tool]
Opus: "Frame ist x:101, y:363..."            [5s denken, 3500 chars parsen]
Opus: double_tap(x: 201, y: 403)            [2s denken + 20ms tool]
Opus: screenshot()                           [2s denken + 12ms tool]
Opus: "Zaehler ist jetzt 1. PASS."          [3s denken]
```

**10 Round-Trips, ~25 Sekunden LLM-Denkzeit, ~550ms Tool-Zeit.**
Das LLM macht 98% nichts ausser warten und triviale Entscheidungen treffen.

### Wie es mit run_plan funktionieren koennte:

```
Opus: run_plan({                             [3s denken, 1 Call]
  steps: [
    {navigate: "Button & Tap Tests"},
    {verify: {screen_contains: ["Tap Me", "Double Tap Zone"]}},
    {find: "Double Tap Zone", as: "target"},
    {double_tap: {element: "$target"}},
    {verify: {element_label: "doubletap-count", equals: "Double Tap: 1"}},
    {screenshot: {quality: "compact", label: "after-double-tap"}}
  ]
})

MCP-Server fuehrt intern aus:                [~500ms total, 0 LLM-Overhead]
  ✓ find("Button & Tap Tests") + click → 80ms
  ✓ settle 300ms
  ✓ find("Tap Me") → found, find("Double Tap Zone") → found
  ✓ find("Double Tap Zone") → rect → center(201, 403)
  ✓ double_tap(201, 403) → 20ms
  ✓ find("doubletap-count") → label "Double Tap: 1" ✓
  ✓ screenshot → [compact image]

→ Response:
  "Plan executed: 6/6 steps passed (487ms)
   Step 4 (double_tap): tapped Double Tap Zone at (201, 403)
   Step 5 (verify): doubletap-count = 'Double Tap: 1' ✓
   [Screenshot: after-double-tap]"
```

**1 Round-Trip, ~3 Sekunden LLM-Denkzeit, ~500ms Tool-Zeit.**
50x schneller. Und stabiler, weil der MCP-Server die Koordinaten intern berechnet.

### Plan-Syntax (Entwurf)

```json
{
  "steps": [
    {"navigate": "Screen Name"},
    {"navigate_back": true},
    {"find": "accessibility_id or label", "as": "variable_name"},
    {"find_all": ["id1", "id2"], "as": ["var1", "var2"]},
    {"click": {"element": "$variable"}},
    {"click": "direct label (shorthand)"},
    {"double_tap": {"element": "$variable"}},
    {"long_press": {"element": "$variable", "duration_ms": 1000}},
    {"swipe": {"direction": "up"}},
    {"type": {"text": "Hello", "element": "$variable"}},
    {"screenshot": {"quality": "compact", "label": "name"}},
    {"wait": 500},
    {"verify": {"screen_contains": ["Label A", "Label B"]}},
    {"verify": {"element_label": "id", "equals": "expected text"}},
    {"verify": {"element_label": "id", "contains": "partial"}},
    {"verify": {"element_exists": "accessibility_id"}},
    {"verify": {"element_not_exists": "accessibility_id"}},
    {"if_failed": "skip_rest | continue | abort"}
  ],
  "on_error": "abort_with_screenshot",
  "timeout_ms": 30000
}
```

Regeln:
- `$variable` referenziert ein vorher gefundenes Element
- `navigate` ist Shorthand fuer find + click + wait + verify
- `verify` schlaegt fehl wenn Bedingung nicht erfuellt → on_error greift
- Screenshots werden nur gemacht wenn explizit angefordert (spart Context)
- Jeder Step hat ein internes Timeout (default 5s)

### Wann braucht man Haiku als Operator?

Der deterministische run_plan deckt ~80% der Faelle ab. Fuer die restlichen 20%
braucht man ein schnelles LLM:

1. **Visuelle Beurteilung:** "Sieht dieses Layout kaputt aus?" → Haiku mit Vision
2. **Adaptive Reaktion:** "Element nicht gefunden nach Scroll — anderer Approach?"
3. **Unstrukturierte Verifikation:** "Ist die Fehlermeldung sinnvoll?"

Hierfuer koennte ein `run_plan_adaptive` Tool existieren, das intern Haiku aufruft
wenn ein Step fehlschlaegt oder eine visuelle Beurteilung noetig ist:

```json
{
  "steps": [
    {"navigate": "Settings"},
    {"screenshot": {"judge": "Is the settings page fully loaded?"}},
    {"click": "Delete Account"},
    {"handle_unexpected": "If an alert appears, read it and decide"}
  ],
  "operator_model": "haiku",
  "operator_api_key": "$ANTHROPIC_API_KEY"
}
```

Haiku wuerde als Entscheider einspringen — nur wenn noetig, nicht fuer jeden Step.

### Architektur-Ueberlegungen

**API-Key-Thema:** Der MCP-Server braeuchte Zugang zu einer LLM-API fuer den
Operator. Optionen:
- Env-Var `ANTHROPIC_API_KEY` (der Nutzer stellt bereit)
- Kein Operator-LLM → reiner deterministischer run_plan (immer noch 50x schneller)
- Lokales Small Model (llama.cpp, MLX) → kein API-Key noetig, ~100ms Latenz

**Fehlerbehandlung:** Wenn ein Plan-Step fehlschlaegt:
- `abort_with_screenshot`: Screenshot + Fehlerbericht → zurueck an Orchestrator
- `continue`: Naechster Step, Fehler wird im Report notiert
- `retry(3)`: Bis zu 3 Versuche mit kurzer Pause

**Rueckgabe an Orchestrator:** Der Report muss kompakt sein. Nicht jeden Step
einzeln melden, sondern:
- Zusammenfassung: "6/6 passed" oder "4/6 passed, 2 failed"
- Nur bei Fehlern: Details + Screenshot
- Nur bei explizitem `screenshot`-Step: Bild zurueckgeben

---

## Impact-Schaetzung

| Approach | Round-Trips (E2E-Session) | LLM-Wartezeit | Tool-Zeit |
|----------|--------------------------|---------------|-----------|
| Heute (Opus direkt) | ~70 | ~5-15 Minuten | ~4 Sekunden |
| Tier 1+2 Optimierungen | ~35 | ~3-8 Minuten | ~3 Sekunden |
| run_plan (deterministisch) | ~8-12 | ~30-60 Sekunden | ~4 Sekunden |
| run_plan + Haiku Operator | ~5-8 | ~20-40 Sekunden | ~5 Sekunden |

**Der Sprung von Tier 2 zu run_plan ist groesser als von Heute zu Tier 2.**

run_plan allein (ohne Haiku) wuerde die E2E-Session von ~15 Minuten LLM-Wartezeit
auf ~1 Minute reduzieren. Der Orchestrator schreibt 5-8 Plaene, der MCP-Server
fuehrt jeden in <1 Sekunde aus.

---

## Implementierungsaufwand

| Komponente | Aufwand | Abhaengigkeiten |
|-----------|---------|-----------------|
| Plan-Parser (JSON → Steps) | 2-3h | — |
| Step-Executor (deterministic) | 3-4h | Tier 1 Items 1+2 (Frame + element_id) |
| Variable-System ($target) | 1h | Step-Executor |
| Verify-Engine | 2h | Step-Executor |
| Report-Generator | 1h | Step-Executor |
| **Summe run_plan** | **~10h** | Tier 1 als Voraussetzung |
| Haiku-Operator Integration | 4-6h | run_plan + API-Key-Handling |

Tier 1 (2-3h) → run_plan (10h) → Haiku-Operator (4-6h)

Der deterministische run_plan ist der groesste Hebel und braucht kein externes LLM.
Der Haiku-Operator ist ein optionales Add-on fuer die 20% adaptiven Faelle.

---

# Gesamtpriorisierung

## Tier 1 — Low Hanging Fruit (~2-3h)

| # | Aenderung | Aufwand | Calls gespart | Context gespart | Empfehlung |
|---|-----------|---------|---------------|-----------------|------------|
| 1 | Frame in find_element | 15 min | 3-10 | Hoch (kein get_source) | Sofort |
| 2 | element_id in Gesten | 30 min | 5-10 | Mittel | Sofort |
| 3 | Auto-WDA bei Launch | 30 min | 2-4 | — | Naechstes Release |
| 4 | Booted-Prio Simulator | 20 min | 1-2 | — | Naechstes Release |
| 5 | 1-Device Dark Mode | 20 min | 1 | — | Backlog |

## Tier 2 — Middle Hanging Fruit (~4-5h)

| # | Aenderung | Aufwand | Calls gespart | Context gespart | Empfehlung |
|---|-----------|---------|---------------|-----------------|------------|
| 6 | Screenshot nach Action | 45 min | 10-15 | Mittel | Sofort (groesster Einzelhebel) |
| 7 | Screenshot Aufloesung | 30 min | 0 | **75% pro Screenshot** | Sofort |
| 8 | get_source pruned | 45 min | 0 | **80-90% pro Aufruf** | Naechstes Release |
| 9 | navigate_and_verify | 60 min | 12-18 | Mittel | Naechstes Release |
| 10 | State Footer | 30 min | 2-5 | Klein | Backlog |
| 11 | Parallel Find | 30 min | 3-5 | Klein | Backlog |

## Tier 3 — High Hanging Fruit (~14-16h)

| # | Aenderung | Aufwand | Round-Trips gespart | Empfehlung |
|---|-----------|---------|---------------------|------------|
| 12 | run_plan (deterministisch) | 10h | **~55-60 pro Session** | Nach Tier 1 |
| 13 | Haiku Operator (adaptiv) | 4-6h | weitere ~5-10 | Nach run_plan |

## Empfohlene Implementierungsreihenfolge

**Sprint 1 (Sofort, ~2h):** Items 1 + 2 + 6 + 7
→ Gesten werden zuverlaessig, Screenshots werden leicht, Actions liefern Feedback.
→ Geschaetzte Reduktion: **30-40 Calls und 60% Context** pro Session.

**Sprint 2 (Naechstes Release, ~3h):** Items 3 + 4 + 8 + 9
→ App-Starts werden nahtlos, Navigation wird ein One-Liner, get_source wird nuetzlich.
→ Geschaetzte Reduktion: **weitere 15-25 Calls** pro Session.

**Sprint 3 (Vision, ~10h):** Item 12 (run_plan)
→ Game-Changer. Opus schreibt 5-8 Plaene, MCP-Server fuehrt jeden in <1s aus.
→ Geschaetzte Reduktion: **70 Round-Trips → 8-12**, LLM-Wartezeit **15min → 1min**.
→ Voraussetzung: Tier 1 Items 1+2 (Frame + element_id).

**Sprint 4 (Optional, ~5h):** Item 13 (Haiku Operator)
→ Fuer die 20% Faelle die Urteilsvermoegen brauchen (visuelle Checks, Fehlerreaktion).
→ Voraussetzung: run_plan + ANTHROPIC_API_KEY.

**Backlog:** Items 5 + 10 + 11
→ Nice-to-have, nicht kritisch.

---

## Testbarkeit

Alle Aenderungen sind mit der bestehenden SilbercueTestHarness testbar:
- **Button Tests** Seite: double_tap, long_press mit element_id (Items 1, 2, 6)
- **Drag & Drop** Seite: drag_and_drop, parallel find (Items 2, 11)
- **Scroll & List** Seite: navigate mit scroll (Item 9)
- **Visual Regression** Seite: Screenshot quality, multi_device_check (Items 5, 7)
- **Hauptmenue**: Navigation zwischen Seiten (Item 9), get_source pruned (Item 8)
- **Generell**: State Footer (Item 10), Simulator-Disambiguierung (Item 4)
- E2E-TESTPLAN.md Phase 3-5 als vollstaendiger Regressionstest
