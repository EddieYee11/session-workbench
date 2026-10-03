"""Machine acceptance against actual files and test runners, never assistant prose."""
import asyncio
import json
import os
import re
import shlex
import time
from pathlib import Path


async def verify(task,checks,state):
    if task['status']!='execution_finished' or not isinstance(checks,list) or not checks or len(checks)>8:
        raise ValueError('需要已结束任务和可执行的验收检查')
    root=Path(task.get('workspace_copy') or task['cwd']).resolve()
    evidence=[]
    for check in checks:
        kind=check.get('type')
        if kind in ('file_exists','file_contains'):
            path=(root/check.get('path','')).resolve()
            if not path.is_relative_to(root) or not path.is_file():
                raise ValueError('验收文件不存在或越界')
            if kind=='file_contains' and (not check.get('value') or check['value'] not in path.read_text()):
                raise ValueError('文件内容未达到验收条件')
            evidence.append({'reference':str(path),'check':kind,'passed':True})
        elif kind=='tests':
            if not task.get('workspace_copy'):
                raise ValueError('测试在独立项目副本执行')
            argv=shlex.split(check.get('command',''))
            prefixes=[['python','-m','pytest'],['python3','-m','pytest'],['npm','test'],['npm','run','test'],['./gradlew','test']]
            supported=any(argv[:len(p)]==p for p in prefixes) or (len(argv)>1 and argv[0]=='./gradlew' and re.fullmatch(r'test[A-Za-z0-9]*',argv[1]))
            if not supported or any(v in ' '.join(argv) for v in (';','&&','||','`','$(','../')):
                raise ValueError('使用受支持的项目测试命令')
            from execution_boundary import sandbox,require_host
            require_host(state)
            scratch=Path(state)/'verification-scratch'/task['id'];scratch.mkdir(parents=True,exist_ok=True)
            argv=sandbox(argv,scratch,root)
            proc=await asyncio.create_subprocess_exec(*argv,cwd=root,env={**os.environ,'TZ':'Asia/Shanghai',
                 'GRADLE_USER_HOME':str(scratch/'gradle'),'npm_config_cache':str(scratch/'npm')},
                 stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.STDOUT)
            try:
                out,_=await asyncio.wait_for(proc.communicate(),120)
            except asyncio.TimeoutError:
                proc.kill();await proc.wait()
                raise ValueError('验收测试超时') from None
            if proc.returncode:
                raise ValueError('项目测试失败，未验收通过')
            log=Path(state)/'verification'/task['id']
            log.mkdir(parents=True,exist_ok=True)
            target=log/('tests-'+str(time.time_ns())+'.log')
            target.write_bytes(out);target.chmod(0o600)
            evidence.append({'reference':str(target),'check':'tests','exit_code':proc.returncode,'passed':True})
        else:
            raise ValueError('未知验收检查；不能根据文本完成自动通过')
    return evidence
