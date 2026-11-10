"""Real local connection, image staging + CRUD smoke test. Never submits a model prompt.

Only its own temporary 'Hermac 连接测试' session is created, renamed and deleted.
"""
import base64
import json
from pathlib import Path
import queue
import subprocess
import threading
import uuid


def main():
    home = Path.home()
    launcher = home / ".local/bin/hermes"
    helper = Path(__file__).parents[1] / "Hermac/Resources/hermac_bridge.py"
    command = json.loads(subprocess.check_output([
        str(launcher), "--print-runtime-command", "--module", "types", "--", str(helper)]))
    command[command.index("-c") + 1] += ";runpy.run_path(sys.argv[1], run_name='__main__')"
    child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True)
    frames, errors = queue.Queue(), []

    def pump():
        for line in child.stdout:
            frames.put(json.loads(line))
        frames.put(None)

    threading.Thread(target=pump, daemon=True).start()
    threading.Thread(target=lambda: errors.extend(child.stderr), daemon=True).start()
    sequence = 0

    def rpc(method, **params):
        nonlocal sequence
        sequence += 1
        rid = sequence
        child.stdin.write(json.dumps({"jsonrpc": "2.0", "id": rid,
                                      "method": method, "params": params}) + "\n")
        child.stdin.flush()
        while True:
            frame = frames.get(timeout=45)
            if frame is None:
                raise RuntimeError("Bridge exited: " + "".join(errors)[-2000:])
            if frame.get("id") == rid:
                if "error" in frame:
                    raise RuntimeError(str(frame["error"]))
                return frame["result"]

    session = None
    staged_image = None
    try:
        while True:
            frame = frames.get(timeout=45)
            if frame is None:
                raise RuntimeError("Bridge exited: " + "".join(errors)[-2000:])
            kind = frame.get("params", {}).get("type")
            if kind == "bridge.error":
                raise RuntimeError(frame["params"]["payload"].get("message"))
            if kind == "bridge.ready":
                break
        assert rpc("ping")["pong"]
        print("Local gateway ping: PASS", flush=True)
        for scope in ("live", "stored"):
            result = rpc("session.list", scope=scope, limit=200)
            assert result["scope"] == scope and isinstance(result["sessions"], list)
            print("Session list (" + scope + "): PASS", flush=True)
        snapshot = rpc("session.create", source="gui", request_id=str(uuid.uuid4()),
                       title="Hermac 连接测试 " + uuid.uuid4().hex[:8])
        session = snapshot["session_id"]
        assert snapshot["messages"] == [] and not snapshot["running"]
        print("Session create: PASS", flush=True)
        # Synthetic 1×1 transparent PNG; never reads or captures the user's screen.
        image_base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        image = rpc("image.attach_bytes", session_id=session,
                    content_base64=image_base64, filename="hermac-smoke.png", ext="png")
        staged_image = Path(image["path"])
        assert image["attached"] is True and image["mime"] == "image/png"
        assert staged_image.is_absolute() and staged_image.is_file()
        assert staged_image.read_bytes() == base64.b64decode(image_base64)
        assert image["bytes"] == staged_image.stat().st_size
        snapshot = rpc("session.resume", session_id=session, display_projection=True)
        assert snapshot["messages"] == [] and not snapshot["running"]
        print("Synthetic image upload + staging (no model prompt): PASS", flush=True)
        renamed = rpc("session.mutate", session_id=session, request_id=str(uuid.uuid4()),
                      expected_revision=snapshot["revision"],
                      expected_generation=snapshot["execution_generation"],
                      operation="rename", payload={"title": "Hermac 连接测试 已重命名 " + uuid.uuid4().hex[:8]})
        assert renamed["operation"] == "rename"
        snapshot = rpc("session.resume", session_id=session, display_projection=True)
        assert "已重命名" in snapshot["info"]["title"]
        print("Session rename + resume: PASS", flush=True)
    finally:
        if staged_image:
            staged_image.unlink(missing_ok=True)
        if session:
            snapshot = rpc("session.resume", session_id=session)
            result = rpc("session.mutate", session_id=session, request_id=str(uuid.uuid4()),
                         expected_revision=snapshot["revision"],
                         expected_generation=snapshot["execution_generation"],
                         operation="delete", payload={})
            assert result["operation"] == "delete"
            print("Session delete: PASS", flush=True)
        child.stdin.close()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.terminate()
            child.wait(timeout=5)
        assert child.returncode == 0, "Bridge did not shut down cleanly"
        print("Bridge shutdown: PASS", flush=True)


if __name__ == "__main__":
    main()
