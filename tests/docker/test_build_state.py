"""Test reuse of final outputs and temporary extraction of runtime layers."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('build_state', Path(__file__).parents[2] / 'docker/build_state.py')
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)


class BuildStateTest(unittest.TestCase):
    def test_unchanged_outputs_reuse_and_input_or_output_changes_rebuild(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'src').mkdir()
            (root / 'src/main').write_text('code')
            (root / 'app').write_bytes(b'final')
            key = state.fingerprint(root, ['src'], ['toolchain-v1'])
            self.assertIsNone(state.reusable(root, 'app', key, ['app']))
            state.record(root, 'app', key, ['app'])
            self.assertEqual(state.reusable(root, 'app', key, ['app']), 'reusable')
            (root / 'src/build').mkdir()
            (root / 'src/build/cache').write_text('temporary')
            self.assertEqual(state.fingerprint(root, ['src'], ['toolchain-v1']), key)
            self.assertNotEqual(state.fingerprint(root, ['src'], ['toolchain-v2']), key)
            (root / 'src/main').write_text('new source')
            self.assertNotEqual(state.fingerprint(root, ['src'], ['toolchain-v1']), key)
            (root / 'app').write_bytes(b'corrupt')
            self.assertIsNone(state.reusable(root, 'app', key, ['app']))
            (root / 'app').unlink()
            self.assertIsNone(state.reusable(root, 'app', key, ['app']))
            with self.assertRaises(ValueError):
                state.record(root, 'app', key, ['app'])

    def test_missing_image_is_not_reusable_and_failures_do_not_replace_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with patch.object(state, 'image_exists', return_value=True):
                state.record(root, 'ocr', 'key', [], 'sha256:final')
                self.assertEqual(state.reusable(root, 'ocr', 'key', []), 'sha256:final')
            with patch.object(state, 'image_exists', return_value=False):
                self.assertIsNone(state.reusable(root, 'ocr', 'key', []))
                with self.assertRaises(ValueError):
                    state.record(root, 'ocr', 'new', [], 'sha256:absent')
            self.assertEqual(json.loads((root / 'build/state/ocr.json').read_text())['fingerprint'], 'key')
