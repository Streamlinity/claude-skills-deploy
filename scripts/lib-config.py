#!/usr/bin/env python3
# lib-config.py — Safe config extraction for shell scripts.
#
# Eliminates shell-injection risk from variable-interpolated python3 -c calls.
# All values are output via shlex.quote so eval in bash is injection-safe.
#
# Usage:
#   python3 lib-config.py emit-yaml-vars <yaml_path>
#   python3 lib-config.py emit-yaml-workflow-vars <yaml_path>
#   python3 lib-config.py emit-dns-vars <yaml_path>
#   python3 lib-config.py get-json-field <json_path> <server_alias> <field>
#   python3 lib-config.py list-environments <yaml_path>

import sys
import json
import shlex


def q(v):
    return shlex.quote(str(v) if v is not None else '')


def emit_yaml_vars(path):
    import yaml
    d = yaml.safe_load(open(path))
    img = d.get('registry', {}).get('image', '')
    last = img.rsplit('/', 1)[-1]
    name, tag = (img.rsplit(':', 1) if ':' in last else (img, 'latest'))
    env = d.get('environments', {})
    stg = env.get('staging', {})
    prd = env.get('production', {})
    pairs = [
        ('PROJECT',             d.get('project', '')),
        ('DEPLOY_SERVER',       d.get('deploy_server', '')),
        ('SERVER_ALIAS',        d.get('server', '')),
        ('SERVER',              d.get('server', '')),        # validate.sh compat
        ('DOPPLER_PROJECT',     d.get('doppler_project', '')),
        ('REGISTRY_IMAGE',      img),
        ('REGISTRY_IMAGE_NAME', name),
        ('REGISTRY_IMAGE_TAG',  tag),
        ('STAGING_DOMAIN',      stg.get('domain', '')),
        ('STAGING_DOPPLER',     stg.get('doppler_environment', '')),
        ('PROD_DOMAIN',         prd.get('domain', '')),
        ('PROD_DOPPLER',        prd.get('doppler_environment', '')),
        ('ENV_VARS',            ' '.join(d.get('env_vars', []))),
        ('APP_PORT',            str(d.get('port', 3000))),
        ('HEALTH_CHECK_PATH',   d.get('health_check_path', '/api/health')),
    ]
    for k, v in pairs:
        print(f'{k}={q(v)}')


def emit_yaml_workflow_vars(path):
    import yaml
    d = yaml.safe_load(open(path))
    img = d.get('registry', {}).get('image', '')
    # Strip any :tag suffix — the workflow appends its own SHA tag, and a
    # double tag (name:latest:abc1234) is an invalid Docker reference.
    last = img.rsplit('/', 1)[-1]
    name = img.rsplit(':', 1)[0] if ':' in last else img
    env = d.get('environments', {})
    stg = env.get('staging', {})
    prd = env.get('production', {})
    ids = d.get('coolify_app_ids', {})
    build = d.get('build', {})
    pairs = [
        ('PROJECT',             d.get('project', '')),
        ('SERVER_ALIAS',        d.get('server', '')),
        ('REGISTRY_IMAGE',      img),
        ('REGISTRY_IMAGE_NAME', name),
        ('RETENTION',           str(d.get('registry', {}).get('retention_tags', 5))),
        ('STAGING_DOMAIN',      stg.get('domain', '')),
        ('PROD_DOMAIN',         prd.get('domain', '')),
        ('HEALTH_CHECK_PATH',   d.get('health_check_path', '/api/health')),
        ('BUILD_CONTEXT',       build.get('context', '.')),
        ('BUILD_DOCKERFILE',    build.get('dockerfile', './Dockerfile')),
        ('STAGING_APP_UUID',    ids.get('staging') or ''),
        ('PROD_APP_UUID',       ids.get('production') or ''),
    ]
    for k, v in pairs:
        print(f'{k}={q(v)}')


def list_environments(path):
    # One tab-separated line per environment: name<TAB>domain<TAB>doppler_environment.
    # Environments are emitted in manifest order. staging and production are
    # REQUIRED (the generated workflow's same-image promotion pipeline is
    # staging -> production); any additional environments (qa, preview, ...)
    # are provisioned identically but do not participate in the CI pipeline.
    import yaml
    d = yaml.safe_load(open(path))
    envs = d.get('environments', {}) or {}
    errors = []
    for required in ('staging', 'production'):
        if required not in envs:
            errors.append(f'ERROR: environments.{required} is required '
                          f'(the CI pipeline promotes staging -> production)')
    for name, cfg in envs.items():
        cfg = cfg or {}
        if not cfg.get('domain'):
            errors.append(f'ERROR: environments.{name}.domain is empty')
        if not cfg.get('doppler_environment'):
            errors.append(f'ERROR: environments.{name}.doppler_environment is empty')
        if '\t' in name or '\t' in str(cfg.get('domain', '')) or '\t' in str(cfg.get('doppler_environment', '')):
            errors.append(f'ERROR: environments.{name} contains a tab character')
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        sys.exit(1)
    for name, cfg in envs.items():
        print(f"{name}\t{cfg['domain']}\t{cfg['doppler_environment']}")


def emit_dns_vars(path):
    import yaml
    d = yaml.safe_load(open(path))
    dns = d.get('dns', {})
    provider = (dns.get('provider', 'none') or 'none')
    env = d.get('environments', {})
    if not provider or provider == 'none':
        # Emit sentinel understood by both provision.sh and validate.sh
        print('dns_provider=none')
        print('DNS_PROVIDER=none')
        return
    zone_name   = dns.get('zone_name', '')
    cred_source = dns.get('credential_source', 'doppler')
    cred_key    = dns.get('credential_key', '')
    staging_dom = env.get('staging', {}).get('domain', '')
    prod_dom    = env.get('production', {}).get('domain', '')
    # provision.sh uses lowercase names; validate.sh uses mixed
    pairs = [
        ('dns_provider',      provider),
        ('dns_zone_name_raw', zone_name),
        ('dns_cred_source',   cred_source),
        ('dns_cred_key',      cred_key),
        ('DNS_PROVIDER',      provider),
        ('provider',          provider),
        ('zone_name',         zone_name),
        ('cred_source',       cred_source),
        ('cred_key',          cred_key),
        ('staging_domain',    staging_dom),
        ('prod_domain',       prod_dom),
    ]
    for k, v in pairs:
        print(f'{k}={q(v)}')


def get_json_field(json_path, server_alias, field):
    d = json.load(open(json_path))
    val = d.get('servers', {}).get(server_alias, {}).get(field, '')
    print(val if val is not None else '')


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'emit-yaml-vars':
        emit_yaml_vars(sys.argv[2])
    elif cmd == 'emit-yaml-workflow-vars':
        emit_yaml_workflow_vars(sys.argv[2])
    elif cmd == 'emit-dns-vars':
        emit_dns_vars(sys.argv[2])
    elif cmd == 'list-environments':
        list_environments(sys.argv[2])
    elif cmd == 'get-json-field':
        get_json_field(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        print(f'ERROR: unknown command {repr(cmd)}', file=sys.stderr)
        sys.exit(1)
