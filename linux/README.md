# OpenCommander für Linux

Native Qt-Desktop-Version nach dem Vorbild der Mac-Catalyst-App. Keine Browser-
oder Electron-Hülle. Deutsch und Englisch; helles und dunkles Erscheinungsbild.

Aktueller Stand: **0.2.4**. Die Änderungen und der geprüfte Umfang stehen im
[Änderungsprotokoll](CHANGELOG.md).

## Starten

Das fertige Archiv `OpenCommander-linux-x86_64.tar.gz` entpacken und die Datei
`opencommander/opencommander` ausführen. Python oder Qt müssen für dieses Paket
nicht separat installiert werden. Das Verzeichnis `_internal` muss neben der
Programmdatei bleiben.

```bash
tar -xzf OpenCommander-linux-x86_64.tar.gz
./opencommander/opencommander
```

Optional `./opencommander/install-local.sh` ausführen, um einen Starter im
persönlichen Anwendungsmenü anzulegen. Danach das entpackte Verzeichnis an seinem
Ort belassen. Es wird nichts systemweit installiert und kein Root-Zugriff benötigt.
Der Starter kann durch Entfernen von
`~/.local/share/applications/opencommander.desktop` wieder entfernt werden.

Der hier erzeugte x86_64-Build wird auf Ubuntu 24.04 gebaut und benötigt glibc 2.39
oder neuer sowie eine Wayland- oder X11-Desktop-Sitzung. Für andere Architekturen
oder ältere Distributionen auf dem Zielsystem aus dem Quellcode bauen. Es ist
kein universell auf allen Linux-Distributionen getestetes Paket.

## Aus dem Quellcode

Python 3.12 oder neuer mit `venv` sowie ein grafischer Linux-Desktop sind erforderlich.
Im Repository:

```bash
./linux/run.sh
```

Beim ersten Start richtet das Skript eine lokale virtuelle Python-Umgebung ein
und installiert `PySide6-Essentials` und `PySide6-Addons` aus `requirements.txt`. Danach funktioniert der
Start ohne Internetzugriff. Auf einem frischen Ubuntu-System kann das Paket
`python3-venv` zusätzlich benötigt werden. Für den Quellcodestart unter X11 benötigt Qt die üblichen XCB-
Laufzeitbibliotheken, insbesondere `libxcb-cursor0`; das portable Paket enthält
diese Cursor-Bibliothek bereits. Wayland benutzt das Qt-Wayland-Plugin.

Optional können Startverzeichnisse und ein separates Einstellungsprofil angegeben werden:

```bash
./linux/run.sh --left "$HOME" --right "$HOME/Downloads"
./linux/run.sh --state-dir /tmp/opencommander-testprofil
```

## Standard-Dateimanager

Beim ersten normalen Start fragt OpenCommander einmalig, ob es der Standard-
Dateimanager werden soll. Erst bei **Ja** wird die Benutzerzuordnung für
`inode/directory` mit `xdg-mime` geändert. **Nein** behält die aktuelle Zuordnung.
Bestehende Installationen erhalten diese Nachfrage beim ersten Start nach dem Update.
Der Menü-Starter muss zuvor mit `install-local.sh` registriert worden sein.

Ordnerpfade und lokale `file://`-URLs können an die Anwendung übergeben werden.
Läuft OpenCommander bereits, wird der Ordner an das vorhandene Fenster weitergereicht.
Dies betrifft die Standard-Zuordnung für Ordner, nicht jedes fest eingebaute
Dateimanager-Kommando anderer Anwendungen oder die Verwaltung des Desktops.

## Funktionen

- Zwei unabhängig navigierbare Bereiche mit Ordnerbaum, Pfadeingabe, Verlauf,
  sortierbarer Dateiliste, Namensfilter und Mehrfachauswahl.
- Kopieren, Verschieben, Umbenennen, neue Ordner und wiederherstellbares Entfernen.
- Drag-and-drop zwischen den Bereichen, in Ordner und aus anderen Desktop-Apps.
  Der Umschalter „Kopieren / Verschieben“ bestimmt die Aktion beim Loslassen per Drag-and-drop. F5 kopiert weiterhin direkt; F6 verschiebt direkt. Nach außen
  werden lokale Datei-URLs als Kopiervorgang angeboten.
