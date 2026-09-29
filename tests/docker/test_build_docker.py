"""Exercise build/publish ordering and failures without accessing any registry."""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class BuildDockerTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.log = self.root / 'commands.jsonl'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        shutil.copyfile(Path(__file__).parents[2] / 'build_docker.sh', self.root / 'build_docker.sh')
        stub = '#!' + shutil.which('python3') + '''
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['BUILD_TEST_LOG'], 'a') as log:
    log.write(json.dumps([name, *args]) + '\\n')
commands = [json.loads(line) for line in Path(os.environ['BUILD_TEST_LOG']).read_text().splitlines()]
failure = os.environ.get('BUILD_TEST_FAILURE', '')
if (failure == 'android' and name == 'build_android.sh'
    or failure == 'checks' and name == 'docker' and '--target' in args and 'checks' in args
    or failure == 'api_build' and name == 'docker' and '--load' in args and any(a.startswith('receipt-master-backend-api:') for a in args)
    or failure == 'smoke' and name == 'fake-python' and any(a.endswith('http_smoke.py') for a in args)
    or failure == 'push' and name == 'docker' and args[:2] == ['image', 'push']
    or failure == 'latest_push' and name == 'docker' and args[:2] == ['image', 'push'] and args[-1].endswith(':latest')):
    sys.exit(37)
if name == 'docker' and args[:2] == ['image', 'inspect']:
    print('sha256:' + ('a' if args[-1].startswith('receipt-master-backend-api:') else 'b') * 64)
elif name == 'docker' and args[:1] == ['compose']:
    print('{}')
elif name == 'date':
    # A second clock read crosses midnight, exposing inconsistent image dates.
    print('20260929' if sum(c[0] == 'date' for c in commands) == 1 else '20260930')
'''
        for name in ['docker', 'fake-python', 'date']:
            script = self.bin / name
            script.write_text(stub)
            script.chmod(0o755)
        # Use the real interpreter for stubs; intercept only the pipeline's Python calls.
        python = self.bin / 'python3'
        python.write_text('#!/bin/sh\nexec "' + str(self.bin / 'fake-python') + '" "$@"\n')
        python.chmod(0o755)
        for name in ['build_web.sh', 'build_android.sh']:
            script = self.root / name
            script.write_text(stub)
            script.chmod(0o755)

    def run_build(self, *args, failure=''):
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'])
        env.update(
            BUILD_TEST_LOG=str(self.log),
            BUILD_TEST_FAILURE=failure,
            RECEIPT_BACKEND_ENDPOINT='https://receipts.example.test/',
        )
        result = subprocess.run(
            ['bash', str(self.root / 'build_docker.sh'), *args], env=env, cwd=self.root, capture_output=True, text=True
        )
        commands = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return result, commands

    def test_local_build_tests_image_without_publishing(self):
        result, commands = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(c[0] == 'build_android.sh' for c in commands))
        smoke = next(c for c in commands if any(a.endswith('http_smoke.py') for a in c))
        self.assertEqual(smoke[smoke.index('--image') + 1], 'sha256:' + 'a' * 64)
        self.assertFalse(any(c[:3] == ['docker', 'image', 'push'] for c in commands))
        builds = [c for c in commands if c[:3] == ['docker', 'buildx', 'build'] and '--load' in c]
        self.assertEqual(
            [c[c.index('--tag') + 1] for c in builds],
            ['receipt-master-backend-ocr:20260929', 'receipt-master-backend-api:20260929'],
        )
        aliases = [c for c in commands if c[:3] == ['docker', 'image', 'tag']]
        self.assertEqual(
            [c[-2:] for c in aliases],
            [
                ['sha256:' + 'b' * 64, 'receipt-master-backend-ocr:latest'],
                ['sha256:' + 'a' * 64, 'receipt-master-backend-api:latest'],
            ],
        )
        self.assertTrue(all(commands.index(c) > commands.index(smoke) for c in aliases))
        self.assertEqual([c for c in commands if c[0] == 'date'], [['date', '+%Y%m%d']])

    def test_each_registry_pushes_both_tested_images_after_smoke(self):
        for registry, host in [('dockerhub', 'docker.io'), ('github', 'ghcr.io')]:
            with self.subTest(registry=registry):
                self.log.unlink(missing_ok=True)
                result, commands = self.run_build('--publish', registry, '--username', 'Example-User')
                self.assertEqual(result.returncode, 0, result.stderr)
                expected = [
                    f'{host}/example-user/receipt-master-backend-{c}:{tag}'
                    for tag in ['20260929', 'latest']
                    for c in ['ocr', 'api']
                ]
                pushes = [c for c in commands if c[:3] == ['docker', 'image', 'push']]
                self.assertEqual([c[-1] for c in pushes], expected)
                tags = [c for c in commands if c[:3] == ['docker', 'image', 'tag'] and c[-1].startswith(host + '/')]
                self.assertEqual(
                    [c[-2:] for c in tags],
                    [
                        ['sha256:' + ('b' if c == 'ocr' else 'a') * 64, ref]
                        for c, ref in zip(['ocr', 'api', 'ocr', 'api'], expected)
                    ],
                )
                smoke_index = next(i for i, c in enumerate(commands) if any(a.endswith('http_smoke.py') for a in c))
                self.assertTrue(all(commands.index(c) > smoke_index for c in pushes + tags))
                self.assertFalse(any(c[:2] == ['docker', 'login'] for c in commands))
                self.assertEqual(sum(c[0] == 'date' for c in commands), 1)

    def test_invalid_options_fail_before_any_work(self):
        for args in [
            ['--publish'],
            ['--publish', 'github'],
            ['--publish', 'unknown', '--username', 'tester'],
            ['--username', 'tester'],
            ['--tag', 'v1'],
            ['--publish', 'github', '--username', 'a/b'],
            ['--publish', 'github', '--username', 'tester', '--tag', '-bad'],
            ['--publish', 'github', '--username', 'tester', '--tag', 'x' * 129],
            ['--publish', 'github', '--username', 'tester', '--tag', 'v1;bad'],
            ['--publish', 'github', '--username', 'tester', '--username', 'another'],
            ['--push'],
        ]:
            with self.subTest(args=args):
                result, commands = self.run_build(*args)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(commands, [])

    def test_build_or_smoke_failure_never_publishes(self):
        for failure in ['checks', 'android', 'api_build', 'smoke']:
            with self.subTest(failure=failure):
                self.log.unlink(missing_ok=True)
                result, commands = self.run_build('--publish', 'github', '--username', 'tester', failure=failure)
                self.assertEqual(result.returncode, 37, result.stderr)
                self.assertFalse(
                    any(c[:3] in [['docker', 'image', 'push'], ['docker', 'image', 'tag']] for c in commands)
                )

    def test_push_error_is_reported_and_stops_further_pushes(self):
        result, commands = self.run_build('--publish', 'dockerhub', '--username', 'tester', failure='push')
        self.assertEqual(result.returncode, 37, result.stderr)
        self.assertEqual(len([c for c in commands if c[:3] == ['docker', 'image', 'push']]), 1)
        self.assertNotIn('Published both backend images', result.stdout)

    def test_latest_push_failure_does_not_claim_complete_publication(self):
        result, commands = self.run_build('--publish', 'github', '--username', 'tester', failure='latest_push')
        self.assertEqual(result.returncode, 37, result.stderr)
        pushes = [c[-1] for c in commands if c[:3] == ['docker', 'image', 'push']]
        self.assertEqual(
            pushes,
            [
                'ghcr.io/tester/receipt-master-backend-ocr:20260929',
                'ghcr.io/tester/receipt-master-backend-api:20260929',
                'ghcr.io/tester/receipt-master-backend-ocr:latest',
            ],
        )
        self.assertNotIn('Published both backend images', result.stdout)

    def test_help_performs_no_build(self):
        result, commands = self.run_build('--help')
        self.assertEqual(result.returncode, 0)
        self.assertIn('--publish dockerhub|github', result.stdout)
        self.assertEqual(commands, [])


if __name__ == '__main__':
    unittest.main()
