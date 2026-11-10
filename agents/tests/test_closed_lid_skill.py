import copy
import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest

import os
SCRIPT_DIR=pathlib.Path(os.environ.get('LIDRUNNER_SKILL_SCRIPTS') or pathlib.Path(__file__).resolve().parents[1]/'plugin/skills/closed-lid-mode/scripts')
sys.path.insert(0,str(SCRIPT_DIR))
import status
import hook

class StatusTests(unittest.TestCase):
 def setUp(self):
  self.hw={'AppleClamshellState':True,'SleepDisabled':True}
  self.diag={'time':100,'phase':'active','lidClosed':True,'sleepDisabled':True,'batteryPercent':50,'onCharger':False}
  self.guard={'time':100,'accessibilityTrusted':True,'sessionEligible':True}
  self.root={'updated':100,'phase':'active','deadline':1000}
 def result(self,now=101):
  return status.evaluate(self.hw,self.diag,self.guard,self.root,now)
 def test_live_closed(self):
  r=self.result(); self.assertEqual(r['mode'],'closed'); self.assertTrue(r['capture_guard_ready'])
 def test_hardware_open_overrides_log(self):
  self.hw['AppleClamshellState']=False
  r=self.result(); self.assertEqual(r['mode'],'open'); self.assertFalse(r['capture_guard_ready'])
 def test_hardware_closed_overrides_log(self):
  self.diag['lidClosed']=False
  self.assertEqual(self.result()['mode'],'closed')
 def test_stale_logs_cannot_imply_open(self):
  self.hw={}; self.diag['lidClosed']=False
  r=self.result(now=120); self.assertEqual(r['mode'],'unknown'); self.assertFalse(r['power_session_active'])
 def test_fresh_fallback(self):
  self.hw={}; self.assertEqual(self.result()['lid_source'],'fresh_lidrunner_diagnostics')
 def test_future_timestamp(self):
  self.hw={}; self.assertEqual(self.result(now=90)['mode'],'unknown')
 def test_stale_guard(self):
  self.guard['time']=80; self.assertFalse(self.result()['capture_guard_ready'])
 def test_stale_privileged_helper(self):
  self.root['updated']=80; self.assertFalse(self.result()['power_session_active'])
 def test_expired_session(self):
  self.root['deadline']=100; self.assertFalse(self.result()['power_session_active'])
 def test_stopped_session(self):
  self.root['phase']='stopped'; self.assertFalse(self.result()['capture_guard_ready'])
 def test_revoked_permission(self):
  self.guard['accessibilityTrusted']=False; self.assertFalse(self.result()['capture_guard_ready'])
 def test_low_battery_alert(self):
  self.diag['batteryPercent']=16; self.assertIn('battery_near_15_percent_cutoff',self.result()['alerts'])
 def test_no_low_battery_alert_on_charger(self):
  self.diag.update(batteryPercent=16,onCharger=True)
  self.assertNotIn('battery_near_15_percent_cutoff',self.result()['alerts'])
 def test_invalid_values(self):
  self.diag['time']='100'; self.root['deadline']=float('nan')
  self.assertFalse(self.result()['power_session_active'])
 def test_untrusted_strings_not_in_output(self):
  self.diag['reason']='ATTACKER TEXT'; self.guard['status']='ATTACKER TEXT'
  self.assertNotIn('ATTACKER',json.dumps(self.result()))
 def test_untrusted_agent_apps_filtered(self):
  self.diag['agentApps']={'claude':True,'chatgpt':'yes','evil':True,'antigravity':False}
  r=self.result(); self.assertEqual(r['agent_apps_running'],{'claude':True,'antigravity':False})
 def test_legacy_chatgpt_flag(self):
  self.diag['chatGPTRunning']=True
  self.assertEqual(self.result()['agent_apps_running'],{'chatgpt':True})
 def test_stale_agent_apps_ignored(self):
  self.diag['agentApps']={'claude':True}
  self.assertIsNone(self.result(now=120)['agent_apps_running'])

