#!/usr/bin/env python3
"""Exercise an evaluation worker/runtime in a NEW disposable installation.

Creates no Steam account or game installation and never targets the normal app.
The C fixture performs GPU clear/readback without opening a window.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worker', type=Path, required=True)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    root = output / 'installation'
    worker = args.worker.resolve()

    def call(command, *extra):
        result = subprocess.run([str(worker), command, '--root', str(root), *map(str, extra)],
                                capture_output=True, text=True, timeout=300)
        (output / (command + '.jsonl')).write_text(result.stdout)
        if result.returncode:
            raise RuntimeError(command + ': ' + result.stdout[-2000:])
        return [json.loads(line) for line in result.stdout.splitlines()]

    call('status')
    archive = args.archive.resolve()
    with archive.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    # The version comes from the importer's proof, not an unverified filename.
    proof = json.loads(Path(str(archive).removesuffix('.tar.gz') + '.proof.json').read_text())
    if proof['archive_sha256'] != digest:
        raise ValueError('Runtime import proof does not match archive')
    call('install-runtime', '--archive', archive, '--sha256', digest, '--version', proof['version'])
    try:
        call('prepare')
        report = call('parity-report')[-1]
        env = report['launch_environment']
        assert env['WINEPREFIX'] == str(root / 'environment')
        assert env['CX_GRAPHICS_BACKEND'] == 'd3dmetal'
        assert not any(key.startswith('DXMT_') for key in env)
        engine = root / 'runtimes' / proof['version']
        log = output / 'device-smoke.log'
        mappings = ''
        with log.open('w') as stream:
            process = subprocess.Popen([str(engine / 'bin/wine'), str(args.fixture.resolve())],
                                       env=env, stdout=stream, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 90
                while process.poll() is None and time.monotonic() < deadline:
                    if 'result=PASS' in log.read_text(errors='replace'):
                        result = subprocess.run(['/usr/sbin/lsof', '-a', '-p', str(process.pid), '-d', 'txt', '-Fn'],
                                                capture_output=True, text=True, timeout=10)
                        mappings = result.stdout
                        break
                    time.sleep(.1)
                process.wait(timeout=10)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=10)
        text = log.read_text(errors='replace')
        expected = str(engine / 'lib/external/D3DMetal.framework/Versions/A/D3DMetal')
        if process.returncode or 'result=PASS' not in text or expected not in mappings or 'winemetal.so' in mappings:
            raise RuntimeError('D3DMetal GPU validation failed: ' + text[-3000:])
        result = {'graphics_backend': 'd3dmetal', 'gptk_version': proof['gptk_version'],
                  'gpu_clear_readback': True, 'apple_framework_mapped': True,
                  'dxmt_not_mapped': True, 'windowless': True, 'game_benchmark_performed': False,
                  'runtime_sha256': digest}
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2), flush=True)
    finally:
        call('stop')


if __name__ == '__main__':
    main()
