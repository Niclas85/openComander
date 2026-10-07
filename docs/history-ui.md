# Historienansicht

Die gemeinsame Swift-Oberfläche stellt jede Aktion als eigene Karte dar:

- Aktion oben links, Datum und lokale Uhrzeit einschließlich Sekunden separat.
- Quelle und Ziel in maximal zwei Zeilen, lange Pfade gekürzt.
- Info-Schaltfläche für vollständige Pfade, Sicherungen und Fehlermeldungen.
- Eigene, gleich breite Rückgängig-Schaltfläche statt einer komplett klickbaren
  mehrzeiligen Textfläche. Fehler der Rücknahme bleiben beim Eintrag sichtbar.
- Auf schmalen Fenstern stehen die Schaltflächen unter dem Text.
- Die Liste scrollt unabhängig von den Dateibereichen.

OneDrive-Online-Auditeinträge enthalten keine sicheren persistenten Rücknahmedaten.
Ihr Rückgängig-Button bleibt sichtbar, ist aber deaktiviert und wird durch einen
Hinweis erklärt. Die vorhandene sitzungsbezogene Online-Rücknahme wird dadurch
nicht verändert. Es wird keine funktionierende Rücknahme vorgetäuscht.

Die gespeicherten Historienformate und der bestehende Schutz vor nachträglich
veränderten Dateien bleiben unverändert.

Fehler werden zusätzlich als optionales Domain-/Code-Paar gespeichert und erst
bei der Anzeige in die aktuelle App-Sprache übersetzt. Native englische
Systemmeldungen werden nicht mehr direkt in der Historie angezeigt. Alte
Datensätze mit ausschließlich gespeichertem Meldungstext bleiben lesbar und
erhalten einen lokalisierten Hinweis ohne erfundene Fehlerursache. Ein erneuter
Versuch kann einen neuen, konkreten Fehlercode liefern. Rücknahme-Fehlermeldungen
im Statusbereich nutzen dieselbe Übersetzung.

Prüfung am 07.10.2026: Mac-Catalyst-Build erfolgreich; neun bestehende
Sicherheits-/Historientestgruppen bestanden. Die Karten, separate Uhrzeit mit
Sekunden, Detail-Buttons und deaktivierte Cloud-Rücknahme wurden im laufenden
Testbuild per Oberfläche und Screenshot bestätigt. Ein zusätzlicher sichtbarer
Undo-Klicktest wurde wegen wiederholter externer Fensterzustandsänderungen
nicht abgeschlossen; die Rücknahmeprüfung ist hier automatisiert belegt.
