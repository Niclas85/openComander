import json
import unittest
from opencommander.location_preferences import load_preferences, configured_locations


class LocationPreferencesTests(unittest.TestCase):
    def test_invalid_configuration(self):
        for value in ['invalid', '{}', 'null']:
            self.assertEqual(load_preferences(value), [])

    def test_rename_hide_and_custom_shortcut(self):
        preferences = load_preferences(json.dumps([
            dict(path='/home/test', name='Home renamed', enabled=True),
            dict(path='/mnt/drive', name='Drive', enabled=False),
            dict(path='/offline/folder', name='My shortcut', enabled=True, custom=True)]))
        self.assertEqual(configured_locations([('Home', '/home/test'), ('Drive', '/mnt/drive')], preferences),
                         [('Home renamed', '/home/test'), ('My shortcut', '/offline/folder')])

    def test_roundtrip_and_deduplication(self):
        preferences = load_preferences(json.dumps([dict(path='/a', name='A', custom=True),
            dict(path='/a/', name='Duplicate'), dict(path='relative', name='Unsafe')]))
        self.assertEqual(len(preferences), 1)
        self.assertEqual(load_preferences(json.dumps(preferences)), preferences)


if __name__ == '__main__':
    unittest.main()
