# FTP, FTPS und SSH im Mac-Dateifenster

Unter **Einstellungen / Orte → Ort hinzufügen** lassen sich lokale Ordner,
FTP, explizites FTPS (TLS auf Port 21) und SSH/SFTP (normalerweise Port 22)
einrichten. SCP wird für SSH-Orte durch SFTP ersetzt, weil dessen Protokoll
auch Verzeichnisnavigation bietet. Kein Terminal oder externer Dateimanager
wird geöffnet. Der macOS-AppKit-Dienst verwendet die vorhandenen macOS-Werkzeuge
`curl` und OpenSSH `sftp`, ohne Shell und ohne zusätzliche Benutzerinstallation.

Verbindungen haben einen eigenen Anzeigenamen, Server, Port, Benutzer,
absoluten Startpfad und optional einen SSH-Schlüsselpfad. Ein Klick auf den
Eintrag in den Einstellungen erlaubt Bearbeiten und Entfernen; der Schalter
steuert seine Sichtbarkeit. Entfernen löscht keine Serverdateien.

## Gemeinsame Oberfläche

Die bisherige OneDrive-Ansicht arbeitet jetzt gegen eine gemeinsame
`CommanderOnlineClient`-Schnittstelle. Ordnerbaum, Dateiliste, Filter/Sortierung,
Zurück/Vorwärts/Aufwärts, Auswahl, Vorschau, Öffnen, Informationen,
Kopieren/Einfügen, Upload/Download, ZIP, Drag-and-drop und die beiden
Dateifenster verwenden dieselbe Oberfläche. Netzwerkaktionen zeigen einen
Ladeindikator; Transfers zusätzlich einen abbrechbaren Objekt-Fortschritt.
Server-Downloads zeigen gelesene Bytes und Prozent, Uploads den Fortschritt der
anschließenden Rückleseprüfung (nicht die Upload-Geschwindigkeit).

## Zugang und Sicherheit

- FTP-Passwörter liegen im Schlüsselbund, nicht in Einstellungen/URLs oder
  Prozessargumenten. Die Übergabe an curl erfolgt über die Standardeingabe.
- FTP ist unverschlüsselt; die Einrichtung warnt ausdrücklich davor.
- FTPS verlangt TLS und gültige Zertifikate; keine unsichere Ausweichverbindung.
- SSH unterstützt Schlüssel/ssh-agent sowie **SSH – SFTP (Passwort)**.
  Passwörter liegen im Schlüsselbund. Ein mitgelieferter, signierter Askpass-Helfer
  empfängt sie einmalig über einen privaten lokalen Socket, nicht über Dateien,
  Umgebungsvariablen oder Prozessargumente. Der Helfer bestätigt keine Hostkeys.
  Über **SSH-Serverschlüssel prüfen** können Fingerabdrücke angezeigt werden.
  Erst nach unabhängigem Vergleich bestätigt der Benutzer das Vertrauen.
  Gespeicherte Schlüssel werden strikt geprüft, geänderte Schlüssel abgewiesen.
- SSH-Konfigurationshooks und Agent-Weiterleitung werden nicht verwendet.
- FTP benötigt MLSD. Server ohne MLSD und nicht interpretierbare Listings werden
  nicht durch unsichere Annahmen als leere Ordner dargestellt.
- Als solche gemeldete Symlinks werden nicht angezeigt/verfolgt. FTP-Server
  können in MLSD jedoch bereits dereferenzierte Dateien melden; das Protokoll
  garantiert keine zuverlässige Linkerkennung. Serverrechte bleiben entscheidend.
  In Zielordnern mit gemeldeten Links oder
  unbekannten Dateitypen werden neue Upload-/Umbenennungsziele vorsichtshalber
  abgelehnt. Startpfadbegrenzung ist eine lexikalische Bediengrenze, kein
  serverseitiges Chroot; Serveradministratoren müssen Rechte selbst beschränken.
  Beim Ordner-Download führen gemeldete Links/unbekannte Dateitypen ausdrücklich
  zum Abbruch, statt einen unvollständigen Ordner als erfolgreich zu melden.
- Neue Dateien werden unter einem zufälligen temporären Namen hochgeladen,
  zurückgelesen und per SHA-256 geprüft, dann zum endgültigen Namen umbenannt.
  Nach Fehler/Abbruch können `.opencommander-*`-Teildateien zurückbleiben;
  Quelldaten werden nicht entfernt. Teilweise angelegte Ordner bleiben ebenfalls.
- Vorhandene Namen werden nicht bewusst überschrieben: der gemeinsame Dialog
  bietet Beide behalten / Überspringen / Abbrechen. FTP/SFTP besitzen dabei
  keine universelle atomare „rename if absent“-Garantie. Bei gleichzeitigen
  Änderungen anderer Clients kann keine vollständige Transaktionsgarantie
  versprochen werden. Nicht als produktionsreife Synchronisation behandeln.
- Verschieben innerhalb derselben gespeicherten Verbindung erfolgt per
  Server-Rename, einschließlich Schutz vor Ordnerzyklen. Unterschiedliche
  gespeicherte Verbindungen werden auch bei gleichem Host als getrennt behandelt.
