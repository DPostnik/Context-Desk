"""Standalone Context Desk provider plugin, protocol v1. No credential handling."""
import argparse
import asyncio
import importlib.metadata
import json
import os
from pathlib import Path
import socket


def status_payload(instance, version, metrics):
    detail = f"Headroom {version} · сжатие контекста без потери данных"
    return {"protocolVersion": 1, "pluginID": "headroom", "pluginVersion": "1.0.1",
            "instance": instance, "detail": detail,
            "detailTranslations": {"ru": detail, "en": f"Headroom {version} · lossless context compression"},
            "metrics": [
                {"id": "requests", "title": "Обработано запросов", "value": metrics.requests_total,
                 "titleTranslations": {"ru": "Обработано запросов", "en": "Requests processed"}},
                {"id": "failed", "title": "Запросов с ошибкой", "value": metrics.requests_failed,
                 "titleTranslations": {"ru": "Запросов с ошибкой", "en": "Failed requests"}},
                {"id": "tokensSaved", "title": "Убрано токенов за запуск", "value": metrics.tokens_saved_total,
                 "titleTranslations": {"ru": "Убрано токенов за запуск", "en": "Context tokens removed this session"}}] }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", required=True)
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--instance", required=True)
    parser.add_argument("--parent", required=True, type=int)
    args = parser.parse_args()
    os.umask(0o077)
    root = Path(args.state)
    root.mkdir(parents=True, exist_ok=True)
    # Configure before importing Headroom; no settings from ~/.headroom.
    os.environ.update({
        "HEADROOM_CONFIG_DIR": str(root / "config"),
        "HEADROOM_WORKSPACE_DIR": str(root / "state"),
        "HEADROOM_CCR_SQLITE_PATH": str(root / "state" / "ccr.sqlite"),
        "HEADROOM_CACHE_TTL_OBS_PATH": str(root / "state" / "ttl-observations.jsonl"),
        "HEADROOM_CACHE_TTL_LEARNED_PATH": str(root / "state" / "ttl-learned.json"),
        "HEADROOM_BEACON": "off", "HEADROOM_TELEMETRY": "off",
        "HEADROOM_UPDATE_CHECK": "off", "DO_NOT_TRACK": "1",
        "HEADROOM_CC_SWITCH_RECONCILE": "0",
        "HF_HOME": str(root / "cache" / "huggingface"),
        "XDG_CACHE_HOME": str(root / "cache"),
        "TIKTOKEN_CACHE_DIR": str(root / "cache" / "tiktoken"),
        "LITELLM_LOCAL_MODEL_COST_MAP": "True",
    })
    version = importlib.metadata.version("headroom-ai")
    if version != "0.38.0":
        raise RuntimeError("Unsupported Headroom version")
    from headroom.proxy.models import ProxyConfig
    from headroom.proxy.server import create_app
    import uvicorn

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    config = ProxyConfig(
        host="127.0.0.1", port=port, mode="cache", lossless=True,
        disable_kompress=True, disable_kompress_fallback=True,
        image_optimize=False, ccr_inject_tool=False, ccr_inject_marker=False,
        cache_enabled=False, rate_limit_enabled=False, retry_enabled=False,
        retry_max_attempts=1, subscription_tracking_enabled=False,
        memory_enabled=False, traffic_learning_enabled=False,
        log_full_messages=False, periodic_toin_stats_enabled=False,
    )
    app = create_app(config)

    @app.get("/contextdesk/status")
    async def status():
        metrics = app.state.proxy.metrics
        return status_payload(args.instance, version, metrics)


    # Headroom mounts its dashboard at /; put our health route before that mount.
    app.router.routes.insert(0, app.router.routes.pop())

    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port,
                                         log_level="error", access_log=False))

    async def supervise():
        task = asyncio.create_task(server.serve(sockets=[sock]))
        ready = Path(args.ready_file)
        try:
            while not server.started and not task.done():
                if os.getppid() != args.parent:
                    server.should_exit = True
                    return
                await asyncio.sleep(0.1)
            if task.done():
                await task
                return
            temporary = ready.with_suffix(".tmp")
            temporary.write_text(json.dumps({"protocolVersion": 1, "pluginID": "headroom",
                                             "port": port, "instance": args.instance}))
            temporary.replace(ready)
            while not task.done():
                if os.getppid() != args.parent:
                    server.should_exit = True
                await asyncio.sleep(0.5)
            await task
        finally:
            ready.unlink(missing_ok=True)

    asyncio.run(supervise())


if __name__ == "__main__":
    main()
