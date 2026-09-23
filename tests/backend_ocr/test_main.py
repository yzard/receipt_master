import asyncio
import base64
import copy
import sys
import tempfile
import unittest
from io import BytesIO
from pathlib import Path
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).parents[2] / 'src/backend_ocr'))
from config import ServerConfig, load_config
from fastapi import HTTPException
from main import EngineRuntime, create_application, prepare_request, stop_process
from PIL import Image
from recipe import command_for

OCR_KEY = 'synthetic-ocr-service-key-for-tests'
AUTH = {'Authorization': f'Bearer {OCR_KEY}'}


def config():
    return ServerConfig.model_validate(
        dict(
            general=dict(host='0.0.0.0', port=8000, api_key=OCR_KEY, max_requests=1, timeout_seconds=60, idle_timeout_seconds=300),
            engine=dict(
                path='/models/vision',
                model='vision',
                port=8002,
                context_length=32768,
                max_images=16,
                receipt_output_tokens=8192,
                logo_output_tokens=4096,
                thinking=True,
                temperature=0,
                seed=42,
                image_pixel_budget=12582912,
                draft_tokens=3,
                max_sequences=1,
            ),
        )
    )


def photo():
    data = BytesIO()
    im = Image.new('RGB', (30, 60))
    exif = im.getexif()
    exif[274] = 6
    im.save(data, format='JPEG', exif=exif)
    return {
        'type': 'image_url',
        'image_url': {'url': 'data:image/jpeg;base64,' + base64.b64encode(data.getvalue()).decode()},
    }


