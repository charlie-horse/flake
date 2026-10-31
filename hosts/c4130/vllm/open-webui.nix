# Open WebUI: chat front-end for the model vllm.service serves.
# Reach it at http://c4130:8082 over the tailnet; the first account to sign
# up becomes admin, later sign-ups wait for the admin's approval.
{ config, ... }:
let
  vllm = config.services.vllm-sm70;
  # 8080/8081 are LMCache's admin API and dashboard.
  port = 8082;
in
{
  services.open-webui = {
    enable = true;
    # One address only: bind all, and open the port on tailscale0 alone
    # (loopback is always allowed; eno1 stays closed).
    host = "0.0.0.0";
    inherit port;
    # Setting `environment` replaces the module's defaults, so the
    # telemetry switches are repeated here.
    environment = {
      SCARF_NO_ANALYTICS = "True";
      DO_NOT_TRACK = "True";
      ANONYMIZED_TELEMETRY = "False";
      ENABLE_VERSION_UPDATE_CHECK = "False";

      WEBUI_URL = "http://c4130:${toString port}";
      WEBUI_AUTH = "True";

      # vLLM's OpenAI-compatible API (no key; any value works). Models come
      # from its /v1/models, so the served name follows activeModel.
      ENABLE_OLLAMA_API = "False";
      ENABLE_OPENAI_API = "True";
      OPENAI_API_BASE_URL = "http://127.0.0.1:${toString vllm.port}/v1";
      OPENAI_API_KEY = "none";

      # No local embedding/RAG models: nothing is downloaded or loaded into
      # RAM (c4130 has ~12 GB headroom next to vLLM + LMCache). Attached
      # documents go to the model whole instead of through retrieval.
      OFFLINE_MODE = "True";
      HF_HUB_OFFLINE = "1";
      BYPASS_EMBEDDING_AND_RETRIEVAL = "True";
      RAG_EMBEDDING_ENGINE = "openai";
      RAG_EMBEDDING_MODEL_AUTO_UPDATE = "False";
      RAG_RERANKING_MODEL_AUTO_UPDATE = "False";
      WHISPER_MODEL_AUTO_UPDATE = "False";
    };
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ port ];
}
