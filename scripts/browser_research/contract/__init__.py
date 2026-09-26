"""Shared direct-driver research contract, version 1 (schema v1 extension)."""
from dataclasses import dataclass, field
from typing import Any, Protocol

CONTRACT_VERSION = 1
CASE_SECONDS = 30
WATCHDOG_SECONDS = 60
POST_CANCEL_SECONDS = 5


@dataclass(frozen=True)
class Target:
    run_id: str
    generation: str
    url: str
    nonce: str
    profile: str
    target_id: str


@dataclass(frozen=True)
class Request:
    request_id: str
    target: Target
    operation: str
    arguments: dict[str, Any] = field(default_factory=dict)
    deadline_ns: int = 0


@dataclass
class Result:
    status: str
    value: Any = None
    error: str | None = None
    uncertain: bool = False
    dispatched: bool = False
    details: dict[str, Any] = field(default_factory=dict)


class Adapter(Protocol):
    candidate_id: str
    candidate_version: str

    def preflight(self) -> Result: ...
    def attach(self, request: Request) -> Result: ...
    def execute(self, request: Request) -> Result: ...
    def cancel(self, request_id: str) -> Result: ...
    def inspect_state(self) -> dict[str, Any]: ...
    def detach(self) -> Result: ...
