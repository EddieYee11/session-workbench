"""mini-only Hindsight launcher; uses Magpie for LLM and Google Vertex for gemini-embedding-2."""
import os
from pathlib import Path

home = Path.home()
for k in ('ALL_PROXY', 'all_proxy'):
    os.environ.pop(k, None)

os.environ.update({
    'GOOGLE_APPLICATION_CREDENTIALS': str(home / '.config/gcloud/legacy_credentials/eddiegao948@gmail.com/adc.json'),
    'GOOGLE_CLOUD_PROJECT': 'project-816c0481-813e-4353-ab7',
    'HINDSIGHT_API_LLM_PROVIDER': 'openai',
    'HINDSIGHT_API_LLM_BASE_URL': 'http://127.0.0.1:3425/v1',
    'HINDSIGHT_API_LLM_API_KEY': 'magpie-local',
    'HINDSIGHT_API_LLM_MODEL': 'group/ds-flash-credits',
    'HINDSIGHT_API_DATABASE_URL': 'pg0://com-memory',
    'HINDSIGHT_API_EMBEDDINGS_PROVIDER': 'google',
    'HINDSIGHT_API_EMBEDDINGS_GEMINI_MODEL': 'gemini-embedding-2',
    'HINDSIGHT_API_EMBEDDINGS_GEMINI_OUTPUT_DIMENSIONALITY': '768',
    'HINDSIGHT_API_EMBEDDINGS_VERTEXAI_PROJECT_ID': 'project-816c0481-813e-4353-ab7',
    'HINDSIGHT_API_EMBEDDINGS_VERTEXAI_REGION': 'global',
    'HINDSIGHT_API_RERANKER_PROVIDER': 'google',
    'HINDSIGHT_API_RERANKER_GOOGLE_PROJECT_ID': 'project-816c0481-813e-4353-ab7',
    'HINDSIGHT_API_RERANKER_GOOGLE_MODEL': 'semantic-ranker-default-004',
    'HINDSIGHT_API_RERANKER_MAX_CANDIDATES': '50',
    'HINDSIGHT_API_LLM_MAX_CONCURRENT': '2',
    'HINDSIGHT_API_ENABLE_AUTO_CONSOLIDATION': 'false',
    'HINDSIGHT_API_RETAIN_MAX_COMPLETION_TOKENS': '16000',
    'HINDSIGHT_API_LOG_LEVEL': 'warning',
    'HF_HUB_OFFLINE': '1',
    'HF_HUB_DISABLE_TELEMETRY': '1',
    'HF_HUB_DISABLE_PROGRESS_BARS': '1',
    'TOKENIZERS_PARALLELISM': 'false',
    'HTTP_PROXY': 'http://127.0.0.1:7897',
    'HTTPS_PROXY': 'http://127.0.0.1:7897',
    'NO_PROXY': '127.0.0.1,localhost',
    'http_proxy': 'http://127.0.0.1:7897',
    'https_proxy': 'http://127.0.0.1:7897',
    'no_proxy': '127.0.0.1,localhost',
})
# Model cache/embedded DB stay private and outside Syncthing.
os.execv(str(home / '.com-memory/venv/bin/hindsight-api'), ['hindsight-api', '--host', '127.0.0.1', '--port', '8888'])
