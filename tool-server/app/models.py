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
