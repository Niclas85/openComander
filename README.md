# OpenCommander

Kostenloser Open-Source-Dateimanager fuer Android, iPhone, iPad und macOS: zwei Seiten, lokale Dateien, ZIP, Drag & Drop und Rueckgaengig. Keine Werbung, kein Tracking, kein Konto.

OpenCommander ist ein lokaler Dateimanager fuer Android, iOS und macOS im Stil eines zweigeteilten Commanders. Die App ist fuer Nutzer gedacht, die Dateien schnell zwischen zwei Seiten organisieren wollen und dabei eine transparente, kostenlose und quelloffene App bevorzugen.

## Funktionen

- Zwei Commander-Seiten wie beim Total Commander
- Querformat: Baum 1, Dateien 1, Baum 2, Dateien 2 nebeneinander
- Hochformat: beide Commander-Seiten untereinander
- Jede Seite hat einen eigenen aufklappbaren Ordnerbaum und eine eigene Dateiliste
- Mehrfachauswahl per Antippen
- Einzelne Dateien und Ordner koennen direkt umbenannt werden
- Sichtbarer Hinweis mit direktem Einstellungslink, wenn Android den Dateizugriff noch nicht erlaubt hat
- Hilfe-Dialog beim ersten erfolgreichen Start und dauerhaft ueber die Schaltflaeche `Hilfe` erreichbar
- Doppeltipp zum Öffnen von Dateien oder Ordnern
- Langes Drücken auf eine ausgewählte Datei startet Drag-and-drop
- Drop auf die andere Dateiliste kopiert oder verschiebt in deren aktuellen Ordner
- Drop auf einen Ordnerbaum kopiert oder verschiebt direkt in diesen Ordner
- Oben waehlt `Aktion: Kopieren` oder `Aktion: Verschieben` eindeutig die Drag-and-drop-Aktion
- Fortschrittsanzeige beim Kopieren und Verschieben
- Bei groesseren Kopier-/Verschiebeaktionen zeigt der Fortschritt Prozent, kopierte Bytes und Gesamtgroesse
- ZIP-Dateien koennen wie Ordner geoeffnet und durchsucht werden
- Markierte Dateien und Ordner koennen als ZIP-Archiv verpackt werden
- Vorhandene APK-Dateien koennen per Doppeltipp im Android-Paketinstaller geoeffnet werden; Android verlangt weiterhin eine ausdrueckliche Installationsbestaetigung
- Android-TV-Unterstuetzung mit Leanback-Launcher, TV-Banner und Fernbedienungsnavigation
- `Rueckgaengig` macht die neueste Kopier- oder Verschiebeaktion zurueck
- `Historie +` klappt mehrere Rueckgaengig-Aktionen auf, damit auch aeltere Aktionen zurueckgenommen werden koennen
- `Dunkel` schaltet zwischen hellem und dunklem Design und wird gespeichert
- Ueberarbeitete helle und dunkle Oberflaeche mit klareren Panels, Buttons und Dateizeilen
- Kleiner `AGB`-Button zeigt AGB-/Impressum-Informationen
- macOS: Zugriff auf lokal eingebundene Cloud-Ordner (z. B. Google Drive, OneDrive, iCloud Drive); Einrichtung und Synchronisation erfolgen in der jeweiligen Anbieter-App
- Mehrsprachige Oberflaeche mit 20 Sprachen: Deutsch, Englisch, Franzoesisch, Spanisch, Italienisch, Portugiesisch, Niederlaendisch, Chinesisch, Japanisch, Koreanisch, Arabisch, Hindi, Russisch, Tuerkisch, Polnisch, Indonesisch, Vietnamesisch, Thai, Ukrainisch und Schwedisch

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

## Bedienung und Speicherzugriff

Beim ersten erfolgreichen Start erklaert ein Hilfe-Dialog Auswahl, Doppeltipp und Drag-and-drop. Die Hilfe bleibt ueber `Hilfe` erreichbar. `Aktion: Kopieren` beziehungsweise `Aktion: Verschieben` bestimmt, was beim Ziehen markierter Elemente in die andere Seite passiert.

Auf Android 11 und neuer muss fuer den vollen Dateimanagerbetrieb der spezielle Zugriff auf alle Dateien in den Systemeinstellungen aktiviert werden. OpenCommander zeigt dafuer dauerhaft einen Hinweis mit direkter Schaltflaeche an, solange die Freigabe fehlt. Android 10 verwendet stattdessen den System-Ordnerdialog (Storage Access Framework): Der dort ausgewaehlte Ordner und seine Unterordner bleiben nach der Freigabe sichtbar und koennen mit den Commander-Funktionen verwaltet werden. Ueber `Details` kann jederzeit ein anderer Ordner ausgewaehlt werden.

