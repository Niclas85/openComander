# Commander-Werkzeuge (Mac)

Erster Ausbau der Commander-Funktionen, eigenständig implementiert. Kein Code aus
Total Commander wird übernommen. Dessen [Funktionsübersicht](https://www.ghisler.com/featurel.htm)
dient nur als Orientierung, nicht als Zusage vollständiger Funktionsgleichheit.

Die Suche hat oben eine eigene **Suchen**-Schaltfläche, die den Suchdialog
öffnet; alternativ öffnet ihn ⌘F. Eine zusätzliche Suchleiste entfällt.
Der Suchpfad wird bei jedem Öffnen aus der aktiven Dateiseite übernommen und
kann im Dialog geändert werden (vollständiger Pfad oder `~/…`). Änderungen des
Suchpfads verändern die angezeigten Dateiseiten nicht. **Werkzeuge** enthält
weiterhin Vergleich und Mehrfach-Umbenennen, nicht mehr die Suche.
Treffer zeigen den Dateinamen und darunter den vollständigen Pfad. Lange Pfade
werden mehrzeilig umgebrochen, statt abgeschnitten zu werden.

| Aktion | Tastatur | Verhalten |
| --- | --- | --- |
| Dateien suchen (eigener Button) | ⌘F | Rekursive Namenssuche mit editierbarem Suchpfad, Teilnamen oder `*`/`?`, Treffer mit vollständigem Pfad; Klick öffnet den zugehörigen Ordner |
| Ordner vergleichen | ⌥⌘C | Vergleicht die beiden angezeigten Ordner rekursiv, einschließlich Dateiinhalten per SHA-256; gleich, unterschiedlich, nur links/rechts oder nicht lesbar |
| Mehrfach umbenennen | ⇧⌘M | Aktive Auswahl nach Namen sortiert, Vorschau, Muster `[N]`/`[E]`/`[C]`, wörtliches Suchen/Ersetzen, Startzähler und Stellenzahl; Rücknahme über Historie |

`[N]` ist der Name ohne Erweiterung, `[E]` die Erweiterung einschließlich Punkt
(bei Ordnern leer), `[C]` der Zähler. Beispiel: `Foto-[C]-[N][E]`.
Suchen/Ersetzen ist wörtlich und unterscheidet Groß-/Kleinschreibung.

Lokale Laufwerke, Netzwerk-Mounts und eingebundene iCloud-/Google-Drive-/OneDrive-
Ordner werden über dasselbe Dateisystem verarbeitet. Der separate **OneDrive-Online**-
Bereich und ZIP-Inhalte werden von diesen drei Werkzeugen noch nicht unterstützt.
Die Werkzeuge sind derzeit in der Mac-Oberfläche erreichbar, nicht in Linux/Android.

## Sicherheit und Grenzen

- Suche/Vergleich im Hintergrund, Abbrechen, keine Verfolgung symbolischer Links.
- Maximal 100.000 Einträge pro Ordnerbaum. Versteckte Dateien folgen der
  Haupteinstellung. Lesefehler werden als unvollständiges Ergebnis angezeigt.
- Inhaltsvergleich verändert nichts und synchronisiert nicht. Er kann das
  Herunterladen ausgelagerter Cloud-Dateien auslösen. Große Dateien werden
  blockweise gelesen; Änderungen während des Vergleichs werden gemeldet.
- Mehrfach-Umbenennen maximal 10.000 Einträge, keine vorhandenen Ziele ersetzen,
  keine doppelten Zielnamen, keine ungültigen Pfade. Vorschau muss vor Anwenden
  erstellt werden; Quellen und Zielbelegung werden danach erneut geprüft.
- Bereits ausgeführte Umbenennungen werden bei Fehler/Abbruch zurückgenommen.
  Ist eine sichere Rücknahme wegen zwischenzeitlicher externer Änderungen nicht
  mehr möglich, wird der verbleibende Pfad ausdrücklich gemeldet.
- Namenstausch und reine Groß-/Kleinschreibungsänderungen auf
  nicht-case-sensitiven Laufwerken werden vorsichtshalber abgelehnt.
- Kein Text-Diff-Editor, keine automatische Verzeichnissynchronisierung und
  keine Volltextsuche innerhalb von Dateien/Archiven in diesem ersten Ausbau.

## Weitere Total-Commander-artige Ausbaustufen (noch offen)

Online-Anbindung der Werkzeuge, Inhalts-/Größen-/Datumsfilter, Duplikatsuche,
Text-Diff, geprüfte Synchronisationsvorschau, FTP/FTPS-Client mit Warteschlange,
weitere Archivformate, Datei-Aufteilen/Zusammenfügen, Prüfsummenexport,
konfigurierbare Spalten/Benutzerbefehle und Plugin-Schnittstellen.
Bestehende Commander-Funktionen (zwei Seiten, ZIP, Vorschau, Kopieren/Verschieben,
Historie, Laufwerke und Verbindungen) bleiben erhalten.

## Prüfung 2026-10-07

`sh tests/run-commander-tools-tests.sh` prüft Suche/Unicode/Platzhalter/Hidden/
Symlink-/Limit-/Abbruchfälle, Inhaltsvergleich gleich großer unterschiedlicher
Dateien, Umbenennungs-Vorschau, Zähler, Rückgängig, Kollisions- und Namensschutz,
veraltete Vorschau, Überlauf und Rücknahme nach Teilfehler/Abbruch.
Der Mac-Catalyst-Build und die bestehenden Sicherheits-/Historientests bestehen.
Ein sichtbarer UI-Test war zunächst durch den gesperrten Mac blockiert;
die neuen Dialoge sind deshalb noch nicht live bestätigt.

Die anschließend ergänzte Suchleiste wurde im Testbuild live geprüft:
Suchen öffnet den Dialog; der Suchpfad wird sowohl aus der aktiven rechten als
auch aus der aktiven linken Seite korrekt übernommen. Ein geänderter Dialogpfad
lieferte den passenden Treffer im anderen Testordner, ohne die beiden
Dateiansichten umzuschalten. Build und Suchtests einschließlich Pfadwechsel,
absoluter Pfade, Home-Abkürzung und Ablehnung relativer Pfade bestehen.
