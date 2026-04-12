import json
from collections.abc import Mapping

from redis.asyncio import Redis

from .config import settings


class Storage:
    def __init__(self) -> None:
        self._redis: Redis | None = None
        self._mem_kv: dict[str, str] = {}
        self._mem_registry: dict[str, str] = {}

    async def connect(self) -> None:
        if settings.use_inmemory:
            return
        self._redis = Redis.from_url(settings.valkey_url, decode_responses=True)

    async def close(self) -> None:
        if self._redis is not None:
            await self._redis.close()

    async def set_value(self, key: str, value: str, ttl_seconds: int | None = None) -> None:
        if settings.use_inmemory:
            self._mem_kv[key] = value
            return
        if ttl_seconds:
            await self._redis.setex(key, ttl_seconds, value)
        else:
            await self._redis.set(key, value)

    async def get_value(self, key: str) -> str | None:
        if settings.use_inmemory:
            return self._mem_kv.get(key)
        return await self._redis.get(key)

    async def delete_value(self, key: str) -> None:
        if settings.use_inmemory:
            self._mem_kv.pop(key, None)
            return
        await self._redis.delete(key)

    async def registry_upsert(self, agent_id: str, payload: Mapping[str, str]) -> None:
        value = json.dumps(dict(payload))
        if settings.use_inmemory:
            self._mem_registry[agent_id] = value
            return
        await self._redis.hset("registry:agents", agent_id, value)

    async def registry_get(self, agent_id: str) -> str | None:
        if settings.use_inmemory:
            return self._mem_registry.get(agent_id)
        return await self._redis.hget("registry:agents", agent_id)

    async def registry_delete(self, agent_id: str) -> None:
        if settings.use_inmemory:
            self._mem_registry.pop(agent_id, None)
            return
        await self._redis.hdel("registry:agents", agent_id)


storage = Storage()
