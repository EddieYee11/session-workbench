"""Native Garmin connector; preserves old garth tokens and stores new auth separately.

argv: domain [YYYY-MM-DD ...]（不给日期就只取今天）。每天一条：活动/心率/压力/身体电量（summary）、睡眠、HRV、训练准备度、
身体电量曲线（压力接口里的 3 分钟序列，降到 15 分钟一点）。每一项单独 try，缺哪项写进 missing，不拖累其余项。
10-17 健康页补：呼吸、血氧、睡眠需求 / 睡眠压力、体能年龄、训练状态与急慢性负荷、当天的活动（GitHub cyberjunky/python-garminconnect 现成接口）。
version=2 标记新字段齐了，旧记录会被分批补抓。
"""
import sys,json,sqlite3
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo
from garminconnect import Garmin
TZ=ZoneInfo('Asia/Shanghai')
state=Path.home()/'.session-workbench'
with sqlite3.connect(state/'personal-hub.sqlite') as db:
 row=db.execute('SELECT data FROM connector_config WHERE name=?',('garmin',)).fetchone()
cfg=json.loads(row[0]) if row else {}
SUMMARY={'steps':'totalSteps','step_goal':'dailyStepGoal','resting_heart_rate':'restingHeartRate','resting_heart_rate_7d':'lastSevenDaysAvgRestingHeartRate',
 'calories':'totalKilocalories','active_calories':'activeKilocalories','distance_meters':'totalDistanceMeters','floors':'floorsAscended',
 'avg_stress':'averageStressLevel','max_stress':'maxStressLevel','body_battery':'bodyBatteryMostRecentValue','body_battery_high':'bodyBatteryHighestValue',
 'body_battery_low':'bodyBatteryLowestValue','body_battery_charged':'bodyBatteryChargedValue','body_battery_drained':'bodyBatteryDrainedValue','body_battery_at_wake':'bodyBatteryAtWakeTime'}