- Serverübergreifendes Verschieben und Remote → lokal vergleichen die vollständige
  Zielkopie per SHA-256. FTP-/SFTP-Quellen werden danach nochmals geprüft und auf
  dem Quellserver in `.OpenCommander-Recovery-<UUID>` umbenannt, auch ganze Ordner.
  Der ursprüngliche Pfad wird frei; eine Wiederherstellungskopie bleibt erhalten.
  Deren Adresse steht in Historie und Abschlussmeldung. Sie kann nach Prüfung
  manuell zurückbenannt werden. Bei geänderten Quellen wird der Move abgebrochen;
  nach Fehlern beim abschließenden Prüfen wird nach Möglichkeit zurückbenannt.
  Keine automatische endgültige Löschung: FTP/SFTP bieten keine universelle
  bedingte Löschgarantie. Abbruch kann Kopien und Wiederherstellungsdateien hinterlassen.
  OneDrive-Dateien verwenden weiterhin bedingtes Löschen in den Papierkorb;
  serverübergreifend kopierte OneDrive-Ordner bleiben aus Sicherheitsgründen erhalten.
- **Endgültig löschen** ist ausdrücklich beschriftet; kein Server-Papierkorb.
  Nichtleere Ordner werden nicht rekursiv gelöscht. Metadaten werden vor Aktionen
  erneut geprüft, ersetzen aber keine atomare serverseitige Versionssperre.
- Die Commander-Werkzeuge Suche/Vergleich/Mehrfach-Umbenennen unterstützen
  direkte Serverorte und OneDrive Online. Vergleiche funktionieren auch gemischt
  zwischen lokalen und Online-Ordnern. Inhaltsvergleiche laden Dateien herunter.
  Suchpfade bleiben innerhalb des konfigurierten Startordners; unsichere Listings
  führen zum Abbruch. Online-Mehrfach-Umbenennen arbeitet nach Vorschau, prüft
  Versionen und Zielnamen erneut und protokolliert jeden abgeschlossenen Schritt.
  Fehler/Abbruch rollen Online-Umbenennungen nicht automatisch zurück; Rückgängig
  ist schrittweise über den Hauptknopf möglich, solange der Browser geöffnet bleibt.
  Native Linux-/Android-Unterstützung
  ist nicht Teil dieser Mac-Implementierung.

## Verifikation

`tests/run-remote-tests.sh` prüft Profile, Pfad-/Options-Injektion und Listings.
Mit einem Python aus einer Testumgebung mit `pyftpdlib`, `paramiko`, `cryptography`
und `pyopenssl` als erstem
Argument startet es ausschließlich Loopback-Testserver in einem temporären
Testordner: FTP, explizites FTPS und SFTP (Schlüssel und Passwort), Unicode/Leerzeichen, rekursive Transfers, SHA-geprüfter
Upload/Download, Namenskonflikte, Umbenennen, Verschieben zwischen zwei Clients,
Zyklen, Schutz nichtleerer Ordner, serverübergreifende Kopien mit Wiederherstellung,
Ablehnung geänderter Quellen, falscher SSH-Hostkeys, falscher Passwörter,
unbekannter TLS-Zertifikate, falscher Zertifikat-Hostnamen und TLS-Downgrades.
Kein Zugriff auf persönliche Server oder Dateien.

Die Testzertifizierungsstelle wird nur für die jeweilige Testverbindung angegeben;
der System-Zertifikatsspeicher bleibt unverändert. Eigene CA-Zertifikate können
bei FTPS optional als PEM-Pfad eingestellt werden. Bytegenauer Upload-Sendefortschritt
und vollständige Remote-Parität bleiben offen. Persönliche Serverzugänge werden
nicht automatisch getestet.

Verifiziert am 08.10.2026: alle vier Loopback-Varianten (FTP, FTPS,
SFTP-Schlüssel und SFTP-Passwort), einschließlich Abbruch vor Start und während
eines SFTP-Downloads, Quelländerungen und Wiederherstellung nach Prüffehlern.
Die 15 OneDrive-, 10 Datei-Sicherheits- und 3 Commander-Werkzeug-Testgruppen
bestanden ebenfalls. Mac-Catalyst-Debug-Build für Apple Silicon und Signaturprüfung
erfolgreich. Die neuen SSH-Passwort-/FTPS-Einstellungsdialoge wurden in der
laufenden App geprüft, ohne persönliche Verbindungen oder Dateien zu ändern.
Die erweiterten Loopback-Tests prüfen außerdem rekursive Suche, editierbaren
Suchpfad, Groß-/Kleinschreibung, Inhaltsvergleich, Umbenennungsvorschau,
veraltete Vorschauen und Byte-Fortschritt. OneDrive-Werkzeuge wurden mit
simulierten Graph-Antworten geprüft. UI-Live-Test auf einem anonymen lokalen
FTP-Testserver: Suchtreffer mit Pfad, Navigation zum Treffer, gemischter
lokal/FTP-Inhaltsvergleich und Mehrfach-Umbenennungsvorschau erfolgreich.
Der temporäre UI-Testort wurde danach entfernt; keine persönlichen Daten geändert.
