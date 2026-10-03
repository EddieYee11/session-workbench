import json
import pytest
from gateway_integration.reminder_store import update

def test_stale_runner_cannot_overwrite_card_or_other_rows(tmp_path):
 path=tmp_path/'reminders.json';path.write_text(json.dumps([{'id':'a','due':'2099-01-01 12:00','status':'pending'}, {'id':'b','due':'2099-01-01 12:00','status':'pending'}]))
 update(path,[{'id':'a','expected':{'status':'pending'},'fields':{'status':'cancelled'}}])
 with pytest.raises(ValueError):update(path,[{'id':'a','expected':{'status':'pending','due':'2099-01-01 12:00'},'fields':{'status':'done'}}])
 update(path,[{'id':'b','expected':{'status':'pending'},'fields':{'status':'done'}}])
 rows=json.loads(path.read_text());assert rows[0]['status']=='cancelled' and rows[1]['status']=='done'
