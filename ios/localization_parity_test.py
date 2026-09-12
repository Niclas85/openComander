"""Structural Android/iOS localization gate for OpenCommander."""

import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
ANDROID_RES = ROOT / "app/src/main/res"
IOS = ROOT / "ios/OpenCommander"
LANGUAGES = {
    "en": "values",
    "de": "values-de",
    "fr": "values-fr",
    "es": "values-es",
    "it": "values-it",
    "pt": "values-pt",
    "nl": "values-nl",
    "zh-Hans": "values-zh-rCN",
    "ja": "values-ja",
    "ko": "values-ko",
    "ar": "values-ar",
    "hi": "values-hi",
    "ru": "values-ru",
    "tr": "values-tr",
    "pl": "values-pl",
    "id": "values-in",
    "vi": "values-vi",
    "th": "values-th",
    "uk": "values-uk",
    "sv": "values-sv",
}
NEW_LANGUAGES = set(LANGUAGES) - {"en", "de", "fr", "es", "it", "pt", "nl"}


def placeholders(value):
    return sorted(re.findall(r"%(?:\d+\$)?(?:@|[ds])|%%", value or ""))


def android_strings(directory):
    root = ET.parse(ANDROID_RES / directory / "strings.xml").getroot()
    return {entry.attrib["name"]: entry.text or "" for entry in root if entry.tag == "string"}


def swift_dictionary(source, code):
    start = source.index(f'        "{code}": [')
    end = source.index("\n        ],", start)
    block = source[start:end]
    return {
        match.group(1): match.group(2)
        for match in re.finditer(
            r'^\s{12}"([^"]+)": "((?:\\.|[^"\\])*)",?$', block, re.MULTILINE
        )
    }


def main():
    android_base = android_strings("values")
    swift_source = (IOS / "Localization.swift").read_text()
    ios_base = swift_dictionary(swift_source, "en")
    assert len(LANGUAGES) == 20

    for code, directory in LANGUAGES.items():
        android = android_strings(directory)
        effective_android = android_base | android
        assert set(effective_android) == set(android_base), (code, "Android key set")
        for key, source in android_base.items():
            assert placeholders(effective_android[key]) == placeholders(source), (
                code, key, "Android placeholders"
            )

        if code in NEW_LANGUAGES:
            assert set(android) == set(android_base), (code, "incomplete Android locale")
            ios = json.loads((IOS / f"Localization-{code}.json").read_text())
            assert set(ios) == set(ios_base), (
                code,
                "iOS key set",
                sorted(set(ios_base) - set(ios)),
                sorted(set(ios) - set(ios_base)),
            )
            for key, source in ios_base.items():
                assert placeholders(ios[key]) == placeholders(source), (
                    code, key, "iOS placeholders"
                )

    controller = (IOS / "ViewController.swift").read_text()
    activity = (ROOT / "app/src/main/java/com/opencommander/MainActivity.java").read_text()
    for code in LANGUAGES:
        assert f'"{code}"' in controller, (code, "missing from iOS picker")
        assert f'"{code}"' in activity, (code, "missing from Android picker")
    assert 'resolvedLanguage(currentLanguage) == "ar"' in swift_source
    assert "configuration.setLayoutDirection(locale)" in activity
    assert 'android:supportsRtl="true"' in (ROOT / "app/src/main/AndroidManifest.xml").read_text()
    print(f"PASS: {len(LANGUAGES)} languages, {len(android_base)} Android keys, {len(ios_base)} iOS keys")


if __name__ == "__main__":
    main()
