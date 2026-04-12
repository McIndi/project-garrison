import os


class Settings:
    beeai_url = os.getenv("TOOL_SERVER_BEEAI_URL", "http://localhost:8090")
    valkey_url = os.getenv("TOOL_SERVER_VALKEY_URL", "redis://localhost:6379/0")
    mongo_uri = os.getenv("TOOL_SERVER_MONGO_URI", "mongodb://root:rootpass@mongo:27017")
    vault_addr = os.getenv("TOOL_SERVER_VAULT_ADDR", "http://localhost:8200")
    vault_token = os.getenv("TOOL_SERVER_VAULT_TOKEN", "root")
    require_token_lookup = os.getenv("TOOL_SERVER_REQUIRE_TOKEN_LOOKUP", "false").lower() == "true"
    spawn_max_depth = int(os.getenv("TOOL_SERVER_SPAWN_MAX_DEPTH", "2"))
    use_inmemory = os.getenv("TOOL_SERVER_INMEMORY", "false").lower() == "true"
    class_token_ttl = {
        "orchestrator": "4h",
        "code": "2h",
        "rag": "1h",
        "analyst": "1h",
    }


settings = Settings()
