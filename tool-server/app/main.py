from contextlib import asynccontextmanager
from dataclasses import replace
import hashlib
import json
import re
import time
from urllib.parse import urlparse
from uuid import uuid4

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException, Request

from .config import settings
from .models import (
    FetchRequest,
    FetchResponse,
    HandoffRequest,
    MemoryWriteRequest,
    OrchestrateRequest,
    OrchestrateResponse,
    SearchRequest,
    SearchResponse,
    SearchResult,
    SpawnRequest,
    SummarizeRequest,
    SummarizeResponse,
    TransitDecryptRequest,
    TransitDecryptResponse,
    TransitEncryptRequest,
    TransitEncryptResponse,
)
from .provisioning import provisioning
from .security import AuthContext, require_auth_context
from .storage import storage


def _validate_memory_key(agent_id: str, key: str) -> str:
    if key.startswith(f"agent:{agent_id}:"):
        return key
    if key.startswith("shared:memory:"):
        return key
    raise HTTPException(status_code=403, detail="Memory key outside allowed namespace")


@asynccontextmanager
async def lifespan(_: FastAPI):
    await storage.connect()
    try:
        yield
    finally:
        await storage.close()


app = FastAPI(title="garrison-tool-server", lifespan=lifespan)


def _audit_payload(raw: bytes) -> str:
    mode = settings.audit_payload_mode
    text = raw.decode("utf-8", errors="replace") if raw else ""
    if mode == "hash-only":
        return hashlib.sha256(raw).hexdigest() if raw else ""
    if mode == "redacted":
        redacted = re.sub(r'"(authorization|token|secret_id|role_id|password)"\s*:\s*"[^"]*"', '"\\1":"[REDACTED]"', text, flags=re.IGNORECASE)
        redacted = re.sub(r"(Bearer\s+)[^\s\"]+", r"\1[REDACTED]", redacted, flags=re.IGNORECASE)
        return redacted
    return text


def _maybe_body_json(raw: bytes) -> dict:
    if not raw:
        return {}
    try:
        value = json.loads(raw.decode("utf-8"))
        return value if isinstance(value, dict) else {}
    except Exception:  # noqa: BLE001
        return {}


@app.middleware("http")
async def audit_http_request(request, call_next):
    started_at = time.time()
    trace_id = request.headers.get("x-trace-id") or str(uuid4())
    req_body = await request.body()
    req_json = _maybe_body_json(req_body)

    status_code = 500
    error_text = ""
    try:
        response = await call_next(request)
        status_code = response.status_code
    except Exception as exc:  # noqa: BLE001
        error_text = str(exc)
        raise
    finally:
        elapsed_ms = int((time.time() - started_at) * 1000)
        path = request.url.path
        event = {
            "trace_id": trace_id,
            "agent_id": request.headers.get("x-agent-id", ""),
            "agent_class": request.headers.get("x-agent-class", ""),
            "human_session_id": request.headers.get("x-human-session-id", ""),
            "model_provider": req_json.get("model_provider", "local"),
            "model_name": req_json.get("model_name", settings.summarize_model),
            "token_counts": req_json.get("token_counts", {}),
            "tool_name": path,
            "status": "ok" if status_code < 400 else "error",
            "status_code": status_code,
            "duration_ms": elapsed_ms,
            "timestamp": storage.utc_now_iso(),
            "payload_mode": settings.audit_payload_mode,
            "request_payload": _audit_payload(req_body),
            "error": error_text,
        }

        if not settings.use_inmemory:
            try:
                client = provisioning._mongo_client()
                client["garrison_audit"]["llm"].insert_one(event)
            except Exception:  # noqa: BLE001
                pass

        print(json.dumps(event, default=str))

    return response


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/internal/audit/ingest/{source}")
async def ingest_audit_events(source: str, request: Request, x_audit_ingest_token: str | None = Header(default=None)) -> dict[str, int]:
    if settings.audit_ingest_token and x_audit_ingest_token != settings.audit_ingest_token:
        raise HTTPException(status_code=403, detail="Invalid audit ingest token")

    if source not in {"vault", "nginx"}:
        raise HTTPException(status_code=400, detail="Unsupported audit source")

    raw = await request.body()
    text = raw.decode("utf-8", errors="replace").strip()
    if not text:
        return {"ingested": 0}

    records: list[dict] = []
    try:
        parsed = json.loads(text)
        if isinstance(parsed, dict):
            records = [parsed]
        elif isinstance(parsed, list):
            records = [item for item in parsed if isinstance(item, dict)]
    except json.JSONDecodeError:
        # fluent-bit json_lines output posts one record per line.
        for line in text.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                parsed_line = json.loads(line)
                if isinstance(parsed_line, dict):
                    records.append(parsed_line)
            except json.JSONDecodeError:
                records.append({"log": line})

    docs: list[dict] = []
    for record in records:
        log_value = record.get("log")
        parsed_log: dict | None = None
        if isinstance(log_value, str):
            try:
                candidate = json.loads(log_value)
                if isinstance(candidate, dict):
                    parsed_log = candidate
            except json.JSONDecodeError:
                parsed_log = None

        docs.append(
            {
                "source": source,
                "ingested_at": storage.utc_now_iso(),
                "record": record,
                "parsed_log": parsed_log,
            }
        )

    if not docs:
        return {"ingested": 0}

    if not settings.use_inmemory:
        try:
            client = provisioning._mongo_client()
            client["garrison_audit"][source].insert_many(docs)
        except Exception as exc:  # noqa: BLE001
            raise HTTPException(status_code=503, detail=f"Audit ingest storage unavailable: {exc}") from exc

    return {"ingested": len(docs)}


