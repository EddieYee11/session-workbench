"""Live retain/replacement/delete acceptance in a disposable bank."""
import asyncio
import json
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from memory import request

async def run():
    bank='com-memory-acceptance';doc='acceptance-document'
    try:
        await request('POST',bank,'/memories',{'items':[{'content':'The indicator light on device M0 is green.','document_id':doc}], 'async':False},timeout=120)
        original=await request('GET',bank,'/documents/'+doc)
        await request('DELETE',bank,'/documents/'+doc,timeout=60)
        await request('POST',bank,'/memories',{'items':[{'content':'The indicator light on device M0 is blue.','document_id':doc}], 'async':False},timeout=120)
        updated=await request('GET',bank,'/documents/'+doc)
        data=await request('POST',bank,'/memories/recall',{'query':'What color is the indicator light on device M0?','types':['world','experience'],'budget':'low'})
        texts='\n'.join(row['text'] for row in data.get('results',[]))
        assert ('blue' in texts.lower() or '蓝色' in texts) and 'green' not in texts.lower() and '绿色' not in texts, 'Replacement recall: ' + texts
        await request('DELETE',bank,'/documents/'+doc,timeout=60)
        stats=await request('GET',bank,'/stats')
        assert stats['total_documents']==0 and stats['total_nodes']==0, 'Document facts survived deletion'
        return {'ok':True,'replacement_removed_old_fact':True,'delete_removed_document_and_facts':True,'synthetic_probe_bank':bank}
    finally:
        await request('DELETE',bank,timeout=60)

if __name__=='__main__':print(json.dumps(asyncio.run(run()),ensure_ascii=False))
