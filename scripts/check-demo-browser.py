#!/usr/bin/env python3
"""Opt-in real Chrome check. Temporary profile, synthetic loopback pages, no model."""
import argparse
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import threading
import uuid

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "BrowserRuntime"))
from install import ROOT, LOCK
from server import Browser

spec = importlib.util.spec_from_file_location("demo_fixture", REPO / "examples/browser-routine/serve.py")
fixture_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture_module)

SELECTORS = {"card": ".card", "title": "h2 a", "link": "h2 a", "idAttribute": "data-id",
             "company": ".company", "badges": ".badge", "next": "#next"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-root", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path, default=REPO / "media")
    args = parser.parse_args()
    config = args.runtime_root / "runtime.json"
    if not config.is_file():
        parser.error("Install BrowserRuntime first; see guides/building.md")
    args.output.mkdir(parents=True, exist_ok=True)
    fixture = fixture_module.ThreadingHTTPServer(("127.0.0.1", 0), fixture_module.Handler)
    thread = threading.Thread(target=fixture.serve_forever, daemon=True)
    thread.start()
    results, seen = [], set()
    try:
        with tempfile.TemporaryDirectory(prefix="context-desk-public-browser-") as temporary:
            root = Path(temporary)
            (root / "runtime.json").write_bytes(config.read_bytes())
            runtime_name = "chrome-devtools-" + LOCK["version"]
            (root / runtime_name).symlink_to((args.runtime_root / runtime_name).resolve())
            browser, host = Browser(root), None
            try:
                for index, snapshot in enumerate(("1", "1", "2"), 1):
                    url = f"http://127.0.0.1:{fixture.server_port}/?snapshot={snapshot}"
                    opened = browser.open(url)
                    host = browser.chrome
                    token = opened["session"]
                    first = browser.cards(token, SELECTORS)
                    assert first["complete"] and len(first["cards"]) == 2, "First-page coverage failed"
                    if index == 1:
                        capture = root / "browser-catalog.png"
                        browser.native("take_screenshot", {"pageId": browser.page, "filePath": str(capture), "fullPage": True})
                        (args.output / capture.name).write_bytes(capture.read_bytes())
                    second = browser.next(token, str(uuid.uuid4()), first["url"], None, SELECTORS, next_token=first["nextToken"])
                    assert second["complete"] and len(second["cards"]) == 2, "Second-page coverage failed"
                    assert {c["id"] for c in first["cards"]}.isdisjoint(c["id"] for c in second["cards"])
                    assert browser.verify_result(token, "#end", text="End of catalog")["verified"]
                    cards = first["cards"] + second["cards"]
                    matches = sorted(c["id"] for c in cards if c["company"] == "Frontend" and c["badges"] == "Open")
                    new = sorted(set(matches) - seen)
                    seen.update(new)
                    expected = [(["W-101", "W-103"], ["W-101", "W-103"]),
                                (["W-101", "W-103"], []), (["W-101", "W-104"], ["W-104"])][index - 1]
                    assert (matches, new) == expected
                    results.append({"snapshot": snapshot, "pages": 2, "cards": len(cards),
                                    "matching": matches, "new": new, "seen": sorted(seen)})
                    browser.close_session(token)
            finally:
                browser.stop()
                # Only this isolated check's owned Chrome child is stopped.
                if host and host.child and host.child.poll() is None:
                    host.child.terminate()
                    host.child.wait(timeout=10)
        report = {"kind": "production-browser-adapter-check", "model_called": False,
                  "scheduler_run": False, "profile": "temporary-synthetic-only",
                  "chrome_devtools_mcp": LOCK["version"], "runs": results}
        (args.output / "browser-check.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
    finally:
        fixture.shutdown()
        fixture.server_close()


if __name__ == "__main__":
    main()
