import asyncio
import base64
import copy
import sys
import tempfile
import unittest
from io import BytesIO
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[2] / 'src/backend_ocr'))
from config import ServerConfig, load_config
from fastapi import HTTPException
from main import create_application, prepare_request, stop_process
from PIL import Image
from recipe import command_for


def config():
    return ServerConfig.model_validate(
        dict(
            port=8000,
            max_requests=1,
            timeout_seconds=60,
            logo_model_path='/models/logo',
            paddle=dict(
                python='/opt/paddle/bin/python',
                port=8003,
                detection_path='/models/det',
                recognition_path='/models/rec',
                threads=8,
            ),
            engine=dict(
                path='/models/vision',
                model='vision',
                port=8002,
                memory_fraction=0.88,
                context_length=32768,
                max_images=16,
                max_batched_tokens=8192,
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
    def test_recipe_requires_weights_and_has_one_multimodal_engine(self):
        with tempfile.TemporaryDirectory() as tmp:
            c = config().engine.model_copy(update={'path': tmp})
            with self.assertRaises(ValueError):
                command_for(c)
            Path(tmp, 'config.json').write_text('{}')
            command = command_for(c)
            self.assertEqual(command[:3], ['vllm', 'serve', tmp])
            self.assertIn('--logits_processors', command)
            self.assertIn('--no-enable-prefix-caching', command)
            self.assertNotIn('--logits-processors', command)
            self.assertNotIn('--api-key', command)

    def test_all_images_and_schema_forwarded_with_exif_applied(self):
        body = {
            'model': 'vision',
            'messages': [
                {'role': 'system', 'content': 'instructions'},
                {'role': 'user', 'content': [{'type': 'text', 'text': 'same receipt'}, photo(), photo()]},
            ],
            'response_format': {'type': 'json_schema', 'json_schema': {'name': 'receipt'}},
        }
        prepared = prepare_request(copy.deepcopy(body), config())
        self.assertEqual(prepared['response_format'], body['response_format'])
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
                prepare_request({'model': 'vision', 'messages': [{'content': images}]}, config())

    def test_two_engines_read_each_photo_and_failure_is_not_partial_success(self):
        import httpx

        async def run(fail):
            c = config()
            calls = []

            async def handler(request):
                import json

                data = json.loads(request.content)
                calls.append((request.url.port, data))
                if request.url.port == c.paddle.port:
                    return httpx.Response(503 if fail else 200, json={"words": []})
                return httpx.Response(
                    200,
                    json={
                        "choices": [{"finish_reason": "stop", "message": {"content": "MILK 3.00"}}],
                        "usage": {"prompt_tokens": 1, "completion_tokens": 2, "total_tokens": 3},
                    },
                )

            app = create_application(c)
            app.state.requests = asyncio.Semaphore(1)
            async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as upstream:
                app.state.client = upstream
                async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
                    response = await client.post(
                        "/v1/ocr/recognize", json={"model": "vision", "messages": [{"content": [photo(), photo()]}]}
                    )
                    if fail:
                        self.assertEqual(response.status_code, 502)
                    else:
                        self.assertEqual(response.status_code, 200)
                        self.assertEqual(len(response.json()["pages"]), 2)
                        self.assertEqual(response.json()["usage"]["total_tokens"], 6)
                        self.assertEqual(
                            [port for port, _ in calls], [c.engine.port, c.paddle.port, c.engine.port, c.paddle.port]
                        )
                        for port, body in calls:
                            if port == c.engine.port:
                                self.assertEqual(body["messages"][0]["content"][0]["text"], "<image>document parsing.")
                                self.assertNotIn("response_format", body)

        asyncio.run(run(False))
        asyncio.run(run(True))

    def test_concurrent_receipts_wait_and_failure_releases_queue(self):
        import httpx

        async def run():
            app = create_application(config())
            app.state.requests = asyncio.Semaphore(1)
            started = asyncio.Event()
            release = asyncio.Event()
            calls = []

            async def handler(request):
                calls.append(request.url.port)
                if len(calls) == 1:
                    started.set()
                    await release.wait()
                    return httpx.Response(503, json={"detail": "unavailable"})
                if request.url.port == config().paddle.port:
                    return httpx.Response(200, json={"words": []})
                return httpx.Response(
                    200, json={"choices": [{"finish_reason": "stop", "message": {"content": "MILK 3.00"}}]}
                )

            async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as upstream:
                app.state.client = upstream
                async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
                    body = {"model": "vision", "messages": [{"content": [photo()]}]}
                    first = asyncio.create_task(client.post("/v1/ocr/recognize", json=body))
                    await asyncio.wait_for(started.wait(), 2)
                    second = asyncio.create_task(client.post("/v1/ocr/recognize", json=body))
                    # A queued request must not reach either engine before the first completes.
                    await asyncio.sleep(0.05)
                    self.assertFalse(second.done())
                    self.assertEqual(len(calls), 1)
                    release.set()
                    responses = await asyncio.wait_for(asyncio.gather(first, second), 2)
                    self.assertEqual([r.status_code for r in responses], [502, 200])
                    self.assertEqual(calls, [config().engine.port, config().engine.port, config().paddle.port])

        asyncio.run(run())

    def test_logo_matching_validates_requests_and_releases_serial_queue(self):
        import httpx

        class Matcher:
            def match(self, image, references):
                if image == "bad":
                    raise ValueError("Invalid image")
                return {"model": "test", "scores": [{"id": r["id"], "score": 0.0} for r in references]}

        async def run():
            app = create_application(config())
            app.state.requests = asyncio.Semaphore(1)
            app.state.logo_lock = asyncio.Lock()
            app.state.logo_matcher = Matcher()
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
                for references in [[], [{"id": "x", "image": "image"}] * 2, [{"id": 7, "image": "image"}], [{}] * 9]:
                    response = await client.post("/v1/logo/match", json={"image": "image", "references": references})
                    self.assertEqual(response.status_code, 400)
                body = {"image": "bad", "references": [{"id": "a", "image": "image"}]}
                self.assertEqual((await client.post("/v1/logo/match", json=body)).status_code, 400)
                body["image"] = "image"
                await app.state.requests.acquire()
                waiting = asyncio.create_task(client.post("/v1/logo/match", json=body))
                await asyncio.sleep(0.03)
                self.assertFalse(waiting.done())
                app.state.requests.release()
                response = await asyncio.wait_for(waiting, 2)
                self.assertEqual(response.status_code, 200)
                self.assertEqual(response.json()["scores"][0]["id"], "a")

        asyncio.run(run())

    def test_config_rejects_parallel_inference(self):
        from pydantic import ValidationError

        for section, field in [(None, "max_requests"), ("engine", "max_sequences")]:
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


if __name__ == '__main__':
    unittest.main()
