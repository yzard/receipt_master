import contextlib
import hashlib
import importlib.util
import io
import json
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('shared_qwen', Path(__file__).parents[2] / 'docker/shared_qwen.py')
model = importlib.util.module_from_spec(spec)
spec.loader.exec_module(model)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def layer(name, data):
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode='w') as archive:
        entry = tarfile.TarInfo(name)
        entry.size = len(data)
        archive.addfile(entry, io.BytesIO(data))
    return out.getvalue()


class SavedImage:
    def __init__(self, assets):
        self.payloads = [
            layer('base', b'base'),
            layer('models/model.ninfer', b'weights'),
            layer('models/LICENSE', b'license'),
            layer('app/temporary', b'compiler'),
        ]
        self.diffs = ['sha256:' + sha(p) for p in self.payloads]
        history = [
            {'created_by': 'ENV PATH=/usr/bin', 'empty_layer': True},
            {'created_by': 'base'},
            *[{'created_by': f'ADD --chmod=644 {url} {dest} # buildkit'} for _, url, dest in assets],
            {'created_by': 'ENV RECEIPT_SERVICE=ocr', 'empty_layer': True},
            {'created_by': 'application'},
        ]
        config = {
            'architecture': 'amd64',
            'os': 'linux',
            'config': {'Env': ['PATH=/app/bin', 'RECEIPT_SERVICE=ocr']},
            'history': history,
            'rootfs': {'type': 'layers', 'diff_ids': self.diffs},
        }
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode='w') as archive:
            files = {f'{i}/layer.tar': data for i, data in enumerate(self.payloads)}
            files = {'blobs/sha256/' + sha(data): data for data in self.payloads}
            files['blobs/sha256/config'] = json.dumps(config).encode()
            files['manifest.json'] = json.dumps(
                [{'Config': 'blobs/sha256/config', 'Layers': ['blobs/sha256/' + sha(data) for data in self.payloads]}]
            ).encode()
            for name, data in files.items():
                entry = tarfile.TarInfo(name)
                entry.size = len(data)
                archive.addfile(entry, io.BytesIO(data))
        self.stdout = io.BytesIO(output.getvalue())

    def wait(self):
        return 0

    def poll(self):
        return 0


