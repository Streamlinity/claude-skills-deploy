#!/usr/bin/env python3
# render-workflows.py — Render the promotion: manual workflows from scripts/templates.
#
# Usage (called by generate-workflow.sh, never directly):
#   python3 render-workflows.py <out_dir>
#
# Reads the values generate-workflow.sh computed from the environment (RW_* names) and
# writes <out_dir>/deploy.yml, promote.yml and rollback.yml.
#
# Template syntax (GitHub Actions owns ${{ }}, so the templates use @@NAME@@):
#   @@NAME@@          replaced by the value of NAME
#   @@LOAD_GATE@@     alone on a line: writes scripts/release-gate.sh to
#                     $RUNNER_TEMP/release-gate.sh and sources it, at that indentation
#   #@if smoke / #@endif   lines kept only when smoke_command is set
#
# Strings from coolify.yaml that a person writes (ci_workflow, release_owners,
# smoke_command) are emitted as JSON strings, which YAML reads as double-quoted scalars.

import json
import os
import re
import sys

import yaml

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TEMPLATES = {
    'deploy.yml': 'deploy-manual.yml.tmpl',
    'promote.yml': 'promote.yml.tmpl',
    'rollback.yml': 'rollback.yml.tmpl',
}
EOF_MARK = 'RELEASE_GATE_EOF'


def die(msg):
    print(f'ERROR: {msg}', file=sys.stderr)
    sys.exit(1)


def load_gate():
    path = os.path.join(SCRIPT_DIR, 'release-gate.sh')
    text = open(path).read()
    if '${{' in text:
        die(f'{path} contains a GitHub Actions expression opener; it would be expanded in the workflow')
    for line in text.splitlines():
        if line.strip() == EOF_MARK:
            die(f'{path} contains a line equal to the heredoc marker {EOF_MARK}')
        if line.startswith('\t'):
            die(f'{path} indents with a tab; YAML block scalars need spaces')
    return text.rstrip('\n').split('\n')


def conditionals(text, flags):
    out, keep = [], [True]
    for line in text.split('\n'):
        m = re.fullmatch(r'\s*#@if (\w+)\s*', line)
        if m:
            keep.append(keep[-1] and flags[m.group(1)])
            continue
        if re.fullmatch(r'\s*#@endif\s*', line):
            if len(keep) == 1:
                die('#@endif without #@if')
            keep.pop()
            continue
        if keep[-1]:
            out.append(line)
    if len(keep) != 1:
        die('#@if without #@endif')
    return '\n'.join(out)


def expand_load_gate(text, gate_lines):
    out = []
    for line in text.split('\n'):
        m = re.fullmatch(r'(\s*)@@LOAD_GATE@@\s*', line)
        if not m:
            out.append(line)
            continue
        ind = m.group(1)
        block = [f'cat > "$RUNNER_TEMP/release-gate.sh" <<\'{EOF_MARK}\''] + gate_lines + [
            EOF_MARK, 'source "$RUNNER_TEMP/release-gate.sh"']
        out.extend((ind + b) if b else '' for b in block)
    return '\n'.join(out)


def main():
    if len(sys.argv) != 2:
        die('usage: render-workflows.py <out_dir>')
    out_dir = sys.argv[1]
    env = os.environ
    smoke = env.get('RW_SMOKE_COMMAND', '')
    values = {
        'SOURCE': env['RW_SOURCE'],
        'CI_WORKFLOW_JSON': json.dumps(env['RW_CI_WORKFLOW']),
        'RELEASE_OWNERS_JSON': json.dumps(env['RW_RELEASE_OWNERS']),
        'SMOKE_COMMAND_JSON': json.dumps(smoke),
        'COOLIFY_URL': env['RW_COOLIFY_URL'],
        'STAGING_APP_UUID': env['RW_STAGING_APP_UUID'],
        'PROD_APP_UUID': env['RW_PROD_APP_UUID'],
        'STAGING_DOMAIN': env['RW_STAGING_DOMAIN'],
        'PROD_DOMAIN': env['RW_PROD_DOMAIN'],
        'HEALTH_CHECK_PATH': env['RW_HEALTH_CHECK_PATH'],
        'REGISTRY_IMAGE_NAME': env['RW_REGISTRY_IMAGE_NAME'],
        'BUILD_CONTEXT': env['RW_BUILD_CONTEXT'],
        'BUILD_DOCKERFILE': env['RW_BUILD_DOCKERFILE'],
        'PACKAGE': env['RW_PACKAGE'],
        'RETENTION': env['RW_RETENTION'],
    }
    gate_lines = load_gate()
    os.makedirs(out_dir, exist_ok=True)
    for out_name, tmpl_name in TEMPLATES.items():
        text = open(os.path.join(SCRIPT_DIR, 'templates', tmpl_name)).read()
        text = conditionals(text, {'smoke': bool(smoke)})
        text = expand_load_gate(text, gate_lines)

        def sub(m):
            if m.group(1) not in values:
                die(f'{tmpl_name}: unknown token @@{m.group(1)}@@')
            return values[m.group(1)]

        text = re.sub(r'@@([A-Z_]+)@@', sub, text)
        if '@@' in text:
            die(f'{tmpl_name}: unreplaced @@ token')
        path = os.path.join(out_dir, out_name)
        with open(path, 'w') as f:
            f.write(text)
        try:
            yaml.safe_load(open(path))
        except yaml.YAMLError as e:
            die(f'{path} is not valid YAML: {e}')
        print(f'WROTE {path}')


if __name__ == '__main__':
    main()
