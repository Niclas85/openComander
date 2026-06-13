# OpenCommander

Kostenloser Open-Source-Dateimanager fuer Android: zwei Seiten, lokale Dateien, ZIP, Drag & Drop und Rueckgaengig. Keine Werbung, kein Tracking, kein Konto.

OpenCommander ist ein lokaler Android-Dateimanager im Stil eines zweigeteilten Commanders. Die App ist fuer Nutzer gedacht, die Dateien schnell zwischen zwei Seiten organisieren wollen und dabei eine transparente, kostenlose und quelloffene App bevorzugen.

## Funktionen

- Zwei Commander-Seiten wie beim Total Commander
- Querformat: Baum 1, Dateien 1, Baum 2, Dateien 2 nebeneinander
- Hochformat: beide Commander-Seiten untereinander
- Jede Seite hat einen eigenen aufklappbaren Ordnerbaum und eine eigene Dateiliste
- Mehrfachauswahl per Antippen
- Doppeltipp zum Öffnen von Dateien oder Ordnern
- Langes Drücken auf eine ausgewählte Datei startet Drag-and-drop
- Drop auf die andere Dateiliste kopiert oder verschiebt in deren aktuellen Ordner
- Drop auf einen Ordnerbaum kopiert oder verschiebt direkt in diesen Ordner
- Oben schaltet ein Toggle zwischen `Kopieren` und `Verschieben`
- Fortschrittsanzeige beim Kopieren und Verschieben
- Bei groesseren Kopier-/Verschiebeaktionen zeigt der Fortschritt Prozent, kopierte Bytes und Gesamtgroesse
- ZIP-Dateien koennen wie Ordner geoeffnet und durchsucht werden
- Markierte Dateien und Ordner koennen als ZIP-Archiv verpackt werden
- `Rueckgaengig` macht die neueste Kopier- oder Verschiebeaktion zurueck
- `Historie +` klappt mehrere Rueckgaengig-Aktionen auf, damit auch aeltere Aktionen zurueckgenommen werden koennen
- `Dunkel` schaltet zwischen hellem und dunklem Design und wird gespeichert
- Ueberarbeitete helle und dunkle Oberflaeche mit klareren Panels, Buttons und Dateizeilen
- Kleiner `AGB`-Button zeigt AGB-/Impressum-Informationen
- Cloud-Anbieter sind vorerst wieder entfernt, bis die Bedienung dafuer klarer ist
- Mehrsprachige Oberflaeche: Deutsch, Englisch, Franzoesisch, Spanisch, Italienisch, Portugiesisch und Niederlaendisch

## Warum OpenCommander?

- Kostenlos und Open Source
- Keine Werbung
- Kein Tracking
- Kein Benutzerkonto
- Lokale Dateiverwaltung statt Cloud-Zwang
- Zwei-Seiten-Workflow fuer schnelleres Kopieren und Verschieben

## Repository

Quellcode: https://github.com/Niclas85/openComander

## Rechtliches

Vorlagen und Prueflisten liegen unter `legal/`:

- `privacy-policy-de.md`
- `terms-de.md`
- `impressum-template-de.md`
- `play-console-checklist-de.md`

Die Angaben muessen vor einer Veroeffentlichung mit echten Anbieter- und Kontaktdaten finalisiert werden.

## Marketing und Store

Store-Texte, Screenshot-Copy und Launch-Checklisten liegen unter `playstore/`:

- `listing-de.md`
- `listing-en.md`
- `screenshot-copy.md`
- `launch-checklist.md`

Der Marketing-Plan liegt in `MARKETING.md`.

## Lizenz

OpenCommander steht unter der MIT-Lizenz. Details siehe `LICENSE`.

## Sicherheit

Security-Hinweise und Release-Pruefpunkte stehen in `SECURITY.md` und `legal/legal-security-review-2026-06-13.md`.

## Build

```powershell
.\gradlew.bat :app:assembleDebug --no-daemon
```

Die Debug-APK liegt danach hier:

```text
app/build/outputs/apk/debug/app-debug.apk
```

Beim ersten Start muss Android den Zugriff auf alle Dateien erlauben, sonst kann die App nur eingeschränkt lesen und schreiben.
