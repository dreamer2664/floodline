from pathlib import Path
import contextlib,io,json,os,subprocess,sys,tempfile,unittest,zipfile
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'ops'))
import field,release

class ContractTests(unittest.TestCase):
    def test_standalone_clean_complete_game_charter(self):
        text=(ROOT/'RIVETER.md').read_text();self.assertGreater(len(text.split()),4000)
        for required in ('EDIT mode','NOT RUN','HANDOFF.md','every five minutes','six distinct','ProximityPrompt','Studio playtest','t-20261015-ffaa'):self.assertIn(required,text)
        for key in ('CHATCODE_TOKEN','GITHUB_TOKEN'):self.assertEqual(text.count(key+'=PENDING-ISSUE'),1)
    def test_embedded_private_bootstrap_executes(self):
        text=(ROOT/'RIVETER.md').read_text();code=text.split("python3 - <<'PY'\n",1)[1].split('\nPY\n',1)[0]
        with tempfile.TemporaryDirectory() as t:
            p=Path(t);kit=p/'RIVETER.md';kit.write_text(text.replace('CHATCODE_TOKEN=PENDING-ISSUE','CHATCODE_TOKEN=unit-test-chat').replace('GITHUB_TOKEN=PENDING-ISSUE','GITHUB_TOKEN=unit-test-git'))
            with patch.dict(os.environ,{'HOME':t,'FLOODLINE_KIT':str(kit)}):exec(compile(code,'kit-bootstrap','exec'),{})
            self.assertEqual((p/'.private/riveter.env').stat().st_mode&0o777,0o600)
            self.assertEqual((p/'.private/floodline-askpass.sh').stat().st_mode&0o777,0o700)
    def test_only_own_identity(self):
        with tempfile.TemporaryDirectory() as t:
            with self.assertRaises(ValueError):field.home('kinetic',t)
    def test_tools_pinned_with_hashes(self):
        lock=json.loads((ROOT/'ops/toolchain-lock.json').read_text());self.assertEqual(set(lock['tools']),{'rojo','lune','luau'})
        for entry in lock['tools'].values():self.assertEqual(len(entry['archive_sha256']),64);self.assertTrue(entry['binary_sha256'])

class JournalTests(unittest.TestCase):
    def test_failures_solutions_resume_and_secret_redaction(self):
        with tempfile.TemporaryDirectory() as t,patch.dict(os.environ,{'GITHUB_TOKEN':'unit-test-secret'}):
            field.event('riveter','failure','Test unit-test-secret','Missing world in edit mode',state='failed',root=t)
            field.event('riveter','fix','Bake map before export','Geometry now in exported file',next_action='Inspect actual map',root=t)
            text=(Path(t)/'agents/riveter/HANDOFF.md').read_text();self.assertNotIn('unit-test-secret',text);self.assertIn('Missing world',text);self.assertIn('Geometry now',text);self.assertIn('Inspect actual map',text)
    def test_actual_process_auth_isolated_and_not_delivered(self):
        with tempfile.TemporaryDirectory() as t,patch.dict(os.environ,{'GITHUB_TOKEN':'unit-test-secret'}),contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(field.run_tracked('riveter',[sys.executable,'-c','import os;print("CLEAN" if "GITHUB_TOKEN" not in os.environ else "BAD")'],'test',root=t),0)
            status=json.loads((Path(t)/'status/riveter.json').read_text());self.assertEqual(status['state'],'checkpoint');self.assertIn('CLEAN',status['observed_activity'])
    def test_partial_output_cannot_block_observation(self):
        with tempfile.TemporaryDirectory() as t,contextlib.redirect_stdout(io.StringIO()):
            field.run_tracked('riveter',[sys.executable,'-c','import time;print("part",end="",flush=True);time.sleep(.16)'],'test',interval=.03,root=t)
            records=[json.loads(l) for l in (Path(t)/'agents/riveter/events.jsonl').read_text().splitlines()];self.assertTrue(any(x['kind']=='process-observation' for x in records))
    def test_missing_and_nonzero_commands_fail(self):
        with tempfile.TemporaryDirectory() as t,contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(field.run_tracked('riveter',['/not-a-real-executable'],'test',root=t),127)
            self.assertEqual(field.run_tracked('riveter',[sys.executable,'-c','raise SystemExit(5)'],'test',root=t),5)
            self.assertEqual(json.loads((Path(t)/'status/riveter.json').read_text())['state'],'failed')
    def test_rapid_commands_have_distinct_raw_logs(self):
        with tempfile.TemporaryDirectory() as t,contextlib.redirect_stdout(io.StringIO()):
            for _ in range(2):field.run_tracked('riveter',[sys.executable,'-c','print("fixture")'],'test',root=t)
            self.assertEqual(len(list((Path(t)/'agents/riveter/work').glob('process-*.log'))),2)

class ArtifactSafetyTests(unittest.TestCase):
    def test_other_folder_refused(self):
        with tempfile.TemporaryDirectory() as t,patch.object(release,'ROOT',Path(t)):
            p=Path(t)/'other.rbxlx';p.write_text('fixture')
            with self.assertRaises(ValueError):release.own_file('riveter',p)
    def test_compressed_known_key_and_private_entry_refused(self):
        with tempfile.TemporaryDirectory() as t,patch.object(release,'ROOT',Path(t)),patch.dict(os.environ,{'GITHUB_TOKEN':'unit-test-secret'}):
            p=Path(t)/'agents/riveter';p.mkdir(parents=True);z=p/'source.zip'
            with zipfile.ZipFile(z,'w',compression=zipfile.ZIP_DEFLATED) as archive:archive.writestr('src/bad.txt','unit-test-secret')
            with self.assertRaisesRegex(ValueError,'compressed'):release.own_file('riveter',z)
            with zipfile.ZipFile(z,'w') as archive:archive.writestr('.env','nothing secret')
            with self.assertRaisesRegex(ValueError,'private'):release.own_file('riveter',z)
    def test_clean_source_archive_allowed(self):
        with tempfile.TemporaryDirectory() as t,patch.object(release,'ROOT',Path(t)):
            p=Path(t)/'agents/riveter';p.mkdir(parents=True);z=p/'source.zip'
            with zipfile.ZipFile(z,'w') as archive:archive.writestr('src/Grid.luau','return {}')
            f,digest=release.own_file('riveter',z);self.assertEqual(f,z);self.assertEqual(len(digest),64)

if __name__=='__main__':unittest.main()