class SharedQwenTest(unittest.TestCase):
    def test_runtime_export_preserves_dependencies_and_excludes_application(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'blobs/sha256').mkdir(parents=True)
            assets = [
                ('a' * 64, 'https://example.test/model', '/models/model.ninfer'),
                ('b' * 64, 'https://example.test/license', '/models/LICENSE'),
            ]
            image = SavedImage(assets)
            with patch.object(model.subprocess, 'Popen', return_value=image):
                model.export_local('final-ocr-image', root, [], selector=lambda config: (config['history'][:-2], 0, 3))
            index = json.loads((root / 'index.json').read_text())
            manifest = json.loads((root / 'blobs/sha256' / index['manifests'][0]['digest'].split(':')[1]).read_text())
            config = json.loads((root / 'blobs/sha256' / manifest['config']['digest'].split(':')[1]).read_text())
            self.assertEqual(config['rootfs']['diff_ids'], image.diffs[:3])
            self.assertEqual(config['config']['Env'], ['PATH=/app/bin', 'RECEIPT_SERVICE=ocr'])
            self.assertNotIn(image.diffs[-1].split(':')[1], {p.name for p in (root / 'blobs/sha256').iterdir()})

    def test_reuse_local_model_without_download_and_preserve_exact_layer_prefix(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'docker').mkdir()
            assets = [
                (sha(b'weights'), 'https://example.test/pinned-model', '/models/model.ninfer'),
                (sha(b'license'), 'https://example.test/pinned-license', '/models/LICENSE'),
            ]
            stage = (
                'FROM base@sha256:'
                + '1' * 64
                + ' AS qwen-model\n'
                + '\n'.join(f'ADD --chmod=644 --checksum=sha256:{digest} {url} {dest}' for digest, url, dest in assets)
            )
            (root / 'docker/backend_ocr.Dockerfile').write_text(stage + '\n\nFROM qwen-model\n')
            saved = SavedImage(assets)
            output = io.StringIO()
            with patch.object(model, 'local_source', return_value='local-image'), patch.object(
                model.subprocess, 'Popen', return_value=saved
            ), patch.object(
                model.subprocess, 'run', side_effect=AssertionError('Model redownloaded')
            ), contextlib.redirect_stdout(
                output
            ):
                model.prepare(root, 'isolated-builder', root / 'cache')
            context = output.getvalue().strip()
            layout = root / 'cache/model'
            _, prefix = model.inspect_layout(layout, assets, full=True)
            self.assertEqual(prefix, saved.diffs[1:3])
            index = json.loads((layout / 'index.json').read_text())
            manifest = json.loads((layout / 'blobs/sha256' / index['manifests'][0]['digest'].split(':')[1]).read_text())
            config = json.loads((layout / 'blobs/sha256' / manifest['config']['digest'].split(':')[1]).read_text())
            self.assertEqual(config['config'], {'Labels': {'org.shared-model.sha256': assets[0][0]}})
            self.assertNotIn(saved.diffs[-1].split(':')[1], {p.name for p in (layout / 'blobs/sha256').iterdir()})
            self.assertFalse(list((root / 'cache').glob('model-work.*')))
            output = io.StringIO()
            with patch.object(model, 'local_source', side_effect=AssertionError('Local search repeated')), patch.object(
                model.subprocess, 'run', side_effect=AssertionError('Model redownloaded')
            ), contextlib.redirect_stdout(output):
                model.prepare(root, 'fresh-builder', root / 'cache')
            self.assertEqual(output.getvalue().strip(), context)
            blob = layout / 'blobs/sha256' / saved.diffs[1].split(':')[1]
            blob.write_bytes(b'corrupt')
            with self.assertRaises(ValueError):
                model.inspect_layout(layout, assets)

    def test_linked_layers_are_reusable_after_old_add_images_are_gone(self):
        assets = [
            ('a' * 64, 'https://example.test/model', '/models/model.ninfer'),
            ('b' * 64, 'https://example.test/license', '/models/LICENSE'),
        ]
        config = {
            'history': [
                {'created_by': 'base'},
                *[{'created_by': f'COPY --link {dest} {dest} # buildkit'} for _, _, dest in assets],
            ]
        }
        _, start, count = model.boundary(config, assets)
        self.assertEqual((start, count), (1, 2))

    def test_download_is_only_a_cold_cache_fallback(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'docker').mkdir()
            assets = [
                (sha(b'weights'), 'https://example.test/model', '/models/model.ninfer'),
                (sha(b'license'), 'https://example.test/license', '/models/LICENSE'),
            ]
            (root / 'docker/backend_ocr.Dockerfile').write_text(
                'FROM scratch AS qwen-model\n'
                + '\n'.join(f'ADD --chmod=644 --checksum=sha256:{digest} {url} {dest}' for digest, url, dest in assets)
                + '\n'
            )
            calls = []

            def build(args, **kwargs):
                calls.append(args)
                output = args[args.index('--output') + 1]
                layout = Path(output.split('dest=')[1].split(',')[0])
                with patch.object(model.subprocess, 'Popen', return_value=SavedImage(assets)):
                    model.export_local('downloaded-model-only-stage', layout, assets)

            with patch.object(model, 'local_source', return_value=None), patch.object(
                model.subprocess, 'run', side_effect=build
            ), contextlib.redirect_stdout(io.StringIO()):
                model.prepare(root, 'owned-builder', root / 'cache')
            self.assertEqual(len(calls), 1)
            self.assertIn('qwen-model', calls[0])
            self.assertIn('owned-builder', calls[0])

    def test_docker_history_without_link_flag_still_reuses_local_weights(self):
        assets = [
            ('a' * 64, 'https://example.test/model', '/models/model.ninfer'),
            ('b' * 64, 'https://example.test/license', '/models/LICENSE'),
        ]
        history = '\n'.join(f'COPY {dest} {dest} # buildkit' for _, _, dest in assets)
        with patch.object(model, 'command', side_effect=['local-image\n', history]):
            self.assertEqual(model.local_source(assets), 'local-image')

    def test_whole_model_tree_is_recoverable_from_a_labelled_runtime_image(self):
        assets = [
            ('a' * 64, 'https://example.test/model', '/models/model.ninfer'),
            ('b' * 64, 'https://example.test/license', '/models/LICENSE'),
        ]
        config = {
            'config': {'Labels': {'org.shared-model.sha256': 'a' * 64}},
            'history': [{'created_by': 'base'}, {'created_by': 'COPY / / # buildkit'}, {'created_by': 'application'}],
        }
        _, start, count = model.boundary(config, assets)
        self.assertEqual((start, count), (1, 1))
        with patch.object(
            model,
            'command',
            side_effect=['local-image\n', 'COPY / / # buildkit', json.dumps([{'Config': config['config']}])],
        ):
            self.assertEqual(model.local_source(assets), 'local-image')
