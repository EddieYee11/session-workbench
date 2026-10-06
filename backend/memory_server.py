"""mini-only Hindsight launcher; reuse Pi's provider without copying its secret."""
import json
import os
from pathlib import Path

home = Path.home()
models = json.loads((home / '.pi/agent/models.json').read_text())['providers']
provider = models['zenmux']
auth = json.loads((home / '.pi/agent/auth.json').read_text())['zenmux']
if auth.get('type') != 'api_key':
    raise RuntimeError('Pi zenmux API key unavailable')
key = auth.get('key') or auth.get('apiKey')
if not key:
    raise RuntimeError('Pi zenmux API key unavailable')
os.environ.update({
    'HINDSIGHT_API_LLM_PROVIDER': 'openai',
    'HINDSIGHT_API_LLM_BASE_URL': provider['baseUrl'],
    'HINDSIGHT_API_LLM_API_KEY': key,
    'HINDSIGHT_API_LLM_MODEL': provider['models'][0]['id'],
    'HINDSIGHT_API_DATABASE_URL': 'pg0://com-memory',
    'HINDSIGHT_API_EMBEDDINGS_PROVIDER': 'local',
    'HINDSIGHT_API_EMBEDDINGS_LOCAL_MODEL': 'intfloat/multilingual-e5-small',
    'HINDSIGHT_API_EMBEDDINGS_LOCAL_FORCE_CPU': 'true',
    'HINDSIGHT_API_EMBEDDINGS_QUERY_PREFIX': 'query: ',
    'HINDSIGHT_API_EMBEDDINGS_PASSAGE_PREFIX': 'passage: ',
    'HINDSIGHT_API_RERANKER_PROVIDER': 'local',
    'HINDSIGHT_API_RERANKER_LOCAL_MODEL': 'cross-encoder/mmarco-mMiniLMv2-L12-H384-v1',
    'HINDSIGHT_API_RERANKER_LOCAL_FORCE_CPU': 'true',
    'HINDSIGHT_API_LLM_MAX_CONCURRENT': '2',
    'HINDSIGHT_API_ENABLE_AUTO_CONSOLIDATION': 'false',
    'HINDSIGHT_API_RETAIN_MAX_COMPLETION_TOKENS': '16000',
    'HINDSIGHT_API_LOG_LEVEL': 'warning',
    'HF_HUB_DISABLE_PROGRESS_BARS': '1',
    'TOKENIZERS_PARALLELISM': 'false',
})
# Model cache/embedded DB stay private and outside Syncthing.
os.execv(str(home / '.com-memory/venv/bin/hindsight-api'), ['hindsight-api', '--host', '127.0.0.1', '--port', '8888'])