- Desktop-Zwischenablage mit URI-Listen und GNOME-/KDE-Ausschneidekennzeichnung.
- ZIP erstellen, als Verzeichnis durchsuchen und ausgewählte Inhalte entpacken.
  „Entpacken“ erscheint nur bei ausgewählter ZIP-Datei oder im geöffneten Archiv.
  Archivpfade bleiben beim Entpacken erhalten; vorhandene Namen werden ergänzt.
- Bild- und Video-Thumbnails in der Dateiliste, im Hintergrund geladen und begrenzt
  zwischengespeichert. Video-Thumbnails benötigen das optionale Systemprogramm
  `ffmpeg`; fehlt es, bleibt das Dateisymbol sichtbar. ZIP-Einträge verwenden weiterhin Symbole.
- Bilder, Videos und Audio öffnen per Doppelklick, Enter oder Vorschau im integrierten
  Medienbetrachter. **Links/Rechts** wechselt zwischen Medien in der sichtbaren Sortier-
  und Filterreihenfolge des Ordners (auch innerhalb eines geöffneten ZIPs).
  **Leertaste** startet/pausiert Audio und Video. Wiedergabeknopf und Zeitleiste
  erscheinen nur bei Videos; Bilder zeigen ausschließlich die Navigation.
  **Escape** schließt den Betrachter und beendet die Wiedergabe. Bilder passen sich der
  Fenstergröße an. Nicht unterstützte Formate/Codecs zeigen eine Fehlermeldung.
- **Rechtsklick → Öffnen mit …** öffnet die GTK-Programmauswahl für eine einzelne
  Datei. Dafür werden System-Python, PyGObject und GTK 4 benötigt (siehe unten).
  ZIP-Dateiinhalte werden zunächst als Vorschaukopie entpackt; Änderungen durch
  externe Programme werden nicht in das Archiv zurückgeschrieben.
- Checkboxen für versteckte Dateien und dunkles Design; Kopieren/Verschieben als Umschalter.
- Versteckte Dateien, helles/dunkles Design, Deutsch/Englisch und gespeicherte Pfade.
- Gespeicherte Rückgängig-Historie, auch nach Neustart, mit eigenem
  Rückgängig-Button pro Vorgang.
  Die Historie zeigt Zeit, Quell-/Zielpfade, gesicherte Originale und Fehlerhinweise.
  Sichtbare Medien-Einträge laden eine Vorschau der ersten passenden Datei; fehlt
  die Datei inzwischen, bleibt das Symbol. Die Rücknahme prüft weiterhin Änderungen.
- Zugriff auf bereits eingebundene Laufwerke, `/media`, `/run/media`, `/mnt` und
  lokale Cloud-Synchronisationsordner. Beliebige andere Pfade können eingegeben werden.
- Dateiaktionen laufen im Hintergrund und lassen sich während des Kopierens abbrechen.

Tastatur: **F5** Kopieren, **F6** Verschieben, **F2** Umbenennen,
**Strg-C/X/V** Zwischenablage, **Strg-A** alles auswählen, **Strg-Z** Rückgängig,
**Strg-Umschalt-N** neuer Ordner, **Entf** Entfernen, **Enter/Strg-O** öffnen,
**Leertaste/Strg-Y** Vorschau, **Strg-L** Pfad, **Alt-Auf** übergeordnet,
**Alt-Links/Rechts** Verlauf, **Strg-H** versteckte Dateien, **Strg-R** aktualisieren.

## USB, Netzwerk, Google Drive und OneDrive

**Verbindungen …** zeigt eingehängte Laufwerke und noch nicht eingebundene Volumes.
Doppelklick oder **Öffnen / Einbinden** öffnet einen eingebundenen Ort im aktiven
Bereich. Ein noch nicht eingebundenes Volume wird zuerst eingebunden; anschließend
kann es geöffnet werden. **Trennen / Auswerfen** verwendet die sichere Linux-
Auswerf-Funktion, ohne erzwungenes Unmount. Während eines Dateivorgangs ist dies gesperrt.
Die Liste und die Schnellzugriffe werden alle fünf Sekunden aktualisiert.

