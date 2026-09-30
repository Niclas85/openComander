# Linux-Änderungsprotokoll

## 0.2.4 – 30. September 2026

Erster zusammengeführter Linux-Quellstand im Repository. Dieser Eintrag dokumentiert
auch die zuvor lokal installierten Iterationen; diese waren keine separaten
GitHub-Releases. Android-, iOS- und macOS-Anwendungscode wird dabei nicht geändert.

### Oberfläche und Bedienung

- Native PySide6-/Qt-Anwendung nach dem Vorbild der Mac-Version, mit zwei Bereichen,
  Ordnerbäumen, Dateilisten, Pfadeingabe, Sortierung, Filter und Mehrfachauswahl.
- Deutsche und englische Oberfläche, farbige Akzente, helles/dunkles Design,
  Checkboxen und ein Kopieren-/Verschieben-Umschalter.
- Drag-and-drop führt die gewählte Aktion direkt aus, auch beim Ablegen in einen
  Unterordner. Die Drag-Freigabe der Dateieinträge wurde korrigiert. Externe
  Dateiquellen erhalten eine Kopierbestätigung, damit sie Quellen nicht zusätzlich löschen.
- Der überflüssige „Ausführen“-Button wurde entfernt (lokale Version 0.2.2).
- „Ordner auswählen“ wurde aus der Werkzeugleiste entfernt; Navigation erfolgt
  direkt im Fenster. „Entpacken“ erscheint nur im ZIP-Kontext (0.2.3).
- „Öffnen mit …“ im Rechtsklick-Menü verwendet die native GTK-Programmauswahl;
  Abbruch und Startfehler werden behandelt. ZIP-Dateieninhalte können als externe
  Kopie geöffnet werden, ohne Änderungen automatisch ins ZIP zurückzuschreiben (0.2.4).
- Kontextaktionen beziehen sich auf den angeklickten Eintrag und erhalten eine
  vorhandene Mehrfachauswahl, wenn innerhalb dieser Auswahl geklickt wird.

### Vorschau und Medien

- Integrierter Bild-, Video- und Audiobetrachter mit Links-/Rechts-Navigation in
  der aktuellen sichtbaren Sortier- und Filterreihenfolge, auch innerhalb von ZIPs.
- Begrenzte Bilddekodierung im Hintergrund und Behandlung defekter Dateien;
  abgesicherte Lebensdauer der Vorschaufenster und asynchronen Ergebnisse.
- Bild- und Video-Thumbnails mit begrenztem Cache; Video-Thumbnails benötigen
  optional das Systemprogramm ffmpeg. ZIP-Einträge behalten Dateisymbole.
- Wiedergabeknopf und Zeitleiste nur bei Videos (0.2.3). Audio lässt sich mit
  der Leertaste steuern; Schließen beendet die Wiedergabe.

### Dateiaktionen und Historie

- Kopieren, Verschieben, Umbenennen, neue Ordner, Entfernen, ZIP-Erstellung und
  geschütztes Entpacken; Desktop-Zwischenablage und Hintergrundverarbeitung.
- Atomare Veröffentlichung vorbereiteter Kopien ohne Überschreiben neu belegter
  Ziele; Sicherung ersetzter Originale und Erhalt vollständig kopierter Ziele,
  wenn die anschließende Quellbereinigung scheitert.
- Persistente Historie mit Zeit, Quelle, Ziel, Fehlern, Wiederherstellungspfaden
  und Vorschau der ersten verfügbaren Mediendatei. Eigene Rücknahme pro Vorgang.
- Rücknahme prüft Inhalt, Metadaten und Dateidentität. Teilrücknahmen werden
  gespeichert; geänderte Dateien oder belegte Originalpfade werden nicht blind ersetzt.
- Eigene Wiederherstellungsverzeichnisse statt System-Papierkorb; deren Speicher
  wird nicht automatisch bereinigt. Archivgrenzen und weitere Details: [README](README.md).

### Desktop, Laufwerke und Eigenschaften

- Nachfrage beim ersten Start zur Standardzuordnung für Ordner, mit ausdrücklicher
  Zustimmung vor Änderung; korrigierte Starterregistrierung und GIO-Verifikation.
- Einzelinstanz pro Profil und Weitergabe von Ordnerpfaden an das vorhandene Fenster.
- Verbindungsdialog für USB, bestehende Mounts, SMB, SFTP und WebDAV über GIO/GVFS;
  sicheres Trennen/Auswerfen ist während Dateioperationen gesperrt.
- GNOME-Online-Konten für verfügbare Google-/Microsoft-Provider, Erkennung vorhandener
  rclone-Mounts und lokaler Cloud-Ordner, einschließlich benutzerdefinierter Dropbox-Pfade.
- Keine eigene Apple-Anmeldung: iCloud erfordert einen separat eingerichteten
  Sync-Ordner oder Mount. Provider-Anmeldung und Cloud-Synchronisation bleiben extern.
- Frische asynchrone Eigenschaften; bei NAS/GVFS Abfrage der ursprünglichen
  Provider-Adresse statt irreführender FUSE-Metadaten. Fehlende Angaben bleiben unbekannt.
- Ordner-Inhaltsgröße nur auf ausdrückliche Berechnung, mit begrenzter Laufzeit,
  gekennzeichneten Teilergebnissen und ohne Verfolgen symbolischer Links.
- ZIP-Eigenschaften beziehen sich auf den ausgewählten Archiveintrag.

### Paketierung und Entwicklung

- Start-, Build- und Benutzerinstallationsskripte; PyInstaller-Verzeichnisbundle
  für Ubuntu 24.04/x86_64, Archiv und SHA-256-Prüfsumme.
- Festgelegte Python-Abhängigkeiten, mitgelieferte Quellen, Lizenztexte und Hinweise
  zu Qt, FFmpeg und der gebündelten XCB-Cursor-Bibliothek.
- Bereinigte Umgebungsvariablen beim Aufruf von Systemprogrammen aus dem Bundle.
- Linux-Tests und Paketierung in GitHub Actions; generierte Pakete, virtuelle
  Umgebungen und lokale Testbilder bleiben außerhalb der Versionsverwaltung.

### Verifikation und verbleibende Grenzen

- Gesamte Linux-Testsuite am 30. September 2026: **75 Tests bestanden**. Abgedeckt
  sind Dateiaktionen/Rücknahme, Desktop-Zuordnung, Integrationen, Eigenschaften,
  Medien, Kontextaktionen und Drag-and-drop. Aufruf siehe [README](README.md).
- Der lokal installierte Build 0.2.4 bestand den Paket-Smoke-Test einschließlich
  Start des Medienbetrachters und Bilddekodierung.
- NAS/SMB und vorhandener Google-Drive-rclone-Mount wurden lesend geprüft.
  Keine echten Schreib-/Löschtests auf NAS, Cloud oder NTFS durchgeführt.
- OneDrive, Dropbox und iCloud waren nicht als authentifizierte Testkonten
  verfügbar; ihre tatsächliche Anmeldung und Synchronisation sind nicht end-to-end geprüft.
- „Öffnen mit …“ ist durch automatisierte Aufruf-/Abbruchtests und GTK-API-Prüfung
  abgedeckt; ein interaktiver Start sämtlicher installierter Programme wurde nicht getestet.
- Tests ohne Bildschirm ersetzen keine vollständige visuelle Prüfung aller
  Desktop-Umgebungen. Andere Distributionen, Architekturen und sämtliche Codecs
  sind nicht umfassend getestet. Cloud-Provider ohne erforderliche sichere
  Dateisystemoperationen können Schreibaktionen ablehnen.
