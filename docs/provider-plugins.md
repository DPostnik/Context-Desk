# Provider plugins — protocol v1

Context Desk discovers installed provider plugins at `~/Library/Application Support/Context Desk/plugins/<id>/plugin.json`. The app builds and runs without any plugin source, runtime or manifest. There is no statically linked Headroom module. Adding a compatible provider requires installing a new folder, refreshing the list and reconnecting, not changing or recompiling the app.

This version supports process-based, loopback Responses proxies. Arbitrary UI extensions and arbitrary Codex configuration overrides are not part of protocol v1. Installed plugins are executable code running with the user's OS privileges, not a sandboxed data format. Discovery only reads manifests; the host launches plugins explicitly selected as the default route or referenced by saved conversations. Newly discovered plugins do not auto-run.

## Manifest

```json
{
  "schemaVersion": 1,
  "id": "my_provider",
  "title": "Мой провайдер",
  "version": "1.0.0",
  "executable": "bin/provider",
  "arguments": []
}
```

The directory name must match the ID. IDs match `[a-z][a-z0-9_]{0,63}`; `direct` is reserved. Executables must use relative paths without `.` or `..` segments. Arguments are passed directly to `Process`, never through a shell. Manifests with unknown schema versions are rejected and displayed as installation issues. Each plugin is responsible for installing its own pinned dependencies; the app does not download code or dependencies during discovery.

## Interface languages

Protocol v1 accepts optional bilingual fields without changing route IDs or wire version: the manifest may supply `titleTranslations` and `descriptionTranslations`, status may supply `detailTranslations`, and each metric may supply `titleTranslations`. Each provided object must contain non-empty `ru` and `en` strings; display limits apply to both. For example: `"titleTranslations": {"ru":"Запросов", "en":"Requests"}`. The host chooses the active app language. Original `title` and `detail` remain fallback fields for older hosts/plugins. First-party plugins are required to ship both translations.

## Process and readiness

The working directory is the installed plugin folder. The host appends:

```
--state <plugin>/data --ready-file <unique-file> --instance <unique-id> --parent <host-pid>
```

The environment is restricted to a small allowlist, including the app's dedicated `CODEX_HOME`; provider credentials and arbitrary inherited environment variables are not injected. Bind an OS-assigned port on `127.0.0.1`, then atomically publish:

```json
{"protocolVersion":1,"pluginID":"my_provider","instance":"<host-instance>","port":12345}
```

Implement `/v1` Responses endpoints and `GET /contextdesk/status`:

```json
{
  "protocolVersion": 1,
  "pluginID": "my_provider",
  "pluginVersion": "1.0.0",
  "instance": "<host-instance>",
  "detail": "Подключён",
  "metrics": [{"id":"requests","title":"Запросов","value":0}]
}
```

Status IDs, version and instance must match the manifest/launch. Metrics must have unique IDs; up to 20 metrics and bounded text are allowed. These values are display data, not commands or Markdown. The host rejects incompatible responses, failed starts and non-loopback provider endpoints. Health requests do not follow HTTP redirects. The plugin must remove readiness on shutdown and monitor its parent to avoid surviving an unexpected host exit.

## Routing and failure semantics

Saved routes are string IDs. Existing `headroom` records retain their exact encoding and `contextdesk_headroom` provider identity; unknown or removed IDs also survive decoding. Direct is the default for a fresh installation. Missing/unhealthy plugin routes cannot send and never fall back to Direct.

The host constructs only scoped `model_providers.contextdesk_<id>` overrides, with Responses API, OpenAI authentication, WebSockets and zero retries. It does not accept permission, sandbox or scheduling configuration from a plugin. Provider status is checked before sending and every five seconds while connected. A plugin failure pauses its queues; if affected work is active, the shared engine transport is closed without replaying turns. Project access settings and normal approval routing stay in the host.

## Validation and installation examples

`plugins/headroom` is the first implementation, including its own installer, runner and dependency lock. Synthetic test plugins cover discovery, multiple IDs, removal, legacy persistence, incompatible schemas/protocols/instances and process lifecycle without model requests or real credentials.

After installing a plugin, `context-probe --plugin <id> --plugin-check` validates its startup/health/shutdown protocol without connecting to Codex or issuing a model request. The probe must be built from the repository using the same compatible SDK as the app.
