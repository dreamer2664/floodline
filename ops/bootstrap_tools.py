#!/usr/bin/env python3
"""Rootless, pinned official Rojo/Lune/Luau CLI bootstrap; no Roblox login.
Auth is never attached to release downloads. Only selected regular binaries are extracted.
"""
from pathlib import Path
import argparse,hashlib,json,os,platform,shutil,stat,urllib.request,zipfile
ROOT=Path(__file__).resolve().parents[1]
REPOS={'rojo':'rojo-rbx/rojo','lune':'lune-org/lune','luau':'luau-lang/luau'}
EXPECTED={'rojo':('rojo',),'lune':('lune',),'luau':('luau','luau-analyze','luau-compile')}

def get(url):
    return urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'floodline-tool-bootstrap'}),timeout=180)
def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
    return h.hexdigest()

def choose(tool,assets):
    names=[a for a in assets if a['name'].endswith('.zip')]
    if tool=='luau':names=[a for a in names if a['name'].lower()=='luau-ubuntu.zip']
    else:names=[a for a in names if 'linux' in a['name'].lower() and any(s in a['name'].lower() for s in ('x86_64','amd64'))]
    if len(names)!=1:raise RuntimeError(f'Expected one Linux x86_64 {tool} ZIP; inspect official release assets')
    return names[0]

def install(lock_path=None):
    if platform.system()!='Linux' or platform.machine().lower() not in ('x86_64','amd64'):raise RuntimeError('This tested bootstrap is Linux x86_64 only; use official Rojo/Lune/Luau builds for your OS')
    lock_path=Path(lock_path or ROOT/'ops/toolchain-lock.json');lock=json.loads(lock_path.read_text()) if lock_path.exists() else {'platform':'linux-x86_64','tools':{}}
    cache=Path(os.environ.get('FLOODLINE_TOOL_CACHE',Path.home()/'.cache/floodline-tools'));bindir=cache/'bin';bindir.mkdir(parents=True,exist_ok=True)
    for tool,repo in REPOS.items():
        entry=lock['tools'].get(tool)
        if not entry:
            with get(f'https://api.github.com/repos/{repo}/releases/latest') as r:release=json.load(r)
            asset=choose(tool,release['assets']);entry={'repo':repo,'version':release['tag_name'],'url':asset['browser_download_url'],'release_url':release['html_url'],'server_digest':asset.get('digest'),'binary_sha256':{}}
            lock['tools'][tool]=entry
        expected=entry.get('binary_sha256',{})
        if expected and all((bindir/n).exists() and sha(bindir/n)==h for n,h in expected.items()):
            for n in expected:(bindir/n).chmod(0o755)
            continue
        archive=cache/(tool+'-'+entry['version']+'.zip')
        if not archive.exists():
            tmp=archive.with_suffix('.part')
            with get(entry['url']) as src,tmp.open('wb') as out:shutil.copyfileobj(src,out)
            tmp.replace(archive)
        actual=sha(archive);server=entry.get('server_digest')
        if server and server!='sha256:'+actual:raise RuntimeError('Official release asset digest mismatch; do not execute')
        if entry.get('archive_sha256') and actual!=entry['archive_sha256']:raise RuntimeError('Pinned archive checksum mismatch; do not execute')
        entry['archive_sha256']=actual
        with zipfile.ZipFile(archive) as z:
            for name in EXPECTED[tool]:
                members=[i for i in z.infolist() if not i.is_dir() and Path(i.filename).name==name and stat.S_IFMT(i.external_attr>>16)!=stat.S_IFLNK]
                if len(members)!=1:raise RuntimeError(f'Expected one regular {name} executable')
                target=bindir/name
                with z.open(members[0]) as src,target.open('wb') as out:shutil.copyfileobj(src,out)
                target.chmod(0o755);digest=sha(target)
                if expected.get(name) and digest!=expected[name]:raise RuntimeError('Pinned executable checksum mismatch')
                entry['binary_sha256'][name]=digest
        lock_path.parent.mkdir(parents=True,exist_ok=True);lock_path.write_text(json.dumps(lock,indent=2)+'\n')
    return bindir

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--lock');a=p.parse_args();print(install(a.lock))
