import os


class Settings:
    beeai_url = os.getenv("TOOL_SERVER_BEEAI_URL", "http://localhost:8090")
    valkey_url = os.getenv("TOOL_SERVER_VALKEY_URL", "redis://localhost:6379/0")
    vault_addr = os.getenv("TOOL_SERVER_VAULT_ADDR", "http://localhost:8200")
    require_token_lookup = os.getenv("TOOL_SERVER_REQUIRE_TOKEN_LOOKUP", "false").lower() == "true"
    spawn_max_depth = int(os.getenv("TOOL_SERVER_SPAWN_MAX_DEPTH", "2"))
    use_inmemory = os.getenv("TOOL_SERVER_INMEMORY", "false").lower() == "true"


settings = Settings()