## Build

```powershell
.\gradlew.bat :app:assembleDebug --no-daemon
```

Die Debug-APK liegt danach hier:

```text
app/build/outputs/apk/debug/app-debug.apk
```

Beim ersten Start muss Android den benoetigten Dateizugriff erlauben. Unter Android 10 wird dafuer ein Ordner im Systemdialog ausgewaehlt; unter Android 11 und neuer wird der spezielle Zugriff auf alle Dateien verwendet.

### macOS

Die Swift-App unter `ios/` wird zugleich als native Mac-Catalyst-App gebaut. Sie enthaelt die bestehenden Commander-Funktionen und zusaetzlich Mac-Tastaturbefehle:

- `Command-C`, `Command-X`, `Command-V`: Dateien kopieren, ausschneiden und einfuegen
- `Command-A`: alles in der aktiven Seite auswaehlen
- `Command-Z`: letzte Dateioperation rueckgaengig machen
- `Command-O`: ausgewaehlte Datei oder Ordner oeffnen
- `Command-R`: aktive Seite aktualisieren
- `Command-Shift-N`: neuen Ordner erstellen
- `Command-Shift-.`: versteckte Dateien ein- oder ausblenden
- `Return`: markierte Datei beziehungsweise Ordner oeffnen
- `Leertaste` oder `Command-Y`: Quick-Look-Vorschau
- `Rueckschritt`: markierte Elemente loeschen

