"""Native Garmin connector; preserves old garth tokens and stores new auth separately."""
import sys,json,sqlite3
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo
from garminconnect import Garmin
state=Path.home()/'.session-workbench'
with sqlite3.connect(state/'personal-hub.sqlite') as db:
 row=db.execute('SELECT data FROM connector_config WHERE name=?',('garmin',)).fetchone()
cfg=json.loads(row[0]) if row else {}
client=Garmin(cfg.get('username'),cfg.get('password'),is_cn=(cfg.get('domain',sys.argv[1])=='garmin.cn'),return_on_mfa=True)
store=state/'garmin-session'
try:
 status=client.login(str(store) if store.exists() else None) if cfg.get('username') and cfg.get('password') else client.login(str(store if store.exists() else Path.home()/'.garth/session.json'))
 if status[0]:raise RuntimeError('Garmin requires a new MFA login')
 store.mkdir(parents=True,exist_ok=True,mode=0o700)
 client.client.dump(str(store))
 date=datetime.now(ZoneInfo('Asia/Shanghai')).date().isoformat();data=client.get_user_summary(date)
 fields={'steps':'totalSteps','resting_heart_rate':'restingHeartRate','calories':'totalKilocalories','distance_meters':'totalDistance','intensity_minutes':'totalIntensityMinutes'}
 print(json.dumps({'date':date,'source':'Garmin Connect','domain':cfg.get('domain',sys.argv[1]),'measurements':{k:data.get(v) for k,v in fields.items()},'missing':[k for k,v in fields.items() if data.get(v) is None]}))
except Exception as error:
 print(json.dumps({'error':{'code':'garmin_authorization_required','type':type(error).__name__,'reason':'Existing Garmin session cannot be reused; native login or MFA required'}}))
