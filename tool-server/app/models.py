from pydantic import BaseModel, Field


class MemoryWriteRequest(BaseModel):
    value: str
    ttl_seconds: int | None = None


class SpawnRequest(BaseModel):
    agent_class: str = Field(min_length=1)
    task_context: str = Field(min_length=1)
    memory_keys: list[str] = Field(default_factory=list)


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