```bash
xcodegen generate --spec ios/project.yml --project ios
xcodebuild -project ios/OpenCommander.xcodeproj -scheme OpenCommander \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Die direkte macOS-Version ist als Finder-Ersatz ohne App-Sandbox ausgelegt. Die linke Commander-Seite startet beim Macintosh-Stammordner `/`, die rechte bei `~/Downloads`. `Computer / Laufwerke` bietet Schnellzugriffe auf Root, Benutzerordner, Downloads, Schreibtisch und alle unter `/Volumes` eingebundenen externen Datentraeger.

Beim ersten Mac-Start erklaert OpenCommander den Festplattenvollzugriff und oeffnet auf Wunsch direkt die passende Seite der Systemeinstellungen. Diese Freigabe muss aus Sicherheitsgruenden einmal vom Nutzer erteilt werden; eine App darf sie sich unter macOS nicht selbst geben. OpenCommander prueft den Status nach der Rueckkehr asynchron, zeigt unter `Computer / Laufwerke` dauerhaft `Festplattenvollzugriff aktiv ✓` und aktualisiert beide Dateiseiten automatisch. Bereits ueber den Ordnerdialog erteilte Rechte werden zusaetzlich als Security-Scoped-Bookmarks gespeichert und nach einem Neustart wiederverwendet.

Fuer den Betrieb als primaerer Finder-Ersatz ist die direkt vertriebene, signierte macOS-Version ohne App-Sandbox vorgesehen. Eine Mac-App-Store-Version bleibt an Apples Sandbox und Ordnerauswahl gebunden. Auch die direkte Version kann die einmalige Bestaetigung unter `Datenschutz & Sicherheit > Festplattenvollzugriff` nicht automatisieren und Finder nicht als geschuetzte Systemkomponente deinstallieren; danach kann sie aber als alltaeglicher Dateimanager fuer Root, Benutzerordner und externe Laufwerke verwendet werden.

### NTFS-Komponenten

Der unabhaengige Swift-Kern unter `ntfs/OpenCommanderNTFS/` ist MIT-lizenziert.
Daneben liegt unter `ntfs/NTFS3G/` ein separater experimenteller NTFS-3G-/FSKit-Prototyp
mit GPL-2.0-or-later-Komponenten. Herkunft, Lizenztexte und der aktuelle Teststand
stehen in `ntfs/NTFS3G/THIRD-PARTY.md` und `ntfs/NTFS3G/README.md`.
Schreibbetrieb erfordert explizit `OPENCOMMANDER_NTFS3G_EXPERIMENTAL`; der normale
Build verweigert Mounts weiterhin. Der Prototyp ist nicht produktionsreif.

### Unabhaengiger NTFS-Kern

Unter `ntfs/OpenCommanderNTFS/` entsteht eine eigenstaendige MIT-lizenzierte NTFS-Implementierung. Sie uebernimmt keinen Code aus NTFS-3G, macFUSE, Tuxera oder einem anderen NTFS-Treiber. Bereits implementiert und durch Unit-Tests abgedeckt sind:

- Bootsektor- und Geometriepruefung
- MFT-`FILE`-Datensaetze mit Update-Sequence-Fixups
- residente und nichtresidente Attributkoepfe
- Runlist-Dekodierung einschliesslich negativer LCN-Deltas und Sparse Runs
- begrenzter Blockzugriff sowie sektorausgerichtete Schreibtransaktionen mit Rollback
- verifizierte Read-Modify-Write-Transaktionen und groessengleiche residente Dateiaktualisierungen auf Test-Images
- residente und allocation-basierte `$I30`-Verzeichnisindizes
- automatische Pruefung von NTFS-Version, Volume-Flags, Backup-Bootsektor, `$MFTMirr` und `hiberfil.sys`
- standardmaessig geschlossene Schreibfreigabe fuer ungepruefte, verschmutzte, hibernierte oder nicht unterstuetzte Volumes

`OpenCommanderNTFSModule` bindet den Kern als native FSKit-Dateisystemerweiterung in die Mac-App ein. Sie kann in `Systemeinstellungen > Allgemein > Anmeldeobjekte & Erweiterungen > Dateisystemerweiterungen` aktiviert werden. Der aktuelle Entwicklungsstand erkennt NTFS-Medien, meldet sie aber absichtlich noch nicht als benutzbar: Reale allgemeine NTFS-Schreibzugriffe bleiben gesperrt, bis Verzeichnisindex-Mutationen, `$Bitmap`-Aktualisierungen, `$LogFile`-Wiederherstellung und absturzsichere Metadatenaktualisierungen implementiert und mit Datentraeger-Abbildern validiert sind. Bis dahin verwendet OpenCommander den von macOS bereitgestellten Mountmodus, normalerweise nur lesend.

Tests des portablen Kerns:

```bash
cd ntfs/OpenCommanderNTFS
swift test
```

## Dateisicherheit und Wiederherstellung

Kopier-, Verschiebe- und ZIP-Aktionen speichern fuer Rueckgaengig einen Inhaltspruefwert
sowie Dateimetadaten. Wurden Dateien inzwischen bearbeitet, ersetzt oder um weitere
Unterdateien ergaenzt, wird die betreffende Ruecknahme gestoppt. Bereits belegte
urspruengliche Dateipfade werden nicht ueberschrieben. Nach einem Teilfehler bleiben
noch nicht abgeschlossene Ruecknahmen in der Historie; erfolgreich abgeschlossene
Eintraege werden nicht nochmals ausgefuehrt.

Scheitert auf Android nach einer vollstaendigen Kopie das anschliessende Loeschen
der Quelle, bleibt die Zielkopie erhalten. Der Fehlerhinweis nennt ihren Ort.
Beim Ersetzen auf iOS/macOS wird die Kopie zuerst vollstaendig in einem temporaeren
Ordner auf dem Ziellaufwerk vorbereitet. Erst danach wird die vorhandene Datei
zur Wiederherstellung gesichert und die neue Kopie veroeffentlicht.

Rueckgaengig bewahrt entfernte lokale Kopien in versteckten
`.OpenCommanderUndo-*`-Ordnern neben dem bisherigen Ziel auf. Beim Ersetzen koennen
auch `.OpenCommanderTransfer-*`-Ordner eine vorherige Version enthalten.
Androids Dokumentanbieter-Zugriffe sichern Daten im privaten App-Cache. Diese
Sicherungen verbrauchen Speicherplatz und werden nicht automatisch geloescht;
Android darf Cache-Inhalte jedoch selbst entfernen. Die Historie gilt fuer die
laufende App-Sitzung und ersetzt kein dauerhaftes Backup. Fehlende oder nicht
pruefbare Dateien erlauben keine destruktive Ruecknahme. Inhaltspruefungen lesen
die betroffenen Dateien erneut, was bei grossen Dateien und Cloud-Inhalten dauern kann.

## Automatische Pruefungen

```bash
python3 ios/localization_parity_test.py
tests/run-java-safety.sh
ANDROID_HOME="$HOME/Android/Sdk" ./gradlew :app:assembleDebug :app:lintDebug --no-daemon
```

Auf macOS mit Swift/Xcode:

```bash
tests/run-swift-safety.sh
swift test --package-path ntfs/OpenCommanderNTFS
```

Die GitHub-Actions-Pipeline prueft Android-Build, Lint, Sprachschluessel und
Dateisicherheitsregressionen sowie auf macOS die Swift-Dateioperationen,
den portablen NTFS-Kern und den iOS-Simulator-Build. Geraetetests fuer Androids
Storage Access Framework, Cloud-Anbieter und Mac Catalyst bleiben erforderlich.