def _scratch_key(agent_id: str, key: str) -> str:
    if not key:
        raise HTTPException(status_code=400, detail="Scratch key cannot be empty")
    return f"agent:{agent_id}:scratch:{key}"


def _validate_fetch_url(url: str) -> None:
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"}:
        raise HTTPException(status_code=400, detail="Only http/https URLs are allowed")
    if not parsed.netloc:
        raise HTTPException(status_code=400, detail="Fetch URL must include host")


def _build_fetch_client() -> httpx.AsyncClient:
    kwargs: dict = {
        "timeout": 10,
        "follow_redirects": True,
    }
    if settings.fetch_proxy_url:
        kwargs["proxy"] = settings.fetch_proxy_url
    return httpx.AsyncClient(**kwargs)


def _extractive_summary(content: str, max_tokens: int) -> tuple[str, list[str]]:
    sentences = [s.strip() for s in re.split(r"(?<=[.!?])\s+", content) if s.strip()]
    if not sentences:
        return "", []

    max_words = max_tokens
    selected: list[str] = []
    used = 0
    for sentence in sentences:
        words = sentence.split()
        if used + len(words) > max_words and selected:
            break
        selected.append(sentence)
        used += len(words)
        if used >= max_words:
            break

    key_points = selected[:5]
    return " ".join(selected), key_points


async def _summarize_with_ollama(content: str, max_tokens: int, output_format: str) -> tuple[str, list[str]]:
    prompt = (
        "Summarize the content. Return concise output. "
        f"Format={output_format}. Max tokens={max_tokens}.\n\n{content}"
    )
    payload = {
        "model": settings.summarize_model,
        "prompt": prompt,
        "stream": False,
        "options": {"num_predict": max_tokens},
    }
    async with httpx.AsyncClient(timeout=20) as client:
        resp = await client.post(f"{settings.ollama_url}/api/generate", json=payload)
    resp.raise_for_status()
    text = resp.json().get("response", "").strip()
    points = [line.lstrip("- ").strip() for line in text.splitlines() if line.strip()][:5]
    return text, points


async def _transit_encrypt(plaintext: str, key: str) -> str:
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.post(
            f"{settings.vault_addr}/v1/transit/encrypt/{key}",
            headers={"X-Vault-Token": settings.vault_token},
            json={"plaintext": plaintext},
        )
        if resp.status_code == 404:
            await client.post(
                f"{settings.vault_addr}/v1/sys/mounts/transit",
                headers={"X-Vault-Token": settings.vault_token},
                json={"type": "transit"},
            )
            await client.post(
                f"{settings.vault_addr}/v1/transit/keys/{key}",
                headers={"X-Vault-Token": settings.vault_token},
                json={"type": "aes256-gcm96"},
            )
            resp = await client.post(
                f"{settings.vault_addr}/v1/transit/encrypt/{key}",
                headers={"X-Vault-Token": settings.vault_token},
                json={"plaintext": plaintext},
            )
    if resp.status_code != 200:
        raise HTTPException(status_code=502, detail=f"Transit encrypt failed: {resp.text}")
    return resp.json().get("data", {}).get("ciphertext", "")


