import os


class Settings:
    beeai_url = os.getenv("TOOL_SERVER_BEEAI_URL", "http://localhost:8090")
    valkey_url = os.getenv("TOOL_SERVER_VALKEY_URL", "redis://localhost:6379/0")
    mongo_uri = os.getenv("TOOL_SERVER_MONGO_URI", "mongodb://root:rootpass@mongo:27017")
    vault_addr = os.getenv("TOOL_SERVER_VAULT_ADDR", "http://localhost:8200")
    vault_token = os.getenv("TOOL_SERVER_VAULT_TOKEN", "")
    require_token_lookup = os.getenv("TOOL_SERVER_REQUIRE_TOKEN_LOOKUP", "false").lower() == "true"
    enforce_token_identity_binding = os.getenv("TOOL_SERVER_ENFORCE_TOKEN_IDENTITY_BINDING", "true").lower() == "true"
    require_token_metadata_contract = os.getenv("TOOL_SERVER_REQUIRE_TOKEN_METADATA_CONTRACT", "true").lower() == "true"
    allow_header_identity_fallback = os.getenv("TOOL_SERVER_ALLOW_HEADER_IDENTITY_FALLBACK", "false").lower() == "true"
    allow_root_token_fallback = os.getenv("TOOL_SERVER_ALLOW_ROOT_TOKEN_FALLBACK", "false").lower() == "true"
    spawn_max_depth = int(os.getenv("TOOL_SERVER_SPAWN_MAX_DEPTH", "2"))
    use_inmemory = os.getenv("TOOL_SERVER_INMEMORY", "false").lower() == "true"
    summarize_mode = os.getenv("TOOL_SERVER_SUMMARIZE_MODE", "extractive")
    summarize_model = os.getenv("TOOL_SERVER_SUMMARIZE_MODEL", "phi3:mini")
    ollama_url = os.getenv("TOOL_SERVER_OLLAMA_URL", "http://ollama:11434")
    search_default_corpus = os.getenv("TOOL_SERVER_SEARCH_DEFAULT_CORPUS", "shared_artifacts.objects")
    search_allowed_corpora = {
        item.strip()
        for item in os.getenv("TOOL_SERVER_SEARCH_ALLOWED_CORPORA", "shared_artifacts.objects").split(",")
        if item.strip()
    }
    fetch_proxy_url = os.getenv("TOOL_SERVER_FETCH_PROXY_URL", "")
    fetch_require_proxy = os.getenv("TOOL_SERVER_FETCH_REQUIRE_PROXY", "true").lower() == "true"
    audit_payload_mode = os.getenv("GARRISON_AUDIT_PAYLOAD_MODE", "full")
    audit_ingest_token = os.getenv("TOOL_SERVER_AUDIT_INGEST_TOKEN", "")
    otel_enabled = os.getenv("TOOL_SERVER_OTEL_ENABLED", "true").lower() == "true"
    otel_logs_endpoint = os.getenv("TOOL_SERVER_OTEL_LOGS_ENDPOINT", "http://otel-collector:4318/v1/logs")
    otel_timeout_ms = int(os.getenv("TOOL_SERVER_OTEL_TIMEOUT_MS", "2000"))
    class_token_ttl = {
        "orchestrator": "4h",
        "code": "2h",
        "rag": "1h",
        "analyst": "1h",
    }


settings = Settings()
