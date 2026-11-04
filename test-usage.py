import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import shutil
import unittest

spec=importlib.util.spec_from_file_location('usage',Path(__file__).parent/'Assets/usage-scan.py')
usage=importlib.util.module_from_spec(spec);spec.loader.exec_module(usage)
ID='90e62167-acd8-40d3-a2cb-4cebba0dee67'

class UsageTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.home=Path(self.temp.name)
        self.path=self.home/'.codex/skills'/('promptdesk-'+ID)/'SKILL.md'
        self.path.parent.mkdir(parents=True);self.path.write_text('---\nname: "第一性原理"\n---\n内容')
        self.store=self.home/'usage.sqlite';self.prompts=[{'id':ID.upper(),'title':'第一性原理'}]
        self.scanner=usage.Scanner(self.home,self.store,self.prompts)
    def tearDown(self):self.scanner.db.close();self.temp.cleanup()
    def count(self):return self.scanner.db.execute('SELECT count(*) FROM events').fetchone()[0]
    def codex(self,payload,kind='response_item',state=None):
        if state is None:state=self.state
        self.scanner.codex({'type':kind,'timestamp':'2026-11-04T05:00:00Z','payload':payload},state,'session-test')
    def start(self,turn='turn-1'):
        self.state={};self.codex({'turn_id':turn,'cwd':str(self.home)},'turn_context')
    def call(self,call='c1',output=None):
        self.codex({'type':'custom_tool_call','name':'exec','call_id':call,'input':'text(await tools.exec_command({cmd:'+json.dumps("cat '"+str(self.path)+"'")+ '}));'})
        self.codex({'type':'custom_tool_call_output','call_id':call,'output':output if output is not None else [{'type':'input_text','text':json.dumps({'exit_code':0,'output':self.path.read_text()})}]})
    def test_success_failure_and_turn_dedup(self):
        self.start();self.call(output='cat: not found');self.assertEqual(self.count(),0)
        self.call('ok');self.call('repeat');self.assertEqual(self.count(),1)
        self.codex({'turn_id':'turn-2'},'turn_context');self.call('next');self.assertEqual(self.count(),2)
    def test_catalog_copy_install_and_diagnostics_never_count(self):
        self.start()
        self.codex({'type':'message','role':'developer','content':[{'type':'input_text','text':'available skills '+str(self.path)}]})
        for command in ['echo '+str(self.path),'ls '+str(self.path),'rg name '+str(self.path),'python3 -c "print(1)"']:
            self.assertEqual(self.scanner.shell_reads(command,'Codex',str(self.home)),set())
        self.codex({'type':'custom_tool_call','name':'exec','call_id':'write','input':'await tools.apply_patch("cat '+str(self.path)+'")'})
        self.codex({'type':'custom_tool_call_output','call_id':'write','output':self.path.read_text()})
        self.assertEqual(self.count(),0)
    def test_explicit_and_implicit_same_turn_and_metadata_echo(self):
        self.start()
        self.codex({'type':'message','role':'user','content':[{'type':'input_text','text':'<skill>\n<path>'+str(self.path)+'</path>\n</skill>'}]})
        self.call();self.assertEqual(self.count(),1)
        # event_msg/item_completed repeats canonical records; must not double count.
        self.codex({'type':'item_completed','item':{'type':'message'}},'event_msg');self.assertEqual(self.count(),1)
    def test_cursor_partial_records_restart_and_truncation(self):
        folder=self.home/'.codex/sessions';folder.mkdir()
        path=folder/'rollout-test.jsonl'
        rows=[{'type':'turn_context','payload':{'turn_id':'t1'}},{'type':'response_item','payload':{'type':'function_call','name':'exec_command','call_id':'x','arguments':json.dumps({'cmd':'cat '+str(self.path)})}},{'type':'response_item','payload':{'type':'function_call_output','call_id':'x','output':json.dumps({'exit_code':0,'output':self.path.read_text()})}}]
        lines=[json.dumps(r).encode()+b'\n' for r in rows]
        path.write_bytes(b''.join(lines[:2])+lines[2][:20]);self.scanner.run();self.assertEqual(self.count(),0)
        with path.open('ab') as f:f.write(lines[2][20:])
        self.scanner.run();self.assertEqual(self.count(),1)
        self.scanner.db.close();self.scanner=usage.Scanner(self.home,self.store,self.prompts)
        self.scanner.run();self.assertEqual(self.count(),1)
        duplicate=folder/'archived-copy.jsonl';duplicate.write_bytes(b''.join([json.dumps({'type':'session_meta','payload':{'id':'same'}}).encode()+b'\n']+lines))
        # Repeated history and source deletion preserve accumulated counts.
        self.scanner.scan_file(duplicate,self.scanner.codex);self.scanner.db.commit();prior=self.count()
        self.scanner.scan_file(duplicate,self.scanner.codex);self.assertEqual(self.count(),prior)
        path.unlink();self.scanner.run();self.assertEqual(self.count(),prior)
    def test_harness_compressed_success_and_failed_tool(self):
        folder=self.home/'.dsh/sessions/session-1';folder.mkdir(parents=True)
        rows=[{'type':'session','id':'h1'},{'type':'turn/start','data':{'turn':'h-turn'}},{'type':'tool/call','time':1,'data':{'turn':'h-turn','callId':'load','name':'skill','arguments':{'name':'promptdesk-'+ID}}},{'type':'tool/result','data':{'message':{'toolCallId':'load','isError':False,'content':[{'type':'text','text':'<skill_content name="promptdesk-'+ID+'">内容</skill_content>'}]}}}]
        encoded=''.join(json.dumps(r)+'\n' for r in rows).encode()
        packed=subprocess.check_output([(shutil.which('zstd') or '/opt/homebrew/bin/zstd'),'-q','-c'],input=encoded)
        path=folder/'session.v4.jsonl.zstd';path.write_bytes(packed)
        self.scanner.run();self.assertEqual(self.count(),1)
        self.scanner.run();self.assertEqual(self.count(),1)
        rows[0]['id']='h2';rows[-1]['data']['message']['isError']=True
        path.write_bytes(subprocess.check_output([(shutil.which('zstd') or '/opt/homebrew/bin/zstd'),'-q','-c'],input=''.join(json.dumps(r)+'\n' for r in rows).encode()))
        self.scanner.run();self.assertEqual(self.count(),1)
    def test_harness_explicit_invocation_is_not_catalog_or_mention(self):
        state={}
        self.scanner.harness({'type':'turn/start','data':{'turn':1}},state,'h')
        content=[{'type':'text','text':'<skill_content name="promptdesk-'+ID+'">内容</skill_content>'}]
        for kind in ('user','runtime-context','skill-catalog'):
            self.scanner.harness({'type':'user/message','time':1793763112574,'data':{'source':{'kind':kind,'name':'promptdesk-'+ID},'content':content}},state,'h')
        self.assertEqual(self.count(),0)
        self.scanner.harness({'type':'user/message','time':1793763112574,'data':{'source':{'kind':'skill-invocation','name':'promptdesk-'+ID,'form':'instructions'},'content':content}},state,'h')
        self.assertEqual(self.count(),1)
        self.assertLess(self.scanner.db.execute('SELECT time FROM events').fetchone()[0],100000000000)

    def test_renaming_keeps_counts_new_id_does_not_inherit(self):
        self.scanner.emit('Codex','s','t',ID,1);self.scanner.db.commit()
        self.scanner.db.close();self.scanner=usage.Scanner(self.home,self.store,[{'id':ID,'title':'改名后'}])
        result=self.scanner.run();self.assertEqual(result['counts'][ID]['Codex'],1)
        self.assertNotIn('different-id',result['counts'])
        self.assertIn('暂未接入',result['status']['Claude']);self.assertIn('暂未接入',result['status']['豆包工作'])

if __name__=='__main__':unittest.main()