async def _transit_decrypt(ciphertext: str, key: str) -> str:
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.post(
            f"{settings.vault_addr}/v1/transit/decrypt/{key}",
            headers={"X-Vault-Token": settings.vault_token},
            json={"ciphertext": ciphertext},
        )
        if resp.status_code == 404:
            await client.post(
                f"{settings.vault_addr}/v1/sys/mounts/transit",
                headers={"X-Vault-Token": settings.vault_token},
                json={"type": "transit"},
            )
            await client.post(
                f"{settings.vault_addr}/v1/transit/keys/{key}",
                headers={"X-Vault-Token": settings.vault_token},
                json={"type": "aes256-gcm96"},
            )
            resp = await client.post(
                f"{settings.vault_addr}/v1/transit/decrypt/{key}",
                headers={"X-Vault-Token": settings.vault_token},
                json={"ciphertext": ciphertext},
            )
    if resp.status_code != 200:
        raise HTTPException(status_code=502, detail=f"Transit decrypt failed: {resp.text}")
    return resp.json().get("data", {}).get("plaintext", "")


def _parse_corpus(corpus: str) -> tuple[str, str]:
    parts = corpus.split(".", 1)
    if len(parts) == 2:
        return parts[0], parts[1]
    return corpus, "objects"


async def _spawn_with_auth(body: SpawnRequest, auth: AuthContext) -> dict:
    if auth.agent_class != "orchestrator":
        raise HTTPException(status_code=403, detail="Only orchestrator can spawn")
    if auth.spawn_depth >= settings.spawn_max_depth:
        raise HTTPException(status_code=403, detail="Spawn depth limit exceeded")

    human_session_id = auth.human_session_id or provisioning.system_session_id()
    creds = await provisioning.issue_spawn_credentials(body.agent_class)

    payload = {
        "agent_class": body.agent_class,
        "task_context": body.task_context,
        "memory_keys": body.memory_keys,
        "parent_agent_id": auth.agent_id,
        "human_session_id": human_session_id,
        "spawn_depth": auth.spawn_depth + 1,
        "root_orchestrator_id": auth.root_orchestrator_id,
        "vault_role_id": creds.role_id,
        "vault_secret_id": creds.secret_id,
    }
    last_error = ""
    for _ in range(3):
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                resp = await client.post(f"{settings.beeai_url}/spawn", json=payload)
            if resp.status_code == 200:
                data = resp.json()
                provisioning.provision_agent_collections(data["agent_id"])
                await storage.registry_upsert(
                    data["agent_id"],
                    {
                        "agent_id": data["agent_id"],
                        "class": body.agent_class,
                        "status": "active",
                        "spawned_by": auth.agent_id,
                        "human_session_id": human_session_id,
                        "parent_agent_id": auth.agent_id,
                        "spawn_depth": str(auth.spawn_depth + 1),
                        "root_orchestrator_id": auth.root_orchestrator_id,
                        "vault_token_accessor": creds.token_accessor,
                    },
                )
                return data
            last_error = resp.text
        except Exception as exc:  # noqa: BLE001
            last_error = str(exc)
    raise HTTPException(status_code=503, detail=f"Spawn failed after retries: {last_error}")


@app.post("/tools/memory/{key:path}")
async def post_memory(
    key: str,
    body: MemoryWriteRequest,
    auth: AuthContext = Depends(require_auth_context),
) -> dict[str, str]:
    full_key = _validate_memory_key(auth.agent_id, key)
    await storage.set_value(full_key, body.value, body.ttl_seconds)
    return {"status": "ok", "key": full_key}


@app.post("/tools/scratch/{key:path}")
async def post_scratch(
    key: str,
    body: MemoryWriteRequest,
    auth: AuthContext = Depends(require_auth_context),
) -> dict[str, str]:
    full_key = _scratch_key(auth.agent_id, key)
    # Scratchpad is private and always short-lived by policy.
    ttl = body.ttl_seconds if body.ttl_seconds is not None else 3600
    await storage.set_value(full_key, body.value, ttl)
    return {"status": "ok", "key": full_key}


@app.get("/tools/scratch/{key:path}")
async def get_scratch(key: str, auth: AuthContext = Depends(require_auth_context)) -> dict[str, str | None]:
    full_key = _scratch_key(auth.agent_id, key)
    value = await storage.get_value(full_key)
    return {"key": full_key, "value": value}


