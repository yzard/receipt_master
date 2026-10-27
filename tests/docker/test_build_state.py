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

    def test_runtime_boundary_excludes_application_and_rejects_ambiguity(self):
        history = [
            {'created_by': 'CUDA'},
            {'created_by': 'NInfer'},
            {'created_by': 'ENV PATH=/opt/app/bin', 'empty_layer': True},
            {'created_by': 'COPY /checks-passed /app/checks-passed # buildkit'},
            {'created_by': 'COPY source'},
        ]
        selected, start, count = state.runtime_history({'history': history})
        self.assertEqual((selected, start, count), (history[:3], 0, 2))
        with self.assertRaises(ValueError):
            state.runtime_history({'history': history + [history[3]]})

    def test_runtime_dependency_or_model_edits_invalidate_reuse_but_checks_do_not(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'docker').mkdir()
            target = root / 'docker/backend_ocr.Dockerfile'
            source = (Path(__file__).parents[2] / 'docker/backend_ocr.Dockerfile').read_text()
            target.write_text(source)
            key = state.runtime_key(root)
            target.write_text(source.replace('touch /checks-passed', 'touch /checks-passed /another-check'))
            self.assertEqual(state.runtime_key(root), key)
            target.write_text(source.replace('uvicorn==0.35.0', 'uvicorn==0.36.0'))
            self.assertNotEqual(state.runtime_key(root), key)
            target.write_text(source.replace('f0b43ad436b9fa8142c6ed6647c470a6fe409484', 'new-model'))
            self.assertNotEqual(state.runtime_key(root), key)