Netzlaufwerke mit `smb://server/freigabe`, `sftp://server/pfad` oder
`davs://server/pfad` verbinden. Zugangsdaten werden im Systemdialog eingegeben.
OpenCommander speichert keine Passwörter oder OAuth-Tokens.

**Google Drive / OneDrive – Konto hinzufügen** öffnet GNOME Online-Konten.
Google beziehungsweise Microsoft 365 hinzufügen und den Dateizugriff aktivieren.
Die Bereitstellung hängt von den installierten GNOME/GVFS-Providern ab.
Vorhandene rclone-Mounts, auch außerhalb von `/media`, werden ebenfalls erkannt;
rclone-Konten werden weiterhin mit rclone eingerichtet. Lokale Sync-Ordner bleiben
über die Pfadeingabe erreichbar.

Für diese Desktop-Integrationen benötigt auch das portable Paket die Systemdienste.
Unter Ubuntu 24.04 sind dies `python3`, `python3-gi`, `gir1.2-gtk-4.0`,
`gvfs-backends`, `gvfs-fuse`, `udisks2`, `gnome-online-accounts` und
`gnome-control-center`. Ohne diese Dienste funktionieren lokale Dateiaktionen weiter;
der Verbindungsdialog meldet fehlende Unterstützung. Auf anderen Desktops können
bereits eingebundene Orte genutzt werden; der Konto-Assistent benötigt GNOME.

GVFS stellt Netzwerk- und Cloud-Orte als lokale FUSE-Pfade bereit. Schreibzugriffe
hängen von den Rechten und Dateisystemfunktionen des Providers ab. Unterstützt ein
Provider die für sichere Dateiaktionen benötigten atomaren Umbenennungen nicht,
bricht die Aktion mit einem Fehler ab. Es gibt keinen unsicheren Überschreib-Fallback.
Eine lokale Erfolgsmeldung ist keine Bestätigung einer abgeschlossenen Cloud-
Synchronisation; diese wird vom jeweiligen Provider verwaltet.

## Eigenschaften und Cloud-Prüfung

Rechtsklick → Eigenschaften bezieht sich auf die angeklickte Datei. Metadaten werden
frisch und im Hintergrund gelesen. Für GVFS-NAS-Pfade wird die ursprüngliche
SMB-/Provider-Adresse abgefragt, damit fehlende FUSE-Metadaten nicht als falsche
Größe, Rechte oder Eigentümer ausgegeben werden. Nicht gemeldete Werte bleiben
explizit unbekannt. POSIX-Rechte können bei NAS und Cloud synthetisch sein.

Ordner zeigen nicht mehr die Größe ihres Verzeichniseintrags als Inhaltsgröße.
**Ordnergröße berechnen** liest auf Wunsch rekursiv, ohne symbolischen Links zu folgen.
Nach zehn Sekunden oder 100.000 Einträgen wird ein Teilergebnis gekennzeichnet;
Zugriffsfehler zählen ebenfalls als unvollständig. Einzelne hängende Provider-
Anfragen werden nach 15 Sekunden beendet. ZIP-Eigenschaften beziehen sich auf den
gewählten Archiveintrag, nicht auf die Größe des gesamten Archivs.