@app.delete("/tools/scratch/{key:path}")
async def delete_scratch(key: str, auth: AuthContext = Depends(require_auth_context)) -> dict[str, str]:
    full_key = _scratch_key(auth.agent_id, key)
    await storage.delete_value(full_key)
    return {"status": "deleted", "key": full_key}


@app.get("/tools/memory/{key:path}")
async def get_memory(key: str, auth: AuthContext = Depends(require_auth_context)) -> dict[str, str | None]:
    full_key = _validate_memory_key(auth.agent_id, key)
    value = await storage.get_value(full_key)
    return {"key": full_key, "value": value}


@app.delete("/tools/memory/{key:path}")
async def delete_memory(key: str, auth: AuthContext = Depends(require_auth_context)) -> dict[str, str]:
    full_key = _validate_memory_key(auth.agent_id, key)
    await storage.delete_value(full_key)
    return {"status": "deleted", "key": full_key}


@app.get("/tools/registry")
async def get_registry(_: AuthContext = Depends(require_auth_context)) -> dict:
    agents = await storage.registry_list()
    return {"agents": agents}


@app.post("/tools/fetch", response_model=FetchResponse)
async def fetch_url(body: FetchRequest, _: AuthContext = Depends(require_auth_context)) -> FetchResponse:
    _validate_fetch_url(body.url)
    method = body.method.upper()
    if method not in {"GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"}:
        raise HTTPException(status_code=400, detail="Unsupported HTTP method")

    if settings.fetch_require_proxy and not settings.fetch_proxy_url:
        raise HTTPException(status_code=503, detail="Fetch proxy is required but not configured")

    req_headers = dict(body.headers)

    try:
        async with _build_fetch_client() as client:
            resp = await client.request(
                method=method,
                url=body.url,
                headers=req_headers,
                content=body.body,
            )
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"Fetch failed: {exc}") from exc

    return FetchResponse(
        status=resp.status_code,
        body=resp.text,
        content_type=resp.headers.get("content-type", "application/octet-stream"),
    )


@app.post("/tools/handoff")
async def write_handoff(body: HandoffRequest, auth: AuthContext = Depends(require_auth_context)) -> dict[str, str]:
    if body.from_agent_id != auth.agent_id:
        raise HTTPException(status_code=403, detail="from_agent_id must match authenticated agent")

    handoff = {
        "from_agent_id": body.from_agent_id,
        "to_agent_class": body.to_agent_class,
        "task_context": body.task_context,
        "artifacts": [a.model_dump() for a in body.artifacts],
        "memory_keys": body.memory_keys,
        "reasoning_summary": body.reasoning_summary,
        "priority": body.priority,
        "human_session_id": auth.human_session_id,
        "created_at": storage.utc_now_iso(),
    }

    await storage.write_handoff(body.from_agent_id, handoff)

    if not settings.use_inmemory:
        try:
            client = provisioning._mongo_client()
            db = client[f"agent_{body.from_agent_id}"]
            db["handoffs"].insert_one(handoff)
        except Exception as exc:  # noqa: BLE001
            raise HTTPException(status_code=503, detail=f"Mongo handoff write failed: {exc}") from exc

    return {"status": "ok", "key": f"registry:handoff:{body.from_agent_id}"}


@app.post("/tools/summarize", response_model=SummarizeResponse)
async def summarize(body: SummarizeRequest, _: AuthContext = Depends(require_auth_context)) -> SummarizeResponse:
    summary: str
    key_points: list[str]

    if settings.summarize_mode == "ollama":
        try:
            summary, key_points = await _summarize_with_ollama(body.content, body.max_tokens, body.format)
        except Exception:  # noqa: BLE001
            summary, key_points = _extractive_summary(body.content, body.max_tokens)
    else:
        summary, key_points = _extractive_summary(body.content, body.max_tokens)

    if body.format == "bullets":
        summary_text = "\n".join(f"- {point}" for point in key_points)
    elif body.format == "structured":
        summary_text = "\n".join(f"point_{idx+1}: {point}" for idx, point in enumerate(key_points))
    else:
        summary_text = summary

    return SummarizeResponse(summary=summary_text, key_points=key_points)


@app.post("/tools/encrypt", response_model=TransitEncryptResponse)
async def encrypt(body: TransitEncryptRequest, _: AuthContext = Depends(require_auth_context)) -> TransitEncryptResponse:
    ciphertext = await _transit_encrypt(body.plaintext, body.key)
    if not ciphertext:
        raise HTTPException(status_code=502, detail="Transit encrypt response missing ciphertext")
    return TransitEncryptResponse(ciphertext=ciphertext)


