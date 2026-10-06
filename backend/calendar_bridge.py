"""Read and adjust Apple Calendar through its existing TCC-authorized queue worker."""
import asyncio
import json
import sqlite3
from urllib.parse import quote
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

SCRIPT = '''
on dateFromIso(s)
 set d to current date
 set day of d to 1
 set year of d to (text 1 thru 4 of s) as integer
 set month of d to (text 6 thru 7 of s) as integer
 set day of d to (text 9 thru 10 of s) as integer
 set time of d to 0
 if (count s) > 10 then
  set hours of d to (text 12 thru 13 of s) as integer
  set minutes of d to (text 15 thru 16 of s) as integer
 end if
 return d
end dateFromIso
on iso(d)
 return ((year of d) as text) & "-" & text -2 thru -1 of ("0" & ((month of d) as integer)) & "-" & text -2 thru -1 of ("0" & (day of d)) & "T" & text -2 thru -1 of ("0" & (hours of d)) & ":" & text -2 thru -1 of ("0" & (minutes of d))
end iso
on clean(s)
 set s to s as text
 set AppleScript's text item delimiters to {tab, linefeed, return}
 set parts to text items of s
 set AppleScript's text item delimiters to " "
 set s to parts as text
 set AppleScript's text item delimiters to ""
 return s
end clean
on run argv
 set lo to my dateFromIso(item 2 of argv)
 set hi to my dateFromIso(item 3 of argv)
 set output to ""
 tell application "Calendar"
  repeat with c in calendars
   set candidates to {}
   if item 1 of argv is "get" or item 1 of argv is "adjust" or item 1 of argv is "delete_created" then
    set candidates to every event of c whose uid is item 4 of argv
   else
    set candidates to every event of c whose start date >= lo and start date < hi
   end if
   repeat with e in candidates
    if item 1 of argv is "delete_created" then
     if not writable of c or (count of attendees of e) > 0 then error "Cannot undo shared or read-only event"
     if (my iso(start date of e)) is not item 6 of argv then error "Event changed; refresh before undo"
     if description of e does not contain item 5 of argv then error "Missing Com creation receipt"
     delete e
     return "deleted"
    end if
    if item 1 of argv is "adjust" and (uid of e) is item 4 of argv then
     if not writable of c then error "Calendar is read-only"
     if (count of attendees of e) > 0 then error "Shared participant event requires explicit assignment"
     if (my iso(start date of e)) is not item 7 of argv then error "Calendar event changed; refresh"
     set targetStart to my dateFromIso(item 5 of argv)
     set targetEnd to my dateFromIso(item 6 of argv)
     if targetStart >= end date of e then
      set end date of e to targetEnd
      set start date of e to targetStart
     else
      set start date of e to targetStart
      set end date of e to targetEnd
     end if
    end if
    set p to properties of e
    set n to -1
    try
     set n to count of attendees of e
    end try
    set desc to ""
    try
     set desc to description of p as text
    end try
    set output to output & (uid of p) & tab & my clean(summary of p) & tab & my iso(start date of p) & tab & my iso(end date of p) & tab & my clean(name of c) & tab & n & tab & my clean(desc) & tab & (writable of c as text) & linefeed
   end repeat
  end repeat
 end tell
 return output
end run
'''


