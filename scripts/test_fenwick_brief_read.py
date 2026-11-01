import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location('reader', Path(__file__).with_name('fenwick-brief-read.py'))
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)


def archive(name='report.json', start=100000, status='complete'):
    data = io.BytesIO()
    with zipfile.ZipFile(data, 'w') as z:
        z.writestr(name, json.dumps({'start': start, 'end': 186400, 'status': status}))
    return data.getvalue()


class Tests(unittest.TestCase):
    def test_reads_only_exact_report_without_extraction(self):
        self.assertEqual(reader.report_from_zip(archive())['status'], 'complete')
        with self.assertRaises(ValueError):
            reader.report_from_zip(archive('../report.json'))

    def test_wrong_window_rejected_and_partial_preserved(self):
        with self.assertRaises(ValueError):
            reader.report_from_zip(archive(start=1))
        self.assertEqual(reader.report_from_zip(archive(status='partial'))['status'], 'partial')

    def test_latest_failed_run_not_silently_replaced(self):
        responses = [json.dumps({'private': True}).encode(), json.dumps({'workflow_runs': [
            {'id': 42, 'run_attempt': 2, 'status': 'completed', 'conclusion': 'failure'},
            {'id': 41, 'run_attempt': 1, 'status': 'completed', 'conclusion': 'success'}]}).encode(),
            json.dumps({'artifacts': [{'id': 123, 'name': 'fenwick-42-2', 'expired': False}]}).encode(), archive(status='partial')]
        calls = []
        def run(args, **kwargs):
            calls.append(args)
            return type('Result', (), {'stdout': responses.pop(0)})()
        with patch.object(reader.subprocess, 'run', run):
            result = reader.load({'repository': 'test/private', 'workflow': 'morning.yml', 'githubExecutable': '/usr/local/bin/gh'})
        self.assertEqual(result['conclusion'], 'failure')
        self.assertEqual(result['runID'], '42')
        self.assertTrue(all(c[1:4] == ['api', '--method', 'GET'] for c in calls))
        self.assertEqual(calls[0][-1], 'repos/test/private')
        self.assertIn('/42/', calls[2][-1])

    def test_public_source_rejected(self):
        with patch.object(reader.subprocess, 'run', return_value=type('R', (), {'stdout': b'{"private":false}'})()):
            with self.assertRaises(ValueError):
                reader.load({'repository': 'test/public', 'workflow': 'morning.yml', 'githubExecutable': '/usr/local/bin/gh'})


if __name__ == '__main__':
    unittest.main()
