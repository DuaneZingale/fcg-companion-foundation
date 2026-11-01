#!/usr/bin/env python3
"""Read a private Fenwick Actions report. Never extract or execute artifact contents."""
import argparse
import io
import json
import os
import re
import subprocess
import sys
import zipfile


def report_from_zip(data):
    if len(data) > 15_000_000:
        raise ValueError('Artifact too large')
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        matches = [x for x in archive.infolist() if x.filename == 'report.json']
        if len(matches) != 1 or matches[0].file_size > 5_000_000:
            raise ValueError('Missing or oversized report')
        report = json.loads(archive.read(matches[0]))
    if report.get('end', 0) - report.get('start', 0) != 86400:
        raise ValueError('Unexpected report window')
    if report.get('status') not in ('complete', 'partial', 'running'):
        raise ValueError('Unexpected report status')
    return report


def load(config):
    repo = config['repository']
    workflow = config['workflow']
    gh = config['githubExecutable']
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo):
        raise ValueError('Invalid repository')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+\.yml', workflow) or not os.path.isabs(gh):
        raise ValueError('Invalid reader configuration')

    def api(path, binary=False):
        # GET only. No shell, URLs from mail, mutation commands or credential output.
        env = {**os.environ, 'GH_PROMPT_DISABLED': '1', 'GH_HOST': 'github.com'}
        endpoint = f'repos/{repo}' + (f'/{path}' if path else '')
        data = subprocess.run([gh, 'api', '--method', 'GET', endpoint],
                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, timeout=25, check=True, env=env).stdout
        return data if binary else json.loads(data)

    if not api('')['private']:
        raise ValueError('Brief source must be private')
    runs = api(f'actions/workflows/{workflow}/runs?per_page=10')['workflow_runs']
    if not runs:
        raise ValueError('No cloud runs yet')
    latest = runs[0]
    run = next((x for x in runs if x['status'] == 'completed'), None)
    if not run:
        raise ValueError('First cloud run has not completed')
    # A failed latest completed run is shown as failed, never silently replaced by an all-clear.
    artifacts = api(f'actions/runs/{int(run["id"])}/artifacts?per_page=100')['artifacts']
    name = f'fenwick-{int(run["id"])}-{int(run["run_attempt"])}'
    matches = [a for a in artifacts if a['name'] == name and not a['expired']]
    if len(matches) != 1:
        raise ValueError('Latest cloud report unavailable or expired')
    report = report_from_zip(api(f'actions/artifacts/{int(matches[0]["id"])}/zip', binary=True))
    return {'runID': str(run['id']), 'conclusion': run.get('conclusion') or 'unknown',
            'latestStatus': latest['status'], 'latestRunID': str(latest['id']), 'report': report}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', required=True)
    args = parser.parse_args()
    try:
        with open(args.config) as f:
            config = json.load(f)
        print(json.dumps(load(config)))
        return 0
    except Exception:
        # Provider payloads and authentication details never go to app logs.
        print('Cloud brief unavailable; check GitHub sign-in and the latest run.', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