@app.post("/tools/decrypt", response_model=TransitDecryptResponse)
async def decrypt(body: TransitDecryptRequest, _: AuthContext = Depends(require_auth_context)) -> TransitDecryptResponse:
    plaintext = await _transit_decrypt(body.ciphertext, body.key)
    if not plaintext:
        raise HTTPException(status_code=502, detail="Transit decrypt response missing plaintext")
    return TransitDecryptResponse(plaintext=plaintext)


@app.post("/tools/search", response_model=SearchResponse)
async def search(body: SearchRequest, _: AuthContext = Depends(require_auth_context)) -> SearchResponse:
    if settings.use_inmemory:
        return SearchResponse(results=[])

    corpus = body.corpus or settings.search_default_corpus
    db_name, coll_name = _parse_corpus(corpus)
    query = body.query.strip()

    try:
        client = provisioning._mongo_client()
        coll = client[db_name][coll_name]
        docs = list(coll.find({}, {"_id": 1, "summary": 1, "content": 1, "text": 1}).limit(200))
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=503, detail=f"Search backend unavailable: {exc}") from exc

    q = query.lower()
    ranked: list[SearchResult] = []
    for doc in docs:
        text = str(doc.get("summary") or doc.get("content") or doc.get("text") or "")
        if not text:
            continue
        score = float(text.lower().count(q))
        if score <= 0:
            continue
        ranked.append(
            SearchResult(
                id=str(doc.get("_id")),
                score=score,
                summary=text[:240],
                source=f"{db_name}.{coll_name}",
            )
        )

    ranked.sort(key=lambda r: r.score, reverse=True)
    return SearchResponse(results=ranked[: body.top_k])


@app.post("/orchestrate", response_model=OrchestrateResponse)
async def orchestrate(body: OrchestrateRequest, auth: AuthContext = Depends(require_auth_context)) -> OrchestrateResponse:
    if auth.agent_class != "orchestrator":
        raise HTTPException(status_code=403, detail="Only orchestrator can orchestrate")

    workflow_id = f"wf-{uuid4().hex[:12]}"
    target_class = body.preferred_agent_class or "rag"

    if target_class == "orchestrator":
        return OrchestrateResponse(
            workflow_id=workflow_id,
            status="completed",
            spawned_agent_id=None,
            result_summary="Handled by orchestrator without delegation.",
        )

    effective_auth = auth
    if body.human_session_id != auth.human_session_id:
        effective_auth = replace(auth, human_session_id=body.human_session_id)

    spawn_result = await _spawn_with_auth(
        SpawnRequest(
            agent_class=target_class,
            task_context=body.request_text,
            memory_keys=[f"shared:memory:workflow:{workflow_id}"],
        ),
        effective_auth,
    )

    return OrchestrateResponse(
        workflow_id=workflow_id,
        status="accepted",
        spawned_agent_id=spawn_result.get("agent_id"),
        result_summary=f"Delegated request to {target_class} agent.",
    )


@app.post("/tools/spawn")
async def spawn_agent(body: SpawnRequest, auth: AuthContext = Depends(require_auth_context)) -> dict:
    return await _spawn_with_auth(body, auth)


@app.delete("/tools/spawn/{agent_id}")
async def delete_spawn(agent_id: str, auth: AuthContext = Depends(require_auth_context)) -> dict:
    if auth.agent_class != "orchestrator":
        raise HTTPException(status_code=403, detail="Only orchestrator can terminate")

    record = await storage.registry_get_record(agent_id)
    if not record:
        return {"agent_id": agent_id, "status": "not_found"}

    owner_root = record.get("root_orchestrator_id")
    if owner_root and owner_root != auth.root_orchestrator_id:
        raise HTTPException(status_code=403, detail="Agent is outside caller spawn tree")

    payload = {
        "agent_id": agent_id,
        "requestor_agent_id": auth.agent_id,
        "human_session_id": auth.human_session_id,
        "root_orchestrator_id": auth.root_orchestrator_id,
    }
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.post(f"{settings.beeai_url}/terminate", json=payload)
    if resp.status_code != 200:
        raise HTTPException(status_code=502, detail="BeeAI terminate failed")

    accessor = record.get("vault_token_accessor")
    if accessor:
        await provisioning.revoke_accessor(accessor)

    await storage.registry_delete(agent_id)
    return {"agent_id": agent_id, "status": "terminated"}