Google Drive/OneDrive können über vorhandene GVFS-/rclone-Mounts benutzt werden.
Dropbox-Sync-Ordner werden auch über die lokale `.dropbox/info.json` erkannt.
iCloud-Ordner und vorhandene iCloud-Mounts werden ebenfalls angezeigt; eine eigene
Apple-Anmeldung ist nicht implementiert. Für einen iCloud-Drive-Mount mit rclone
ist mindestens eine Version mit dem `iclouddrive`-Backend nötig (ab 1.69).
Siehe [rclone iCloud Drive](https://rclone.org/iclouddrive/),
[rclone OneDrive](https://rclone.org/onedrive/) und
[Dropbox-Systemanforderungen](https://help.dropbox.com/installs/system-requirements).
Das Vorhandensein eines Ordners bestätigt weder eine aktive Synchronisation noch
Schreibfähigkeit oder eine erfolgreiche Anmeldung beim Cloud-Anbieter.

## Dateisicherheit und Grenzen

Kopien werden in einem privaten temporären Verzeichnis auf dem Ziellaufwerk
vorbereitet und mit Linux `renameat2(RENAME_NOREPLACE)` veröffentlicht. Das
verhindert das Überschreiben zwischenzeitlich neu angelegter Ziele. Bei Ersetzen
bleibt die vorherige Version als Wiederherstellungskopie erhalten. Scheitert nach
einem vollständigen Kopieren das Löschen der Quelle, bleibt das vollständige Ziel
stehen; die Fehlermeldung nennt den Ort.

Rückgängig vergleicht Inhalt, Metadaten und Dateidentität. Nachträgliche Änderungen
oder belegte ursprüngliche Pfade stoppen die betroffene Rücknahme. Bereits erledigte
Teilrücknahmen werden gespeichert und bei einem erneuten Versuch nicht wiederholt.
Symbolische Links werden beim Kopieren als Links erhalten, nicht rekursiv verfolgt.
ZIP-Pfade mit `..`, absoluten Pfaden, doppelten Namen oder symbolischen Links werden
abgelehnt. ZIP-Entpacken ist auf 100.000 Einträge und insgesamt 4 GiB begrenzt;
verschlüsselte ZIP-Dateien werden nicht unterstützt.

**Entfernen verwendet eigene `.OpenCommanderTrash-*`-Wiederherstellungsordner,
nicht den System-Papierkorb.** Zurückgenommene Kopien liegen in
`.OpenCommanderUndo-*`; ersetzte Originale gegebenenfalls in
`.OpenCommanderTransfer-*/previous`. Diese Ordner bleiben auf dem jeweiligen
Laufwerk erhalten und belegen Speicher, bis sie bewusst manuell entfernt werden.
Die Historie und Einstellungen liegen in `$XDG_DATA_HOME/opencommander`, gewöhnlich
`~/.local/share/opencommander`. Entpackte externe Vorschaukopien bleiben dort unter
`previews`, damit externe Anwendungen sie weiter bearbeiten können.

Inhaltsprüfungen lesen Dateien erneut und können bei großen Dateien dauern.
Ein Abbruch betrifft die nächste Kopier-/Archiviteration; eine bereits begonnene
Quellbereinigung wird nicht absichtlich unterbrochen. Wiederherstellung ist kein
Dateisystem-Journal und kein Schutz gegen Stromausfall oder beliebige gleichzeitige
Änderungen durch andere Programme. Ein Backup bleibt notwendig.

Linux verwendet vorhandene Treiber und Zugriffsrechte. NTFS kann geschrieben
werden, wenn das Laufwerk mit einem schreibfähigen Linux-Treiber (beispielsweise
ntfs3 oder ntfs-3g) schreibbar eingebunden ist und die Benutzerrechte es erlauben.
OpenCommander bindet ein schreibgeschütztes NTFS-Laufwerk nicht automatisch
schreibbar um; ein NTFS-Schreibtest gehört nicht zum unten dokumentierten Testumfang. Die experimentelle macOS-
NTFS-Erweiterung wird nicht portiert, installiert oder aktiviert. Quick Look und vollständige Parität
mit allen Mac-Funktionen gehören nicht zu dieser ersten Linuxversion.

## Prüfen und paketieren

```bash
linux/.venv/bin/python -m pip install -r linux/requirements-dev.txt
QT_QPA_PLATFORM=offscreen linux/.venv/bin/python -m pytest linux/tests -q
QT_QPA_PLATFORM=offscreen ./linux/run.sh --smoke-test
./linux/build.sh
```

Das Paketierungsskript setzt Ubuntu/Debian mit `apt-get` und `dpkg-deb` voraus.
Es lädt die kleine XCB-Cursor-Bibliothek herunter und entpackt sie ausschließlich
im Bauverzeichnis, ohne Systempakete zu installieren.

Die Paketierung erzeugt `linux/dist/opencommander/` und ein Archiv plus Prüfsumme
unter `linux/artifacts/`. Mit `OPENCOMMANDER_BUILD_ROOT` und
`OPENCOMMANDER_DIST_ROOT` können Zwischen- und Paketverzeichnisse auf ein anderes
Laufwerk gelegt werden. Das Bundle enthält die Python-Anwendungsquellen,
Abhängigkeitsversionen und Lizenzhinweise; siehe `THIRD-PARTY.md`.
