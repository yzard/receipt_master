"""Reject invalid runtime identities before touching mounts or executing the service."""

import os
import subprocess
import unittest
from pathlib import Path


class ServiceEntrypointTest(unittest.TestCase):
    entrypoint = Path(__file__).parents[2] / 'docker/service-entrypoint.sh'

    def assert_rejected(self, env):
        reply = subprocess.run(
            ['sh', str(self.entrypoint), 'sh', '-c', 'echo service-started'], env=env, capture_output=True, text=True
        )
        self.assertEqual(reply.returncode, 2, reply.stderr)
        self.assertIn('PUID and PGID', reply.stderr)
        self.assertNotIn('service-started', reply.stdout)

    def test_both_identity_variables_are_required(self):
        for field in ('PUID', 'PGID'):
            with self.subTest(field=field):
                env = dict(os.environ, PUID='1000', PGID='1003')
                del env[field]
                self.assert_rejected(env)

    def test_root_empty_and_non_numeric_identities_are_rejected(self):
        for field in ('PUID', 'PGID'):
            for value in ('0', '', '-1', 'users'):
                with self.subTest(field=field, value=value):
                    env = dict(os.environ, PUID='1000', PGID='1003')
                    env[field] = value
                    self.assert_rejected(env)


if __name__ == '__main__':
    unittest.main()