class VisionTest(unittest.TestCase):
    def test_inference_and_capabilities_require_service_key(self):
        import httpx

        async def run():
            app = create_application(config())
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
                for path, method in [('/capabilities', 'get'), ('/v1/chat/completions', 'post')]:
                    response = await getattr(client, method)(path)
                    self.assertEqual(response.status_code, 401)
                    response = await getattr(client, method)(path, headers={'Authorization': 'Bearer wrong'})
                    self.assertEqual(response.status_code, 401)
                response = await client.get('/capabilities', headers=AUTH)
                self.assertEqual(response.json(), {'max_images': 16})

        asyncio.run(run())

    def test_recipe_requires_weights_and_has_one_multimodal_engine(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = str(Path(tmp, 'model.ninfer'))
            c = config().engine.model_copy(update={'path': path})
            with self.assertRaises(ValueError):
                command_for(c)
            Path(path).write_bytes(b'model')
            command = command_for(c)
            self.assertEqual(command[:2], ['ninfer-serve', path])
            self.assertIn('--vision', command)
            self.assertIn('--spec', command)
            self.assertNotIn('--no-thinking', command)
            self.assertNotIn('--api-key', command)

    def test_all_images_and_schema_forwarded_with_exif_applied(self):
        body = {
            'profile': 'receipt',
            'messages': [
                {'role': 'system', 'content': 'instructions'},
                {'role': 'user', 'content': [{'type': 'text', 'text': 'same receipt'}, photo(), photo()]},
            ],
        }
        prepared = prepare_request(copy.deepcopy(body), config())
        self.assertEqual(prepared['response_format'], {'type': 'text'})
        self.assertEqual(prepared['model'], 'vision')
        self.assertEqual(prepared['max_tokens'], 8192)
        self.assertTrue(prepared['chat_template_kwargs']['enable_thinking'])
        self.assertEqual(prepared['messages'][0], body['messages'][0])
        parts = prepared['messages'][1]['content']
        self.assertEqual(len(parts), 3)
        for p in parts[1:]:
            im = Image.open(BytesIO(base64.b64decode(p['image_url']['url'].split(',')[1])))
            self.assertEqual(im.size, (60, 30))
            self.assertNotIn(274, im.getexif())

    def test_invalid_requests_do_not_fetch_remote_images_or_silently_drop_photos(self):
        for images in [
            [],
            [photo()] * 17,
            [{'type': 'image_url', 'image_url': {'url': 'https://example.com/a'}}],
            [{'type': 'image_url', 'image_url': None}],
        ]:
            with self.assertRaises(HTTPException):
                prepare_request({'profile': 'receipt', 'messages': [{'content': images}]}, config())

    def test_one_request_contains_all_images_and_preserves_thinking_and_prompt(self):
        import json

        import httpx

        async def run(fail):
            calls = []

            async def handler(request):
                calls.append(json.loads(request.content))
                return httpx.Response(
                    503 if fail else 200,
                    json={
                        "choices": [
                            {"finish_reason": "stop", "message": {"content": "{}", "reasoning_content": "thought"}}
                        ]
                    },
                )

            app = create_application(config())
            async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as upstream:
                app.state.runtime = EngineRuntime(config(), upstream)
                app.state.runtime.ensure_ready = AsyncMock()
                async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
                    response = await client.post(
                        "/v1/chat/completions",
                        json={
                            "profile": "receipt",
                            "messages": [
                                {"role": "system", "content": "store rules"},
                                {"role": "user", "content": [photo(), photo()]},
                            ],
                        },
                        headers=AUTH,
                    )
                    self.assertEqual(response.status_code, 502 if fail else 200)
                    self.assertEqual(len(calls), 1)
                    self.assertEqual(len(calls[0]["messages"][1]["content"]), 2)
                    self.assertEqual(calls[0]["messages"][0]["content"], "store rules")
                    self.assertTrue(calls[0]["chat_template_kwargs"]["enable_thinking"])

        asyncio.run(run(False))
        asyncio.run(run(True))

    def test_multiple_images_share_pixel_budget_without_losing_pages(self):
        c = config().model_copy(deep=True)
        c.engine.image_pixel_budget = 65536
        data = BytesIO()
        Image.new('RGB', (1024, 2048), 'white').save(data, format='PNG')
        part = {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,' + base64.b64encode(data.getvalue()).decode()},
        }
        body = prepare_request(
            {'profile': 'receipt', 'messages': [{'content': [copy.deepcopy(part), copy.deepcopy(part)]}]}, c
        )
        images = [
            Image.open(BytesIO(base64.b64decode(p['image_url']['url'].split(',')[1])))
            for p in body['messages'][0]['content']
        ]
        self.assertEqual(len(images), 2)
        self.assertLessEqual(sum(i.width * i.height for i in images), 65536)

    def test_concurrent_receipts_wait_and_failure_releases_queue(self):
        import httpx

        async def run():
            app = create_application(config())
            started = asyncio.Event()
            release = asyncio.Event()
            calls = []

            async def handler(request):
                calls.append(request.url.port)
                if len(calls) == 1:
                    started.set()
                    await release.wait()
                    return httpx.Response(503, json={"detail": "unavailable"})
                return httpx.Response(
                    200, json={"choices": [{"finish_reason": "stop", "message": {"content": "MILK 3.00"}}]}
                )

            async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as upstream:
                app.state.runtime = EngineRuntime(config(), upstream)
                app.state.runtime.ensure_ready = AsyncMock()
                async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
                    body = {"profile": "receipt", "messages": [{"content": [photo()]}]}
                    first = asyncio.create_task(client.post("/v1/chat/completions", json=body, headers=AUTH))
                    await asyncio.wait_for(started.wait(), 2)
                    second = asyncio.create_task(client.post("/v1/chat/completions", json=body, headers=AUTH))
                    # A queued request must not reach either engine before the first completes.
                    await asyncio.sleep(0.05)
                    self.assertFalse(second.done())
                    self.assertEqual(len(calls), 1)
                    release.set()
                    responses = await asyncio.wait_for(asyncio.gather(first, second), 2)
                    self.assertEqual([r.status_code for r in responses], [502, 200])
                    self.assertEqual(calls, [config().engine.port, config().engine.port])

        asyncio.run(run())

    def test_config_rejects_parallel_inference(self):
        from pydantic import ValidationError

        for section, field in [("general", "max_requests"), ("engine", "max_sequences")]:
            data = config().model_dump()
            (data if section is None else data[section])[field] = 2
            with self.assertRaises(ValidationError):
                ServerConfig.model_validate(data)

    def test_supervisor_terminates_process_group(self):
        async def run():
            child = await asyncio.create_subprocess_exec('sh', '-c', 'sleep 300 & wait', start_new_session=True)
            await stop_process(child)
            self.assertIsNotNone(child.returncode)

        asyncio.run(run())


class LifecycleTest(unittest.IsolatedAsyncioTestCase):
    async def test_idle_service_health_does_not_launch_engine(self):
        import httpx

        app = create_application(config())
        with patch('main.command_for') as command:
            async with app.router.lifespan_context(app):
                async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
                    for _ in range(3):
                        response = await client.get('/health')
                        self.assertEqual(response.json()['engine_state'], 'unloaded')
                    response = await client.post('/v1/chat/completions', json={'profile': 'invalid'}, headers=AUTH)
                    self.assertEqual(response.status_code, 400)
                command.assert_not_called()

    async def test_cold_start_queue_idle_release_and_reload(self):
        import httpx

        c = config().model_copy(update={'general': config().general.model_copy(update={'idle_timeout_seconds': 0.08})})
        started = asyncio.Event()
        release = asyncio.Event()
        calls = []
        health_calls = 0

        async def handler(request):
            nonlocal health_calls
            if request.url.path == '/health':
                health_calls += 1
                return httpx.Response(503 if health_calls == 1 else 200)
            calls.append(request.url.path)
            if len(calls) == 1:
                started.set()
                await release.wait()
            return httpx.Response(200, json={'ok': True})

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            runtime = EngineRuntime(c, client)
            monitor = asyncio.create_task(runtime.idle_watch())

            async def job():
                async with runtime.slot():
                    return await runtime.infer({})

            with patch('main.command_for', return_value=['sh', '-c', 'sleep 300 & wait']) as command:
                try:
                    first = asyncio.create_task(job())
                    await asyncio.wait_for(started.wait(), 2)
                    process = runtime.process
                    second = asyncio.create_task(job())
                    await asyncio.sleep(0.2)
                    self.assertIsNone(process.returncode)
                    self.assertEqual(len(calls), 1)
                    self.assertEqual(command.call_count, 1)
                    self.assertGreaterEqual(health_calls, 2)
                    release.set()
                    await asyncio.gather(first, second)
                    await asyncio.sleep(0.2)
                    self.assertIsNotNone(process.returncode)
                    self.assertIsNone(runtime.process)
                    await job()
                    self.assertEqual(command.call_count, 2)
                    self.assertNotEqual(runtime.process.pid, process.pid)
                finally:
                    monitor.cancel()
                    await asyncio.gather(monitor, return_exceptions=True)
                    await runtime.stop()

    async def test_start_failure_and_native_crash_allow_next_request(self):
        import httpx

        async with httpx.AsyncClient(transport=httpx.MockTransport(lambda _: httpx.Response(200, json={}))) as client:
            runtime = EngineRuntime(config(), client)
            with patch('main.command_for', return_value=['/missing-ninfer']):
                with self.assertRaises(HTTPException) as error:
                    await runtime.infer({})
                self.assertEqual(error.exception.status_code, 503)
                self.assertIsNone(runtime.process)
            with patch('main.command_for', return_value=['sh', '-c', 'sleep 300 & wait']):
                try:
                    await runtime.infer({})
                    previous = runtime.process
                    await stop_process(previous)
                    await runtime.infer({})
                    self.assertNotEqual(previous.pid, runtime.process.pid)
                finally:
                    await runtime.stop()

    async def test_timeout_and_cancellation_reap_native_process(self):
        import httpx

        for cancel in (False, True):
            started = asyncio.Event()

            async def handler(request):
                if request.url.path == '/health':
                    return httpx.Response(200)
                started.set()
                await asyncio.Event().wait()

            c = config().model_copy(update={'general': config().general.model_copy(update={'timeout_seconds': 0.2})})
            async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
                runtime = EngineRuntime(c, client)
                with patch('main.command_for', return_value=['sh', '-c', 'sleep 300 & wait']):
                    task = asyncio.create_task(runtime.infer({}))
                    await started.wait()
                    process = runtime.process
                    if cancel:
                        task.cancel()
                        with self.assertRaises(asyncio.CancelledError):
                            await task
                    else:
                        with self.assertRaises(HTTPException) as error:
                            await task
                        self.assertEqual(error.exception.status_code, 504)
                    self.assertIsNotNone(process.returncode)
                    self.assertIsNone(runtime.process)

    async def test_loading_timeout_reaps_process(self):
        import httpx

        c = config().model_copy(update={'general': config().general.model_copy(update={'timeout_seconds': 0.1})})
        async with httpx.AsyncClient(transport=httpx.MockTransport(lambda _: httpx.Response(503))) as client:
            runtime = EngineRuntime(c, client)
            with patch('main.command_for', return_value=['sh', '-c', 'sleep 300 & wait']):
                task = asyncio.create_task(runtime.infer({}))
                await asyncio.sleep(0.04)
                process = runtime.process
                with self.assertRaises(HTTPException):
                    await task
                self.assertIsNotNone(process.returncode)
                self.assertIsNone(runtime.process)


if __name__ == '__main__':
    unittest.main()
