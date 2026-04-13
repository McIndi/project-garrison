from pydantic import BaseModel, Field, field_validator


class MemoryWriteRequest(BaseModel):
    value: str
    ttl_seconds: int | None = None


class SpawnRequest(BaseModel):
    agent_class: str = Field(min_length=1)
    task_context: str = Field(min_length=1)
    memory_keys: list[str] = Field(default_factory=list)


class OrchestrateRequest(BaseModel):
    request_text: str = Field(min_length=1)
    human_session_id: str = Field(min_length=1)
    preferred_agent_class: str | None = Field(default=None, pattern="^(orchestrator|code|rag|analyst)$")


class OrchestrateResponse(BaseModel):
    workflow_id: str
    status: str = Field(pattern="^(accepted|completed|failed)$")
    spawned_agent_id: str | None = None
    result_summary: str


class SpawnResponse(BaseModel):
    agent_id: str
    status: str
    error: str | None = None


class FetchRequest(BaseModel):
    url: str = Field(min_length=1)
    method: str = "GET"
    headers: dict[str, str] = Field(default_factory=dict)
    body: str | None = None


class FetchResponse(BaseModel):
    status: int
    body: str
    content_type: str


class HandoffArtifact(BaseModel):
    type: str = Field(min_length=1)
    ref: str = Field(min_length=1)


class HandoffRequest(BaseModel):
    from_agent_id: str = Field(min_length=1)
    to_agent_class: str = Field(min_length=1)
    task_context: str = Field(min_length=1)
    artifacts: list[HandoffArtifact] = Field(default_factory=list)
    memory_keys: list[str] = Field(default_factory=list)
    reasoning_summary: str = Field(min_length=1)
    priority: str = Field(pattern="^(low|normal|high)$")


class SummarizeRequest(BaseModel):
    content: str = Field(min_length=1)
    max_tokens: int = Field(default=256, ge=16, le=4096)
    format: str = Field(default="bullets", pattern="^(bullets|prose|structured)$")


class SummarizeResponse(BaseModel):
    summary: str
    key_points: list[str]


class TransitEncryptRequest(BaseModel):
    plaintext: str = Field(min_length=1)
    key: str = Field(pattern="^(agent-payload|shared-memory)$")


class TransitEncryptResponse(BaseModel):
    ciphertext: str


class TransitDecryptRequest(BaseModel):
    ciphertext: str = Field(min_length=1)
    key: str = Field(pattern="^(agent-payload|shared-memory)$")


class TransitDecryptResponse(BaseModel):
    plaintext: str


class SearchRequest(BaseModel):
    query: str = Field(min_length=1)
    corpus: str = Field(default="shared_artifacts.objects", min_length=1)
    top_k: int = Field(default=5, ge=1, le=50)

    @field_validator("query")
    @classmethod
    def query_cannot_be_whitespace(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("query cannot be blank or whitespace-only")
        return value


class SearchResult(BaseModel):
    id: str
    score: float
    summary: str
    source: str


class SearchResponse(BaseModel):
    results: list[SearchResult]