def local(ms):return datetime.fromtimestamp(ms/1000,TZ).isoformat(timespec='minutes') if ms else None
def day(client,date):
 m,missing,curve={},[],[]
 def part(name,fn):
  try:fn()
  except Exception:missing.append(name)
 def summary():
  s=client.get_user_summary(date)
  m.update({k:s.get(v) for k,v in SUMMARY.items()})
  if s.get('moderateIntensityMinutes') is not None:m['intensity_minutes']=(s.get('moderateIntensityMinutes') or 0)+2*(s.get('vigorousIntensityMinutes') or 0)
 def sleep():
  d=(client.get_sleep_data(date) or {}).get('dailySleepDTO') or {}
  if not d.get('sleepTimeSeconds'):raise ValueError('no sleep')
  m.update(sleep_seconds=d.get('sleepTimeSeconds'),sleep_score=((d.get('sleepScores') or {}).get('overall') or {}).get('value'),
   deep_seconds=d.get('deepSleepSeconds'),light_seconds=d.get('lightSleepSeconds'),rem_seconds=d.get('remSleepSeconds'),awake_seconds=d.get('awakeSleepSeconds'),
   sleep_start=local(d.get('sleepStartTimestampGMT')),sleep_end=local(d.get('sleepEndTimestampGMT')),sleep_heart_rate=d.get('avgHeartRate'),
   sleep_stress=d.get('avgSleepStress'),sleep_need_minutes=(d.get('sleepNeed') or {}).get('actual'),sleep_feedback=d.get('sleepScoreFeedback'))
 def hrv():
  h=(client.get_hrv_data(date) or {}).get('hrvSummary') or {}
  if not h:raise ValueError('no hrv')
  m.update(hrv_last_night=h.get('lastNightAvg'),hrv_weekly=h.get('weeklyAvg'),hrv_status=h.get('status'),
   hrv_baseline=[(h.get('baseline') or {}).get('balancedLow'),(h.get('baseline') or {}).get('balancedUpper')])
 def readiness():
  r=client.get_training_readiness(date)
  r=r[0] if isinstance(r,list) and r else r
  if not r:raise ValueError('no readiness')
  m.update(readiness_score=r.get('score'),readiness_level=r.get('level'),recovery_minutes=r.get('recoveryTime'))
 def battery():
  values=(client.get_stress_data(date) or {}).get('bodyBatteryValuesArray') or []
  last=None
  for v in values:
   if len(v)<3 or v[2] is None:continue
   if last is None or v[0]-last>=15*60*1000:curve.append([int(v[0]/1000),v[2]]);last=v[0]
 def breath():
  r=client.get_respiration_data(date) or {}
  m.update(respiration_waking=r.get('avgWakingRespirationValue'),respiration_sleep=r.get('avgSleepRespirationValue'))
 def spo2():
  r=client.get_spo2_data(date) or {}
  m.update(spo2_avg=r.get('averageSpO2') or r.get('avgSleepSpO2'),spo2_low=r.get('lowestSpO2'),spo2_7d=r.get('lastSevenDaysAvgSpO2'))
 def fitness():
  r=client.get_fitnessage_data(date) or {}
  if r.get('fitnessAge'):m.update(fitness_age=round(r['fitnessAge'],1),age=r.get('chronologicalAge'),fitness_age_target=round(r.get('achievableFitnessAge') or 0,1) or None)
 def training():
  r=client.get_training_status(date) or {}
  latest=((r.get('mostRecentTrainingStatus') or {}).get('latestTrainingStatusData') or {})
  t=next(iter(latest.values()),{}) if isinstance(latest,dict) else {}
  load=t.get('acuteTrainingLoadDTO') or {}
  vo2=((r.get('mostRecentVO2Max') or {}).get('generic') or {})
  m.update(training_status=t.get('trainingStatusFeedbackPhrase') or t.get('trainingStatus'),load_acute=load.get('dailyTrainingLoadAcute'),
   load_chronic=load.get('dailyTrainingLoadChronic'),load_ratio=load.get('dailyAcuteChronicWorkloadRatio'),load_ratio_status=load.get('acwrStatus'),
   vo2max=vo2.get('vo2MaxPreciseValue') or vo2.get('vo2MaxValue'))
 def activities():
  for a in client.get_activities_by_date(date,date) or []:
   acts.append({'name':a.get('activityName'),'type':(a.get('activityType') or {}).get('typeKey'),'start':(a.get('startTimeLocal') or '')[11:16],
    'minutes':round((a.get('duration') or 0)/60),'calories':a.get('calories'),'avg_hr':a.get('averageHR'),'max_hr':a.get('maxHR'),
    'aerobic_te':round(a.get('aerobicTrainingEffect') or 0,1),'anaerobic_te':round(a.get('anaerobicTrainingEffect') or 0,1),'load':a.get('activityTrainingLoad')})
 acts=[]
 for name,fn in (('summary',summary),('sleep',sleep),('hrv',hrv),('readiness',readiness),('body_battery_curve',battery),
                 ('respiration',breath),('spo2',spo2),('fitness_age',fitness),('training_status',training),('activities',activities)):part(name,fn)
 return {'date':date,'version':2,'measurements':{k:v for k,v in m.items() if v is not None},'body_battery_curve':curve,'activities':acts,'missing':missing}
client=Garmin(cfg.get('username'),cfg.get('password'),is_cn=(cfg.get('domain',sys.argv[1])=='garmin.cn'),return_on_mfa=True)
store=state/'garmin-session'
try:
 status=client.login(str(store) if store.exists() else None) if cfg.get('username') and cfg.get('password') else client.login(str(store if store.exists() else Path.home()/'.garth/session.json'))
 if status[0]:raise RuntimeError('Garmin requires a new MFA login')
 store.mkdir(parents=True,exist_ok=True,mode=0o700)
 client.client.dump(str(store))
 dates=sys.argv[2:] or [datetime.now(TZ).date().isoformat()]
 print(json.dumps({'source':'Garmin Connect','domain':cfg.get('domain',sys.argv[1]),'days':[day(client,d) for d in dates]},ensure_ascii=False))
except Exception as error:
 print(json.dumps({'error':{'code':'garmin_authorization_required','type':type(error).__name__,'reason':'Existing Garmin session cannot be reused; native login or MFA required'}}))
