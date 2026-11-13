#!/usr/bin/env python3
"""Generation-agreement canaries: local commands must not hide broken remote catalogs."""
import copy
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('agent_contract', Path(sys.argv[1]))
suite = importlib.util.module_from_spec(spec)
spec.loader.exec_module(suite)


class Product:
    tool = 'fixture'

    def __init__(self):
        # Nonstandard/dotted local names ensure no product name is hardcoded.
        self.commands = {'ping': (False, False), 'read': (False, False),
                         'serve': (True, False), 'offline.inspect': (True, False),
                         'console_ui': (True, True)}
        self.docs = '# fixture\n'
        self.skill = '---\nname: fixture\n---\n'
        for wire, (local, interactive) in self.commands.items():
            command = f'`fixture {wire.replace(".", " ").replace("_", "-")}`'
            self.docs += f'### {command}\n\n- Wire name: `{wire}`\n- MCP tool: '
            self.docs += 'none (local command)\n' if local else f'`{suite.mcp_name(wire)}`\n'
            if interactive:
                self.docs += '- Interactive: needs a terminal on stdin and stdout\n'
            else:
                self.skill += command + '\n'
        self.names = ['ping', 'read']
        self.completions = 'ping read serve offline console-ui'

    def help_verbs(self):
        # Read's grant=none must not make it local.
        return [(wire, 'none') for wire in self.commands]

    def run(self, verb, **kwargs):
        return SimpleNamespace(stdout=self.docs if verb == 'docs' else self.skill)

    def json(self, *args, **kwargs):
        return {'content': self.completions}

    def mcp(self, requests):
        return [{'result': {'tools': [
            {'name': name, 'inputSchema': {'type': 'object', 'additionalProperties': False}}
            for name in self.names]}}]


p = Product()
suite.check_generation(p)
print('ok generation interactive and non-interactive local commands')

faults = {
    'missing remote MCP tool': ('names', ['ping']),
    'extra MCP tool': ('names', ['ping', 'read', 'extra']),
    'exposed interactive local': ('names', ['ping', 'read', 'console__ui']),
    'exposed non-interactive local': ('names', ['ping', 'read', 'offline_dinspect']),
    'missing local completion': ('completions', 'ping read serve offline'),
    'interactive skill entry': ('skill', p.skill + '`fixture console-ui`\n'),
    'missing local skill entry': ('skill', p.skill.replace('`fixture offline inspect`', '')),
    'missing local docs': ('docs', p.docs[:p.docs.index('### `fixture console-ui`')]),
    'missing remote docs': ('docs', p.docs.replace('- Wire name: `read`', '- Wire name: `other`')),
    'missing MCP metadata': ('docs', p.docs.replace('- MCP tool: none (local command)', '- Unknown: local')),
}
for name, (field, value) in faults.items():
    bad = copy.deepcopy(p)
    setattr(bad, field, value)
    try:
        suite.check_generation(bad)
    except AssertionError:
        print(f'ok generation rejected {name}')
    else:
        raise AssertionError(f'generation check accepted {name}')
