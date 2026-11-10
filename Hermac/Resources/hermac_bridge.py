"""A stdio transport for Hermes's authenticated, local gateway.

Run through the installed Hermes launcher's --print-runtime-command interface.
Hermes keeps ownership of credentials, agent execution and conversation storage.
"""
import asyncio
import json
import os
import sys

RPC_OUTPUT = sys.stdout


def write_frame(frame):
    RPC_OUTPUT.write(json.dumps(frame, ensure_ascii=False) + "\n")
    RPC_OUTPUT.flush()


def error_frame(request_id, message, code=-32000):
    return {"jsonrpc": "2.0", "id": request_id,
            "error": {"code": code, "message": message}}


async def forward_request(client, frame, emit=write_frame):
    """Preserve the native caller's id; the installed client owns wire correlation."""
    if "method" not in frame:
        await client.websocket.send(json.dumps(frame))
        return
    request_id = frame.get("id")
    try:
        result = await client.rpc(frame["method"], _timeout=120,
                                  **frame.get("params", {}))
        emit({"jsonrpc": "2.0", "id": request_id, "result": result})
    except Exception as exc:
        code = getattr(exc, "code", None) or -32000
        error = error_frame(request_id, str(exc), code)
        if getattr(exc, "data", None):
            error["error"]["data"] = exc.data
        emit(error)


async def relay(client):
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader(limit=8 * 1024 * 1024)
    transport, _ = await loop.connect_read_pipe(
        lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer)
    pending = set()

    async def read_input():
        while raw := await reader.readline():
            try:
                frame = json.loads(raw)
            except ValueError:
                write_frame(error_frame(None, "Invalid JSON frame", -32700))
                continue
            task = asyncio.create_task(forward_request(client, frame))
            pending.add(task)
            task.add_done_callback(pending.discard)

    async def read_events():
        while True:
            frame = await client.events.get()
            if isinstance(frame, Exception):
                raise frame
            write_frame(frame)

    incoming = asyncio.create_task(read_input())
    events = asyncio.create_task(read_events())
    try:
        done, _ = await asyncio.wait({incoming, events},
                                     return_when=asyncio.FIRST_COMPLETED)
        for task in done:
            task.result()
    finally:
        transport.close()
        for task in {incoming, events, *pending}:
            task.cancel()
        await asyncio.gather(incoming, events, *pending, return_exceptions=True)


async def main():
    # Startup and plugin diagnostics belong to stderr, never in the RPC stream.
    sys.stdout = sys.stderr
    # Hermac's first version deliberately attaches only to this Mac's local deployment.
    os.environ.pop("HERMES_TUI_GATEWAY_URL", None)
    from hermes_cli.gateway_client import connect_gateway
    async with connect_gateway() as client:
        write_frame({"jsonrpc": "2.0", "method": "event", "params": {
            "type": "bridge.ready", "payload": {}}})
        await relay(client)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except (KeyboardInterrupt, BrokenPipeError):
        pass
    except Exception as exc:
        write_frame({"jsonrpc": "2.0", "method": "event", "params": {
            "type": "bridge.error", "payload": {"message": str(exc)}}})
        raise SystemExit(1)