class HookTests(unittest.TestCase):
 HOST='codex'
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(); self.cache=pathlib.Path(self.temp.name)
  self.state=status.evaluate({'AppleClamshellState':True,'SleepDisabled':True},
   {'time':100,'phase':'active','batteryPercent':50,'onCharger':False},
   {'time':100,'accessibilityTrusted':True,'sessionEligible':True},
   {'updated':100,'phase':'active','deadline':1000},101)
 def tearDown(self): self.temp.cleanup()
 def call(self,event='PreToolUse',session='A',**extra):
  return hook.run(dict(hook_event_name=event,session_id=session,**extra),self.state,self.cache,host=self.HOST)
 def test_first_closed_notice(self):
  self.assertIn('lid CLOSED',json.dumps(self.call()))
 def test_unchanged_tool_notice_suppressed(self):
  self.call(); self.assertIsNone(self.call())
 def test_multiple_sessions_independent(self):
  self.call(session='A'); self.assertIsNotNone(self.call(session='B'))
 def test_reopen_transition(self):
  self.call(); self.state['mode']='open'; self.state['capture_guard_ready']=False
  self.assertIn('lid OPEN',json.dumps(self.call()))
 def test_initial_open_quiet(self):
  self.state['mode']='open'; self.assertIsNone(self.call('SessionStart'))
 def test_compaction_reintroduces_context(self):
  self.call(); self.assertIsNotNone(self.call('SessionStart',source='compact'))
 def test_turn_start_reintroduces_closed_context(self):
  self.call(); self.assertIsNotNone(self.call('UserPromptSubmit'))
 def test_readiness_change_not_suppressed(self):
  self.call(); self.state['capture_guard_ready']=False
  self.assertIsNotNone(self.call())
 def test_countdowns_do_not_spam(self):
  self.call(); self.state['battery_percent']=49; self.state['session_remaining_seconds']=850
  self.assertIsNone(self.call())
 def test_no_approval_decisions(self):
  result=self.call(tool_input={'command':'arbitrary user command'})
  self.assertEqual(set(result),{'hookSpecificOutput'})
  self.assertEqual(set(result['hookSpecificOutput']),{'hookEventName','additionalContext'})
 def test_no_transcript_or_prompt_cache(self):
  self.call('UserPromptSubmit',prompt='SECRET_PROMPT',transcript_path='/secret-transcript')
  data=''.join(p.read_text() for p in self.cache.iterdir())
  self.assertNotIn('SECRET_PROMPT',data); self.assertNotIn('/secret-transcript',data)
 def test_unsupported_host_quiet(self):
  self.state['mode']='unsupported_host'; self.assertIsNone(self.call())
 def test_session_ids_not_paths(self):
  self.call(session='../../escape'); self.assertTrue(all(p.parent==self.cache for p in self.cache.iterdir()))

class SimulationTests(unittest.TestCase):
 def test_simulated_closed_is_labelled(self):
  old=os.environ.get('LIDRUNNER_SIMULATE_LID'); os.environ['LIDRUNNER_SIMULATE_LID']='closed'
  try: r=status.collect()
  finally:
   if old is None: os.environ.pop('LIDRUNNER_SIMULATE_LID')
   else: os.environ['LIDRUNNER_SIMULATE_LID']=old
  self.assertTrue(r['simulated']); self.assertEqual(r['mode'],'closed'); self.assertTrue(r['power_session_active'])
 def test_unknown_simulation_value_ignored(self):
  os.environ['LIDRUNNER_SIMULATE_LID']='banana'
  try: self.assertNotIn('simulated',status.collect())
  finally: os.environ.pop('LIDRUNNER_SIMULATE_LID')
 def test_simulated_hook_text_labelled(self):
  with tempfile.TemporaryDirectory() as d:
   st=status.simulated('closed',100.0)
   r=hook.run({'hook_event_name':'SessionStart','session_id':'s'},st,pathlib.Path(d),host='claude')
   self.assertTrue(r['hookSpecificOutput']['additionalContext'].startswith('[SIMULATED TEST STATE'))

class ClaudeHookTests(HookTests):
 HOST='claude'

class AntigravityHookTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(); self.cache=pathlib.Path(self.temp.name)
  self.state=status.evaluate({'AppleClamshellState':True,'SleepDisabled':True},
   {'time':100,'phase':'active','batteryPercent':50,'onCharger':False},
   {'time':100,'accessibilityTrusted':True,'sessionEligible':True},
   {'updated':100,'phase':'active','deadline':1000},101)
 def tearDown(self): self.temp.cleanup()
 def call(self,steps=10,conv='C',event='PreInvocation',**extra):
  payload=dict(conversationId=conv,initialNumSteps=steps,invocationNum=1,**extra)
  return hook.run(payload,self.state,self.cache,host='antigravity',event_name=event)
 def test_closed_turn_injects_ephemeral(self):
  r=self.call(); self.assertEqual(set(r),{'injectSteps'})
  self.assertIn('lid CLOSED',r['injectSteps'][0]['ephemeralMessage'])
 def test_same_turn_suppressed(self):
  self.call(); self.assertIsNone(self.call())
 def test_new_turn_reminds_when_closed(self):
  self.call(); self.assertIsNotNone(self.call(steps=14))
 def test_open_new_turn_quiet(self):
  self.state['mode']='open'; self.assertIsNone(self.call()); self.assertIsNone(self.call(steps=14))
 def test_mid_turn_closure_detected(self):
  self.state['mode']='open'; self.call()
  self.state['mode']='closed'; self.assertIsNotNone(self.call())
 def test_reopen_transition(self):
  self.call(); self.state['mode']='open'; self.state['capture_guard_ready']=False
  self.assertIn('lid OPEN',json.dumps(self.call()))
 def test_unknown_event_ignored(self):
  self.assertIsNone(self.call(event='PreToolUse'))
 def test_no_prompt_or_transcript_cached(self):
  self.call(lastUserInput='SECRET_PROMPT',transcriptPath='/secret-transcript',workspacePaths=['/secret-ws'])
  data=''.join(p.read_text() for p in self.cache.iterdir())
  for secret in ('SECRET_PROMPT','/secret-transcript','/secret-ws'): self.assertNotIn(secret,data)
 def test_missing_conversation_quiet(self):
  self.assertIsNone(hook.run({'initialNumSteps':1},self.state,self.cache,host='antigravity',event_name='PreInvocation'))

class CliTests(unittest.TestCase):
 """End-to-end: run hook.py as each host would, against live (read-only) host state."""
 def run_hook(self,args,payload):
  import subprocess
  env=dict(os.environ,HOME=self.home)
  return subprocess.run(['/usr/bin/python3',str(SCRIPT_DIR/'hook.py'),*args],input=json.dumps(payload),
   capture_output=True,text=True,timeout=10,env=env)
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(); self.home=self.temp.name
 def tearDown(self): self.temp.cleanup()
 def test_antigravity_always_prints_json_object(self):
  r=self.run_hook(['--host','antigravity','--event','PreInvocation'],{'conversationId':'x','initialNumSteps':1})
  self.assertEqual(r.returncode,0); self.assertIsInstance(json.loads(r.stdout),dict)
 def test_antigravity_garbage_input(self):
  r=self.run_hook(['--host','antigravity','--event','PreInvocation'],'not an object')
  self.assertEqual(json.loads(r.stdout),{})
 def test_claude_output_shape_or_silence(self):
  r=self.run_hook(['--host','claude'],{'hook_event_name':'SessionStart','session_id':'s','source':'startup'})
  self.assertEqual(r.returncode,0)
  if r.stdout.strip():
   self.assertEqual(json.loads(r.stdout)['hookSpecificOutput']['hookEventName'],'SessionStart')
 def test_codex_default_host_compat(self):
  r=self.run_hook([],{'hook_event_name':'PreToolUse','session_id':'s','tool_input':{'command':'x'}})
  self.assertEqual(r.returncode,0)
  if r.stdout.strip(): self.assertNotIn('permissionDecision',r.stdout)

if __name__=='__main__': unittest.main(verbosity=2)
