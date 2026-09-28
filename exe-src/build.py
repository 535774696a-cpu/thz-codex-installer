from pathlib import Path
import hashlib,os,subprocess,shutil,tempfile
root=Path(__file__).resolve().parent
resources=['InstallerLibrary.ps1','Runner.ps1']
s='public static partial class Bootstrap { static readonly System.Collections.Generic.Dictionary<string,string> Resources=new System.Collections.Generic.Dictionary<string,string> { '+','.join('{"'+n+'","'+hashlib.sha256((root/n).read_bytes()).hexdigest().upper()+'"}' for n in resources)+' }; }'
(root/'Resources.cs').write_text(s)
compiler=Path(os.environ.get('THZ_MONO_ROOT','/tmp/thz-v44-build/toolchain'))
env=dict(os.environ,MONO_PATH=str(compiler/'usr/lib/mono/4.5'),LD_LIBRARY_PATH=str(compiler/'usr/lib'),MONO_CFG_DIR=str(compiler/'etc'))
with tempfile.TemporaryDirectory(prefix='thz-exe-build-') as work:
    stage=Path(work)
    for n in ['Safety.cs','Bootstrap.cs','Resources.cs']+resources: shutil.copy2(root/n,stage/n)
    cmd=[str(compiler/'usr/bin/mono-sgen'),str(compiler/'usr/lib/mono/4.5/mcs.exe'),'-target:winexe','-platform:anycpu','-r:System.Windows.Forms','-r:System.Drawing','-out:THZ-Codex-Setup.exe','Safety.cs','Bootstrap.cs','Resources.cs']+['-resource:'+n+','+n for n in resources]
    subprocess.run(cmd,env=env,cwd=stage,check=True)
    shutil.copy2(stage/'THZ-Codex-Setup.exe',root.parent/'THZ-Codex-Setup.exe')
p=root.parent/'THZ-Codex-Setup.exe';(root.parent/'SHA256SUMS.txt').write_text(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n')
print('EXE built:',p)
