"""Transport contract tests; no Hermes imports, credentials or personal state."""
import asyncio
import importlib.util
import json
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location(
    "hermac_bridge", Path(__file__).parents[1] / "Hermac/Resources/hermac_bridge.py")
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)


class FakeSocket:
    def __init__(self):
        self.frames = []

    async def send(self, raw):
        self.frames.append(json.loads(raw))


class FakeClient:
    def __init__(self):
        self.websocket = FakeSocket()
        self.calls = []

    async def rpc(self, method, **params):
        self.calls.append((method, params))
        return {"sessions": [{"session_id": "sample", "title": "测试"}]}


class BridgeTests(unittest.IsolatedAsyncioTestCase):
    async def test_preserves_request_identity_and_unicode_payload(self):
        client, output = FakeClient(), []
        await bridge.forward_request(client, {
            "jsonrpc": "2.0", "id": 42, "method": "session.list",
            "params": {"scope": "stored"}}, output.append)
        self.assertEqual(client.calls, [("session.list", {"_timeout": 120, "scope": "stored"})])
        self.assertEqual(output[0]["id"], 42)
        self.assertEqual(output[0]["result"]["sessions"][0]["title"], "测试")

    async def test_server_request_response_is_forwarded_without_agent_call(self):
        client, output = FakeClient(), []
        frame = {"jsonrpc": "2.0", "id": "srq-9", "result": {"choice": "deny"}}
        await bridge.forward_request(client, frame, output.append)
        self.assertEqual(client.websocket.frames, [frame])
        self.assertEqual(client.calls, [])
        self.assertEqual(output, [])

    async def test_rpc_refusal_keeps_code_data_and_request_identity(self):
        class Refusal(ValueError):
            code = 4001
            data = {"reason": "stale_revision"}

        class RefusingClient(FakeClient):
            async def rpc(self, method, **params):
                raise Refusal("stale_revision")

        output = []
        await bridge.forward_request(RefusingClient(), {
            "id": 7, "method": "session.mutate", "params": {}}, output.append)
        self.assertEqual(output, [{"jsonrpc": "2.0", "id": 7, "error": {
            "code": 4001, "message": "stale_revision", "data": {"reason": "stale_revision"}}}])


if __name__ == "__main__":
    unittest.main()
