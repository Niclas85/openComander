"""Location shortcuts only: changing these preferences never changes files."""
import json
import os


def load_preferences(value):
    try:
        rows = json.loads(value)
    except (TypeError, ValueError):
        return []
    if not isinstance(rows, list):
        return []
    result, seen = [], set()
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get('path'), str) or not os.path.isabs(row['path']):
            continue
        path = os.path.normpath(row['path'])
        if path in seen:
            continue
        seen.add(path)
        name = row.get('name')
        result.append(dict(path=path, name=name.strip() if isinstance(name, str) and name.strip() else path,
                           enabled=row.get('enabled') is not False, custom=row.get('custom') is True))
    return result


def configured_locations(locations, preferences):
    overrides = {row['path']: row for row in preferences}
    result, seen = [], set()
    locations = list(locations) + [(row['name'], row['path']) for row in preferences if row['custom']]
    for name, path in locations:
        path = os.path.normpath(str(path))
        row = overrides.get(path)
        if path in seen or (row and not row['enabled']):
            continue
        seen.add(path)
        result.append((row['name'] if row else name, path))
    return result
