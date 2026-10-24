#!/usr/bin/env python3
"""Compare production scanners without writing to real session roots."""
import argparse
import hashlib
import datetime as dt
import json
import os
from pathlib import Path
import shutil
import subprocess
import time


def run(command, **kwargs):
    result = subprocess.run(command, check=True, text=True, capture_output=True, **kwargs)
    return result.stdout.strip()


def scan_loop(binary, fixture, target, count, env):
    # The app only reads logs. Keep fixture writes and timestamp formatting in this process.
    process = subprocess.Popen([str(binary), str(fixture), 'external-loop-root', str(target), str(count)],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, env=env)
    try:
        if process.stdout.readline().strip() != 'READY':
            raise RuntimeError('scanner did not become ready')
        for i in range(count):
            start = time.monotonic()
            stamp = dt.datetime.now(dt.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
            if '/.codex/' in str(target):
                row = {'type': 'event_msg', 'timestamp': stamp,
                       'payload': {'type': 'user_message', 'message': f'append-{i}'}}
            else:
                row = {'type': 'user', 'timestamp': stamp, 'message': {'content': f'append-{i}'}}
            with target.open('a') as stream:
                stream.write(json.dumps(row) + '\n')
            process.stdin.write(stamp + '\n')
            process.stdin.flush()
            if process.stdout.readline().strip() != 'ACK':
                raise RuntimeError('scanner did not acknowledge append')
            if i + 1 < count:
                time.sleep(max(0, 0.05 - (time.monotonic() - start)))
        stdout, stderr = process.communicate(timeout=15)
        if process.returncode:
            raise RuntimeError(f'scanner exited {process.returncode}: {stderr}')
        return json.loads(stdout.strip())
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--base', default='095cd826783dbe8a83976b2b1cc57c0e58ff3c7d')
    parser.add_argument('--events', type=int, default=30)
    parser.add_argument('--loop-events', type=int, default=200)
    parser.add_argument('--reuse-binaries', action='store_true')
    args = parser.parse_args()
    root = args.root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    env = {k: v for k, v in os.environ.items() if k not in ('CLAUDE_CONFIG_DIR', 'CODEX_HOME')}
    baseline = root / 'baseline'
    baseline.mkdir(exist_ok=True)
    if not args.reuse_binaries:
        names = run(['git', 'ls-tree', '-r', '--name-only', args.base, 'Sources/NotchCore']).splitlines()
        for name in names:
            if not name.endswith('.swift'):
                continue
            source = run(['git', 'show', f'{args.base}:{name}']) + '\n'
            if name.endswith('/LogScanner.swift'):
                source = source.replace('var didRead:', 'var didOpen: ((String) -> Void)?\n    var didRead:')
                source = source.replace('guard var f = files[path], let h = FileHandle(forReadingAtPath: path) else { return }',
                                        'guard var f = files[path] else { return }\n        didOpen?(path)\n        guard let h = FileHandle(forReadingAtPath: path) else { return }')
                source = source.replace('guard let h = FileHandle(forReadingAtPath: path) else { return nil }',
                                        'didOpen?(path)\n        guard let h = FileHandle(forReadingAtPath: path) else { return nil }')
                source = source.replace('(try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []',
                                        'didList?(dir.path)\n        return (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []')
            (baseline / Path(name).name).write_text(source)
        harness = 'scripts/SessionBenchmark/Incremental/main.swift'
        for mode, sources in [('before', baseline.glob('*.swift')), ('after', Path('Sources/NotchCore').glob('*.swift'))]:
            run(['xcrun', 'swiftc', '-O', '-whole-module-optimization', '-j', '2', '-o', str(root / mode),
                 *map(str, sorted(sources)), harness])
    home = Path.home()
    trees = [home / '.claude/projects', home / '.codex/sessions']
    entries = []
    for tree in trees:
        for directory, dirs, files in os.walk(tree):
            dirs[:] = [d for d in dirs if not d.startswith('.')]
            for name in files:
                path = Path(directory) / name
                if path.suffix == '.jsonl':
                    entries.append((path, path.stat()))
    targets = {
        vendor: max((p for p, _ in entries if marker in str(p)), key=lambda p: p.stat().st_mtime)
        for vendor, marker in [('claude', '.claude/projects/'), ('codex', '.codex/sessions/')]
    }
    active_copies = {}
    for target in targets.values():
        size = target.stat().st_size
        offset = max(0, size - (2 << 20))
        with target.open('rb') as source:
            source.seek(offset)
            active_copies[target] = source.read(size - offset)
    digest = hashlib.sha256()
    for source in sorted(Path('Sources/NotchCore').glob('*.swift')):
        digest.update(str(source).encode())
        digest.update(source.read_bytes())
    result = {'after_source_sha256': digest.hexdigest(), 'base': run(['git', 'rev-parse', args.base]), 'events': args.events, 'loop_events': args.loop_events,
              'real_jsonl_files': len(entries), 'real_jsonl_bytes': sum(s.st_size for _, s in entries),
              'real_targets': {k: str(v) for k, v in targets.items()},
              'event_workload': 'read-only replay: exact file, containing directory, and vendor log root (reported broad-rescan hot path); no writes to real trees',
              'loop_workload': 'external writer at up to 20 Hz with vendor-root notifications and acknowledgement; CPU belongs to scanner only; frozen bounded active copies, real names/mtimes, cold content replaced by {}'}
    for mode in ('before', 'after'):
        result[mode] = {}
        for vendor, target in targets.items():
            for event_kind in ('exact', 'directory', 'root'):
                raw = run([str(root / mode), str(home), event_kind, str(target), str(args.events)], env=env)
                result[mode][vendor + '_' + event_kind] = json.loads(raw)
            fixture = root / ('fixture-' + mode + '-' + vendor)
            if fixture.exists():
                shutil.rmtree(fixture)
            # Preserve names and mtimes without duplicating gigabytes of cold content.
            for path, info in entries:
                copy = fixture / path.relative_to(home)
                copy.parent.mkdir(parents=True, exist_ok=True)
                copy.write_bytes(active_copies[target] if path == target else b'{}\n')
                os.utime(copy, ns=(info.st_atime_ns, info.st_mtime_ns))
            copy_target = fixture / target.relative_to(home)
            loop = result[mode][vendor + '_loop'] = scan_loop(root / mode, fixture, copy_target, args.loop_events, env)
            if loop['observed_appends'] != args.loop_events:
                raise RuntimeError(f'{mode}/{vendor}: synthetic append was not delivered')
    result['speedups'] = {
        key: result['before'][key]['cpu_ms_per_event'] / max(1e-9, result['after'][key]['cpu_ms_per_event'])
        for key in result['after']
    }
    result['scratch_agent_counts_match'] = all(result['before'][v + '_loop']['final_agents'] == result['after'][v + '_loop']['final_agents'] for v in targets)
    result['bounded_opens'] = all(value['opens_per_event'] <= 1 for value in result['after'].values())
    result['bounded_listings'] = all(value['listings_per_event'] == 0 for value in result['after'].values())
    result['passed'] = result['scratch_agent_counts_match'] and result['bounded_opens'] and result['bounded_listings'] and all(
        result['speedups'][vendor + '_' + kind] >= 10
        for vendor in targets for kind in ('root', 'loop'))
    (root / 'incremental-results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
