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
    summarize_mode = os.getenv("TOOL_SERVER_SUMMARIZE_MODE", "extractive")
    summarize_model = os.getenv("TOOL_SERVER_SUMMARIZE_MODEL", "phi3:mini")
    ollama_url = os.getenv("TOOL_SERVER_OLLAMA_URL", "http://ollama:11434")
    search_default_corpus = os.getenv("TOOL_SERVER_SEARCH_DEFAULT_CORPUS", "shared_artifacts.objects")
    audit_payload_mode = os.getenv("GARRISON_AUDIT_PAYLOAD_MODE", "full")
    class_token_ttl = {
        "orchestrator": "4h",
        "code": "2h",
        "rag": "1h",
        "analyst": "1h",
    }


settings = Settings()