class CalendarBridge:
    def __init__(self, home=None): self.home = Path(home or Path.home())

    async def queue(self, argv):
        root = self.home / '.hermes/calendar_queue'
        (root / 'inbox').mkdir(parents=True, exist_ok=True)
        ident = 'com-' + uuid.uuid4().hex
        target = root / 'inbox' / (ident + '.json')
        tmp = target.with_suffix('.tmp')
        tmp.write_text(json.dumps({'script': SCRIPT, 'argv': argv}, ensure_ascii=False)); tmp.chmod(0o600); tmp.replace(target)
        output = root / 'outbox' / (ident + '.json')
        for _ in range(300):
            if output.exists():
                data = json.loads(output.read_text())
                if data.get('exit_code') != 0: raise RuntimeError('Apple Calendar worker rejected operation')
                return data.get('stdout', '')
            await asyncio.sleep(.2)
        raise RuntimeError('Calendar worker timed out; operation outcome requires readback')

    def parse(self, text):
        result = []
        for line in text.splitlines():
            fields = line.split('\t')
            if len(fields) != 8: continue
            ident, title, start, end, calendar, participants, description, writable = fields
            result.append({'id': ident, 'title': title, 'start': start + '+08:00', 'end': end + '+08:00',
                'calendar': calendar, 'attendee_count': int(participants), 'description': description,
                'editable': writable == 'true', 'source': 'Apple Calendar'})
        return result

    def cached(self,start_date,end_date):
        path=self.home/'Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb'
        if not path.exists():return None
        tz=ZoneInfo('Asia/Shanghai');epoch=978307200
        first=datetime.fromisoformat(start_date).replace(tzinfo=tz).timestamp()-epoch
        last=(datetime.fromisoformat(end_date).replace(tzinfo=tz)+timedelta(days=1)).timestamp()-epoch
        with sqlite3.connect(path.as_uri()+'?mode=ro',uri=True) as db:
            db.row_factory=sqlite3.Row
            rows=db.execute("""SELECT DISTINCT i.ROWID,i.UUID,i.summary,i.description,i.all_day,i.availability,i.has_attendees,i.has_recurrences,i.start_tz,c.title calendar,
                COALESCE(o.occurrence_date,i.start_date) occurrence,COALESCE(o.occurrence_start_date,o.occurrence_date,i.start_date) start,COALESCE(o.occurrence_end_date,i.end_date) end,
                (SELECT COUNT(*) FROM Participant p WHERE p.owner_id=i.ROWID) participants
                FROM CalendarItem i JOIN Calendar c ON c.ROWID=i.calendar_id LEFT JOIN OccurrenceCache o ON o.event_id=i.ROWID
                WHERE COALESCE(o.occurrence_start_date,o.occurrence_date,i.start_date)<? AND COALESCE(o.occurrence_end_date,i.end_date)>=? AND COALESCE(i.hidden,0)=0 AND COALESCE(i.status,0)!=2 ORDER BY start""",(last,first)).fetchall()
        result=[]
        for r in rows:
            if not r['UUID']:continue
            result.append({'id':r['UUID'],'title':r['summary'] or '未命名日程','start':datetime.fromtimestamp(r['start']+epoch,tz).isoformat(timespec='minutes'),'end':datetime.fromtimestamp(r['end']+epoch,tz).isoformat(timespec='minutes'),
                'occurrence_id':r['UUID']+':'+str(int(r['occurrence'])) if r['has_recurrences'] else r['UUID'],'recurring':bool(r['has_recurrences']),'calendar':r['calendar'],'description':r['description'] or '', 'attendee_count':r['participants'] if r['participants'] or not r['has_attendees'] else -1,'editable':None,'all_day':bool(r['all_day']),'availability':r['availability'],
                'source':'Apple Calendar cache','coverage':'Calendar 本机缓存；重复事件按 OccurrenceCache 展开','cache_updated_at':path.stat().st_mtime})
        return result

    async def read(self, start_date, end_date):
        try:
            rows=await asyncio.to_thread(self.cached,start_date,end_date)
            if rows is not None:return rows
        except (sqlite3.Error,OSError):pass
        first = datetime.fromisoformat(start_date).strftime('%Y-%m-%d')
        last = (datetime.fromisoformat(end_date) + timedelta(days=1)).strftime('%Y-%m-%d')
        return self.parse(await self.queue(['read', first, last]))

    async def adjust(self, event, start, end):
        if event.get('editable') is None:
            day=datetime.fromisoformat(event['start']).date().isoformat()
            live=self.parse(await self.queue(['get',day,(datetime.fromisoformat(day)+timedelta(days=1)).date().isoformat(),event['id']]))
            actual=next((e for e in live if e['id']==event['id']),None)
            if not actual or any(actual[k]!=event[k] for k in ('start','end','title')):raise ValueError('Calendar snapshot changed')
            event=actual
        if not event.get('editable') or event.get('attendee_count') != 0: raise ValueError('Only editable events without participants may be adjusted automatically')
        if event.get('locked') or '固定' in event.get('description', ''): raise ValueError('Event is locked')
        a, b = datetime.fromisoformat(start), datetime.fromisoformat(end)
        if a.tzinfo is None or b.tzinfo is None or b <= a: raise ValueError('Timezone and positive duration required')
        a, b = a.astimezone(ZoneInfo('Asia/Shanghai')), b.astimezone(ZoneInfo('Asia/Shanghai'))
        first = min(a.date(), datetime.fromisoformat(event['start']).date()).isoformat()
        last = max(b.date(), datetime.fromisoformat(event['end']).date()).isoformat()
        current = await self.read(first, last)
        saved = next((e for e in current if e['id'] == event['id']), None)
        if not saved or any(saved[k] != event[k] for k in ('start', 'end', 'title')): raise ValueError('Event changed; refresh before adjustment')
        if any(e.get('availability') != 1 and e['id'] != event['id'] and datetime.fromisoformat(e['start']) < b and datetime.fromisoformat(e['end']) > a for e in current):
            raise ValueError('Calendar conflict; choose another time')
        rows = self.parse(await self.queue(['adjust', first, (datetime.fromisoformat(last) + timedelta(days=1)).date().isoformat(),
            event['id'], a.strftime('%Y-%m-%dT%H:%M'), b.strftime('%Y-%m-%dT%H:%M'), datetime.fromisoformat(event['start']).strftime('%Y-%m-%dT%H:%M')]))
        after = next((e for e in rows if e['id'] == event['id']), None)
        verified = bool(after and datetime.fromisoformat(after['start']) == a and datetime.fromisoformat(after['end']) == b)
        return {'verified': verified, 'before': saved, 'after': after, 'undo': {'event': after, 'start': saved['start'], 'end': saved['end']}}

    async def undo_created(self,event,operation_id):
        marker='Com operation: '+operation_id
        if not event or marker not in event.get('description',''):raise ValueError('Missing original Com creation receipt')
        day=datetime.fromisoformat(event['start']).date().isoformat()
        end=(datetime.fromisoformat(day)+timedelta(days=1)).date().isoformat()
        live=self.parse(await self.queue(['get',day,end,event['id']]))
        current=next((e for e in live if e['id']==event['id']),None)
        if not current:return {'verified':True,'already_absent':True,'id':event['id']}
        if any(current[k]!=event[k] for k in ('start','end','title')):raise ValueError('Event changed since creation; undo requires refresh')
        await self.queue(['delete_created',day,end,event['id'],marker,datetime.fromisoformat(event['start']).strftime('%Y-%m-%dT%H:%M')])
        after=self.parse(await self.queue(['get',day,end,event['id']]))
        return {'verified':not any(e['id']==event['id'] for e in after),'id':event['id'],'source':'Apple Calendar'}
