"""Read-only assertions from durable ledger and ground truth, independent of driver output."""
import json
from pathlib import Path
from evidence import digest


class Oracle:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.truth = json.loads((self.directory / 'ground-truth.json').read_text())
        self.events = [json.loads(line) for line in (self.directory / 'ledger.jsonl').read_text().splitlines()]
        assert [e['sequence'] for e in self.events] == list(range(1, len(self.events) + 1))
        assert all(e['run'] == self.truth['run'] for e in self.events)
        assert all(a['monotonic_ns'] <= b['monotonic_ns'] for a, b in zip(self.events, self.events[1:]))

    def of(self, kind):
        return [e['data'] for e in self.events if e['kind'] == kind]

    def coverage(self, rows, exhausted):
        # Exact values and multiplicity, not only set membership or claimed count.
        return exhausted is True and sorted(rows, key=lambda r: r['id']) == self.truth['rows']

    def application(self, receipt):
        accepted = self.of('submitted')
        if len(accepted) != 1 or receipt != accepted[0]:
            return False
        prior = []
        for event in self.events:
            if event['kind'] == 'submitted':
                break
            prior.append(event)
        return (receipt['vacancy'] == 7 and receipt['sha256'] == self.truth['hashes']['cv.pdf']
                and any(e['kind'] == 'validated' and e['data']['ticket'] == receipt['ticket'] for e in prior)
                and any(e['kind'] == 'uploaded' and e['data']['upload'] == receipt['upload']
                        and e['data']['purpose'] == 'cv' and e['data']['item'] == 7
                        and e['data']['sha256'] == receipt['sha256'] for e in prior))

    def replies(self):
        approvals, used, version, count = {}, set(), 1, 0
        for event in self.events:
            data = event['data']
            if event['kind'] == 'incoming':
                version = data['version']
            elif event['kind'] == 'approval':
                approvals[data['token']] = data
            elif event['kind'] == 'sent':
                token = data.get('approval')
                approval = approvals.get(token)
                if (not approval or token in used or data['version'] != version
                        or any(approval[k] != data[k] for k in ('version', 'recipient', 'text'))):
                    return False
                used.add(token)
                count += 1
        return count > 0

    def outputs(self, job, destination):
        names = ('output.mp3', 'transcript.txt')
        return (any(e.get('upload') == job and e.get('purpose') == 'media'
                    and e.get('item') == 7 and e.get('sha256') == self.truth['hashes']['input.mp4']
                    for e in self.of('uploaded'))
                and any(e == {'upload': job, 'state': 'complete'} for e in self.of('processed'))
                and all((Path(destination) / n).is_file() and digest((Path(destination) / n).read_bytes()) == self.truth['hashes'][n] for n in names)
                and all(any(e['job'] == job and e['name'] == n and e['sha256'] == self.truth['hashes'][n] for e in self.of('downloaded')) for n in names))

    def loaded_nonce(self, target, before_ns):
        """Require one consistent pre-attachment nonce in this run/generation."""
        matches = [e['data'].get('detail', {}).get('nonce') for e in self.events
                   if e['kind'] == 'page-event' and e['monotonic_ns'] < before_ns
                   and e['data'].get('target') == target
                   and e['data'].get('top_level') is True
                   and e['data'].get('generation') == self.truth['generations'].get(target)
                   and e['data'].get('kind') == 'loaded']
        if not matches or any(not isinstance(n, str) or not n for n in matches):
            return None
        return matches[0] if len(set(matches)) == 1 else None

    def lifecycle_readback(self, target, since_ns):
        """Host receive times only; quiet readback never asserts cessation."""
        events = [e for e in self.events if e['monotonic_ns'] >= since_ns]
        page = [e for e in events if e['kind'] == 'page-event'
                and e['data'].get('target') == target
                and e['data'].get('generation') == self.truth['generations'].get(target)]
        return dict(page_events=page,
                    decoy_events=[e for e in events if e['kind'] == 'page-event'
                                  and e['data'].get('target') == 'decoy'],
                    site_responses=[e for e in events if e['kind'] == 'site-response'],
                    last_page_receive_ns=max((e['monotonic_ns'] for e in page), default=None),
                    cessation_verified=False,
                    interpretation='Page reports are observations, not proof of absence of future work')
