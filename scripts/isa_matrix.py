#!/usr/bin/env python3
"""Enumerate effective ISA configurations and run their applicable ACT tests.

RV32E forces B off in jv32_core.ZB_ACTIVE: 16 I configurations + 8 E
configurations. C/Zicsr/Zifencei are always present. Zcmp is additionally
covered by the project's reference-model tests in the main regression.
"""
import argparse
import datetime
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT=Path(__file__).resolve().parents[1]
ACT=ROOT/'verif/riscv-arch-test'
BASE=ROOT/'verif/config/jv32-rv32imac'
WORK=ROOT/'build/compliance/isa-matrix'

def configurations():
    for e,m,a,b,z in itertools.product(range(2),repeat=5):
        if e and b: continue
        yield f'e{e}m{m}a{a}b{b}z{z}',dict(RV32E_EN=e,RV32M_EN=m,AMO_EN=a,RV32B_EN=b,ZCMP_EN=z)

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--list',action='store_true')
    ap.add_argument('--only')
    args=ap.parse_args()
    configs=[(n,p) for n,p in configurations() if not args.only or n==args.only]
    if not configs: ap.error('unknown configuration')
    if args.list: print(json.dumps(dict(configs),indent=2));return
    WORK.mkdir(parents=True,exist_ok=True)
    provenance={'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'revision':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
                'sources':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                           for directory in ('rtl','testbench','sw','scripts','verif/config')
                           for p in (ROOT/directory).rglob('*')
                           if p.is_file() and p.suffix in ('.sv','.svh','.c','.cpp','.h','.py','.yaml','.mak')}}
    (WORK/'provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
    # Keep the upstream checkout intact. Its failure reporter saves x16-x31
    # unconditionally, although its startup already supports RVTEST_E.
    tests=WORK/'tests';tests.mkdir(exist_ok=True)
    for source in (ACT/'tests').iterdir():
        target=tests/source.name
        if source.name=='env':
            shutil.copytree(source,target,dirs_exist_ok=True)
        elif not target.exists():
            target.symlink_to(source,target_is_directory=source.is_dir())
    failure=tests/'env/failure_code.h'
    contents=failure.read_text()
    contents=contents.replace('        SREG x16, 128(DEFAULT_TEMP_REG)', '#ifndef RVTEST_E\n        SREG x16, 128(DEFAULT_TEMP_REG)')
    contents=contents.replace('        SREG x31, 248(DEFAULT_TEMP_REG)', '        SREG x31, 248(DEFAULT_TEMP_REG)\n#endif')
    failure.write_text(contents)
    original=(BASE/'jv32-rv32imac.yaml').read_text()
    tools_config=(ROOT/'build/arch-test-work/test_config.generated.yaml').read_text()
    summary=[]
    for name,params in configs:
        directory=WORK/name; directory.mkdir(exist_ok=True)
        extensions={'E' if params['RV32E_EN'] else 'I','C','Zca','Zicsr','Zifencei','Zicntr','Sm'}
        if params['RV32M_EN']:extensions.add('M')
        if params['AMO_EN']:extensions.update(['Zaamo','Zalrsc'])
        if params['RV32B_EN']:extensions.update(['Zba','Zbb','Zbs'])
        # Zcmp is not supported by the independent Sail reference used here.
        # Keep it out of this selection; the main regression records its ISS path.
        text=original.replace('name: I,','name: E,' ) if params['RV32E_EN'] else original
        text=re.sub(r'^name:.*',f'name: {name}',text,flags=re.M)
        text='\n'.join(line for line in text.splitlines() if not (re.search(r'name:\s*(\w+),',line) and re.search(r'name:\s*(\w+),',line).group(1) not in extensions))+'\n'
        yaml=directory/(name+'.yaml');yaml.write_text(text)
        out=directory/name;out.mkdir(exist_ok=True)
        (out/'extensions.txt').write_text('\n'.join(sorted(extensions))+'\n')
        config=re.sub(r'^name:.*',f'name: {name}',tools_config,flags=re.M)
        config=re.sub(r'^udb_config:.*',f'udb_config: {yaml}',config,flags=re.M)
        (directory/'test_config.yaml').write_text(config)
        env=os.environ.copy()
        log=directory/'generate.log'
        cmd=[str(ACT/'.venv/bin/act'),str(directory/'test_config.yaml'),'--workdir',str(directory),'--test-dir',str(tests),'--jobs','8','--extensions',','.join(sorted(extensions-{'Sm'}))]
        print(name,'generate',flush=True)
        with log.open('w') as f: rc=subprocess.run(cmd,cwd=ACT,env=env,stdout=f,stderr=subprocess.STDOUT).returncode
        entry={'name':name,'parameters':params,'generation':rc,'log':str(log.relative_to(ROOT))}
        if rc==0:
            build=directory/'rtl'
            cmd=['gmake',f'BUILD_DIR={build}','IRAM_SIZE=262144',*[f'{k}={v}' for k,v in params.items()], 'build-rtl','rtl-amo_config','rtl-trap_contract']
            if params['ZCMP_EN']: cmd.append('rtl-zcmp')
            with (directory/'build.log').open('w') as f: rc=subprocess.run(cmd,cwd=ROOT,env=env,stdout=f,stderr=subprocess.STDOUT).returncode
            entry['build_and_directed']=rc
            elfs=list((out/'elfs').rglob('*.elf'));entry['elf_count']=len(elfs)
            if rc==0 and elfs:
                with (directory/'run.log').open('w') as f:
                    entry['architectural']=subprocess.run([str(ACT/'.venv/bin/python'),str(ACT/'run_tests.py'),str(build/'jv32soc'),str(out/'elfs')],cwd=ROOT,env=env,stdout=f,stderr=subprocess.STDOUT).returncode
            elif not elfs: entry['architectural']='NO TESTS'
        summary.append(entry)
        (WORK/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
        print(entry,flush=True)
    if any(e.get('architectural')!=0 for e in summary):raise SystemExit(1)
if __name__=='__main__':main()
