"""Read-only local skill-load adapters. Persist only IDs, times and scan cursors.
No prompts, tool output, conversation text, network requests or copy counters.
"""
import ast
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import sqlite3
import subprocess
import sys
import time

TOOLS = ['Codex', 'DeepSeek Harness', '豆包工作', 'Claude']


def text_blocks(value):
    if isinstance(value, str):
        yield value
        try:
            decoded = json.loads(value)
        except (ValueError, TypeError):
            return
        if isinstance(decoded, (dict, list)):
            yield from text_blocks(decoded)
    elif isinstance(value, list):
        for item in value:
            yield from text_blocks(item)
    elif isinstance(value, dict):
        for key in ('text', 'output', 'content', 'result'):
            if key in value:
                yield from text_blocks(value[key])


class Scanner:
    def __init__(self, home, store, prompts):
        self.home = Path(home)
        self.prompts = {p['id'].lower(): p for p in prompts}
        self.names = {p['title']: i for i, p in self.prompts.items()
                      if sum(x['title'] == p['title'] for x in self.prompts.values()) == 1}
        self.names.update({'promptdesk-' + i: i for i in self.prompts})
        store = Path(store)
        store.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(store, timeout=5)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('CREATE TABLE IF NOT EXISTS events (tool TEXT, session TEXT, turn TEXT, prompt TEXT, time REAL, PRIMARY KEY(tool,session,turn,prompt))')
        self.db.execute('CREATE TABLE IF NOT EXISTS cursors (path TEXT PRIMARY KEY, inode INTEGER, offset INTEGER, size INTEGER, mtime INTEGER, state TEXT)')
        self.errors = []

    def emit(self, tool, session, turn, prompt, when):
        if turn is not None and prompt in self.prompts:
            self.db.execute('INSERT OR IGNORE INTO events VALUES (?,?,?,?,?)', (tool, session, str(turn), prompt, when))

    def named(self, value):
        if not isinstance(value, str):
            return None
        return self.names.get(value) or self.names.get(value.lower())

    def skill_path(self, value, tool, cwd=''):
        if not isinstance(value, str):
            return None
        value = value.replace('~/', str(self.home) + '/', 1)
        if not value.startswith('/'):
            value = str(Path(cwd) / value)
        path = Path(os.path.normpath(value))
        # Restrict reads to owned skill entries, not references, searches or text mentions.
        if path.name != 'SKILL.md':
            return None
        ident = self.names.get(path.parent.name.lower())
        root = Path(os.environ.get('CODEX_HOME', str(self.home / '.codex'))) if tool == 'Codex' else Path(os.environ.get('DSH_HOME', str(self.home / '.dsh')))
        return ident if path.parent.parent == root / 'skills' else None

    def shell_reads(self, command, tool, cwd):
        found = set()
        try:
            lexer = shlex.shlex(command, posix=True, punctuation_chars=';&|()<>')
            lexer.whitespace_split = True
            segments = [[]]
            for token in lexer:
                if token in (';', '&&', '||', '|', '\n'):
                    segments.append([])
                else:
                    segments[-1].append(token)
            for tokens in segments:
                if tokens and Path(tokens[0]).name in ('cat', 'head', 'tail', 'sed'):
                    for token in tokens[1:]:
                        ident = self.skill_path(token, tool, cwd)
                        if ident:
                            found.add(ident)
        except ValueError:
            pass
        return found

    def call_reads(self, name, args, tool, cwd):
        if isinstance(args, str):
            try:
                args = json.loads(args)
            except ValueError:
                return set()
        if not isinstance(args, dict):
            return set()
        if name.rsplit('__', 1)[-1] in ('exec_command', 'shell_command', 'bash', 'Bash', 'shell'):
            return self.shell_reads(args.get('cmd', args.get('command', '')), tool, cwd)
        if name.rsplit('__', 1)[-1] in ('read', 'read_file', 'Read'):
            ident = self.skill_path(args.get('file_path', args.get('path', '')), tool, cwd)
            return {ident} if ident else set()
        if name in ('skill', 'Skill'):
            ident = self.named(args.get('name', args.get('skill', '')))
            return {ident} if ident else set()
        return set()

    def code_reads(self, code, tool, cwd):
        # Parse string literals, never execute model-produced JavaScript.
        found = set()
        for m in re.finditer(r'(?:tools\.)?(?:exec_command|shell_command)\s*\(\s*\{\s*(?:cmd|command)\s*:\s*("(?:\\.|[^"\\])*"|\x27(?:\\.|[^\x27\\])*\x27)', code):
            try:
                command = ast.literal_eval(m.group(1))
            except (ValueError, SyntaxError):
                continue
            found.update(self.shell_reads(command, tool, cwd))
        return found

    def loaded(self, prompt, output):
        title = self.prompts[prompt]['title']
        technical = 'promptdesk-' + prompt
        for text in text_blocks(output):
            if re.search(r'<skill_content\b[^>]*name=["\x27](?:' + re.escape(title) + '|' + re.escape(technical) + r')["\x27]', text):
                return True
            for line in text.splitlines():
                if line.startswith('name:') and line[5:].strip().strip('"\x27') in (title, technical):
                    return True
        return False

    def codex(self, record, state, session):
        payload = record.get('payload', {})
        kind = record.get('type')
        if kind == 'session_meta':
            state['session'] = payload.get('id', session)
            state['cwd'] = payload.get('cwd', '')
        if kind == 'turn_context' or (kind == 'event_msg' and payload.get('type') == 'task_started'):
            turn = payload.get('turn_id')
            if turn and turn != state.get('turn'):
                state['pending'] = {}
                state['turn'] = turn
            state['cwd'] = payload.get('cwd', state.get('cwd', ''))
        if kind != 'response_item':
            return
        subtype = payload.get('type')
        session = state.get('session', session)
        when = record.get('timestamp', '')
        try:
            from datetime import datetime
            when = datetime.fromisoformat(when.replace('Z', '+00:00')).timestamp()
        except (ValueError, TypeError):
            when = 0
        if subtype == 'message' and payload.get('role') == 'user':
            for block in payload.get('content', []):
                if block.get('type') == 'skill':
                    ident = self.skill_path(block.get('path', ''), 'Codex', state.get('cwd', ''))
                    if ident:
                        self.emit('Codex', session, state.get('turn'), ident, when)
                text = block.get('text', '').strip()
                if text.startswith('<skill>') and '</skill>' in text:
                    # Only the explicit injected skill envelope, never the skill catalog.
                    for ident, prompt in self.prompts.items():
                        if ('promptdesk-' + ident + '/SKILL.md') in text:
                            self.emit('Codex', session, state.get('turn'), ident, when)
        if subtype in ('function_call', 'custom_tool_call'):
            name = payload.get('name', '')
            args = payload.get('arguments', {})
            reads = self.call_reads(name, args, 'Codex', state.get('cwd', ''))
            if subtype == 'custom_tool_call' and name in ('exec', 'functions.exec'):
                reads.update(self.code_reads(payload.get('input', ''), 'Codex', state.get('cwd', '')))
            if reads:
                state.setdefault('pending', {})[payload.get('call_id', '')] = {'ids': sorted(reads), 'turn': state.get('turn'), 'time': when}
        if subtype in ('function_call_output', 'custom_tool_call_output'):
            pending = state.setdefault('pending', {}).pop(payload.get('call_id', ''), None)
            if pending:
                for ident in pending['ids']:
                    if self.loaded(ident, payload.get('output', '')):
                        self.emit('Codex', session, pending['turn'], ident, pending['time'])

    def harness(self, record, state, session):
        payload = record.get('data', {})
        kind = record.get('type')
        if kind == 'session':
            state['session'] = record.get('id', session)
            state['cwd'] = record.get('cwd', '')
        if kind == 'turn/start':
            state['turn'] = payload.get('turn')
            state['pending'] = {}
        session = state.get('session', session)
        when = record.get('time', 0)
        if isinstance(when, str):
            try:
                from datetime import datetime
                when = datetime.fromisoformat(when.replace('Z', '+00:00')).timestamp()
            except ValueError:
                when = 0
        elif isinstance(when, (int, float)) and when > 100000000000:
            when /= 1000
        if kind == 'user/message':
            source = payload.get('source', {})
            # Catalog and runtime-context source kinds must never count.
            if source.get('kind') == 'skill-invocation':
                ident = self.named(source.get('name', source.get('skillName', '')))
                if ident and self.loaded(ident, payload.get('content', [])):
                    self.emit('DeepSeek Harness', session, state.get('turn'), ident, when)
        if kind == 'tool/call':
            reads = self.call_reads(payload.get('name', ''), payload.get('arguments', {}), 'DeepSeek Harness', state.get('cwd', ''))
            if reads:
                state.setdefault('pending', {})[payload.get('callId', '')] = {'ids': sorted(reads), 'turn': payload.get('turn', state.get('turn')), 'time': when}
        if kind == 'tool/result':
            message = payload.get('message', {})
            pending = state.setdefault('pending', {}).pop(message.get('toolCallId', ''), None)
            if pending and not message.get('isError', False):
                for ident in pending['ids']:
                    if self.loaded(ident, message.get('content', [])):
                        self.emit('DeepSeek Harness', session, pending['turn'], ident, pending['time'])

    def scan_file(self, path, adapter, compressed=False):
        stat = path.stat()
        old = self.db.execute('SELECT inode,offset,size,mtime,state FROM cursors WHERE path=?', (str(path),)).fetchone()
        if old and old[0] == stat.st_ino and old[2] == stat.st_size and old[3] == stat.st_mtime_ns:
            return
        state = json.loads(old[4]) if old and old[0] == stat.st_ino and old[1] <= stat.st_size and not compressed else {}
        offset = old[1] if state else 0
        if compressed:
            zstd = shutil.which('zstd') or next((p for p in ('/opt/homebrew/bin/zstd', '/usr/local/bin/zstd') if Path(p).exists()), None)
            if not zstd:
                raise RuntimeError('缺少 zstd 解压工具')
            process = subprocess.Popen([zstd, '-dc', str(path)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            stream = process.stdout
        else:
            stream = path.open('rb')
            stream.seek(offset)
        session = path.parent.name if adapter == self.harness else path.name.split('.jsonl')[0]
        try:
            for line in stream:
                if not line.endswith(b'\n'):
                    break  # A writer may still be appending this JSON record.
                if not compressed:
                    offset += len(line)
                try:
                    record = json.loads(line)
                except (ValueError, UnicodeDecodeError):
                    continue
                adapter(record, state, session)
        finally:
            stream.close()
            if compressed:
                process.wait(timeout=10)
        if compressed:
            offset = 0
        self.db.execute('INSERT OR REPLACE INTO cursors VALUES (?,?,?,?,?,?)', (str(path), stat.st_ino, offset, stat.st_size, stat.st_mtime_ns, json.dumps(state)))

    def run(self):
        roots = {
            'Codex': [Path(os.environ.get('CODEX_HOME', str(self.home / '.codex'))) / folder for folder in ('sessions', 'archived_sessions')],
            'DeepSeek Harness': [Path(os.environ.get('DSH_HOME', str(self.home / '.dsh'))) / 'sessions'],
        }
        # Owned prompts did not exist before their first installed skill directory.
        births = []
        for tool in roots:
            base = roots[tool][0].parent / 'skills'
            for ident in self.prompts:
                p = base / ('promptdesk-' + ident)
                if p.exists():
                    births.append(getattr(p.stat(), 'st_birthtime', p.stat().st_ctime))
        cutoff = min(births, default=time.time()) - 60
        status = {}
        for tool, folders in roots.items():
            available = any(p.exists() for p in folders)
            before = len(self.errors)
            for root in folders:
                if not root.exists():
                    continue
                for path in root.rglob('*'):
                    if not path.is_file() or not (path.name.endswith('.jsonl') or path.name.endswith('.jsonl.zst') or path.name.endswith('.jsonl.zstd')):
                        continue
                    try:
                        if path.stat().st_mtime < cutoff:
                            continue
                        self.scan_file(path, self.codex if tool == 'Codex' else self.harness, path.suffix in ('.zst', '.zstd'))
                    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError):
                        self.errors.append(tool)
            status[tool] = '记录读取异常，保留已有累计' if len(self.errors) > before else ('已接入本地技能加载记录' if available else '未找到本地记录')
        status['豆包工作'] = '暂未接入：未找到可验证的调用记录'
        status['Claude'] = '暂未接入：桌面云端调用记录不可读'
        self.db.commit()
        counts = {}
        last = {}
        for prompt, tool, count, when in self.db.execute('SELECT prompt,tool,count(*),max(time) FROM events GROUP BY prompt,tool'):
            counts.setdefault(prompt, {})[tool] = count
            last[prompt] = max(last.get(prompt, 0), when or 0)
        return {'counts': counts, 'last': last, 'status': status, 'updated': time.time()}


if __name__ == '__main__':
    request = json.load(sys.stdin)
    try:
        scanner = Scanner(request.get('home', str(Path.home())), request['store'], request['prompts'])
        print(json.dumps(scanner.run(), ensure_ascii=False))
    except Exception:
        print(json.dumps({'error': '调用记录读取失败，已有累计保留。'}))
        sys.exit(1)
