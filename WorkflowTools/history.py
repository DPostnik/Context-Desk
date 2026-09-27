#!/usr/bin/env python3
"""Run-scoped, read-only evidence lookup. Never classifies a vacancy as eligible or rejected."""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time
import unicodedata
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

VERSION = 1
URL = re.compile(r'https?://[^\s<>"\'|]+')


def normalize(value):
    return ' '.join(re.findall(r'[^\W_]+', unicodedata.normalize('NFKC', value).casefold()))


def url_key(value):
    """Keep identity-bearing query parameters and fragments; only drop utm_* tracking."""
    try:
        parsed = urlsplit(value.strip())
        if parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username or parsed.password:
            return None
        query = [(k, v) for k, v in parse_qsl(parsed.query, keep_blank_values=True) if not k.lower().startswith('utm_')]
        return urlunsplit((parsed.scheme, parsed.netloc.lower(), parsed.path, urlencode(query), parsed.fragment))
    except ValueError:
        return None


def urls(text):
    for match in URL.finditer(text):
        key = url_key(match.group().rstrip('.,;)]`'))
        if key:
            yield key


def bank_url_keys(cell):
    # A whole bare URL or Markdown link is identity evidence. Mixed prose is only a hint.
    value = cell.strip().strip('`')
    markdown = re.fullmatch(r'\[[^\]]*\]\((https?://.*)\)', value)
    if markdown:
        value = markdown.group(1)
    if re.fullmatch(r'https?://[^\s<>"\'|]+', value):
        key = url_key(value)
        return [key] if key else []
    return []


def source_files(root):
    base = root / 'wiki/job-search'
    required = [base / 'vacancy-bank.md', base / 'pipeline.md', base / 'runtime/job-board-memory.md']
    if any(not p.is_file() for p in required) or not (base / 'companies').is_dir() or not (base / 'sourcing-runs').is_dir():
        raise ValueError('history_sources_missing')
    paths = required + sorted((base / 'companies').rglob('*.md')) + sorted(
        p for p in (base / 'sourcing-runs').rglob('*') if p.suffix in ('.md', '.json') and p.is_file())
    if any(not p.resolve().is_relative_to(root) or p.is_symlink() for p in paths):
        raise ValueError('history_source_outside_root')
    return sorted(set(paths))


def manifest(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in source_files(root)}


def require_fresh(index, root):
    if index.get('version') != VERSION or index.get('root') != str(root):
        raise ValueError('history_index_scope_mismatch')
    if manifest(root) != index['sources']:
        raise ValueError('history_changed_rebuild_index')


def json_text(value, pointer=''):
    if isinstance(value, str):
        yield pointer or '/', value
    elif isinstance(value, dict):
        for key, item in value.items():
            escaped = str(key).replace('~', '~0').replace('/', '~1')
            yield from json_text(item, pointer + '/' + escaped)
    elif isinstance(value, list):
        for number, item in enumerate(value):
            yield from json_text(item, pointer + '/' + str(number))


def table_cells(line):
    body = line.strip().strip('|')
    cells, current, code, wiki = [], '', '', 0
    for piece in re.split(r'(\\.|`+|\[\[|\]\]|\|)', body):
        if piece.startswith('`'):
            if not code:
                code = piece
            elif code == piece:
                code = ''
        elif not code:
            if piece == '[[':
                wiki += 1
            elif piece == ']]':
                wiki = max(0, wiki - 1)
            elif piece == '|' and not wiki:
                cells.append(current.strip())
                current = ''
                continue
        current += piece
    if code or wiki:
        raise ValueError('unsupported_vacancy_bank_row')
    return cells + [current.strip()]


def bank_rows(text, path):
    header = []
    for number, line in enumerate(text.splitlines(), 1):
        if not line.startswith('|'):
            continue
        parts = table_cells(line)
        if parts[0] == 'ID':
            header = parts
        elif re.fullmatch(r'V-\d+', parts[0]):
            row = dict(zip(header, parts))
            if len(parts) != len(header) or not {'ID', 'Vacancy'} <= row.keys() or not ('Status' in row or 'Result' in row):
                raise ValueError('unsupported_vacancy_bank_row')
            source = row.get('Source URL', '')
            keys = bank_url_keys(source)
            role = re.split(r'\s+[—–]\s+', row['Vacancy'], maxsplit=1)
            yield {'vacancyID': row['ID'], 'company': role[0] if len(role) == 2 else '',
                   'title': role[1] if len(role) == 2 else row['Vacancy'],
                   'status': row.get('Status', row.get('Result', '')),
                   'urls': keys, 'unparsedURL': bool(source not in ('', '—', '-') and not keys),
                   'path': path, 'line': number}


def build(root):
    started = time.monotonic()
    sources, records, banks = {}, [], []
    terms, references, bank_urls, roles = (defaultdict(list) for _ in range(4))
    source_bytes = 0
    for path in source_files(root):
        raw = path.read_bytes()
        source_bytes += len(raw)
        relative = str(path.relative_to(root))
        sources[relative] = hashlib.sha256(raw).hexdigest()
        text = raw.decode('utf-8')
        if path == root / 'wiki/job-search/vacancy-bank.md':
            for row in bank_rows(text, relative):
                number = len(banks)
                banks.append(row)
                for url in row['urls']:
                    bank_urls[url].append(number)
                if row['company']:
                    roles[normalize(row['company']) + '\n' + normalize(row['title'])].append(number)
        entries = json_text(json.loads(text)) if path.suffix == '.json' else enumerate(text.splitlines(), 1)
        for locator, content in entries:
            if not content.strip():
                continue
            number = len(records)
            records.append({'path': relative, 'pointer' if path.suffix == '.json' else 'line': locator})
            for term in set(normalize(URL.sub(' ', content)).split()):
                terms[term].append(number)
            for url in set(urls(content)):
                references[url].append(number)
    if not banks:
        raise ValueError('vacancy_bank_rows_missing')
    index = {'version': VERSION, 'root': str(root), 'sources': sources, 'records': records, 'terms': terms,
             'urlReferences': references, 'bank': banks, 'bankURLs': bank_urls, 'roles': roles,
             'sourceBytes': source_bytes, 'bankRowsWithoutURL': sum(not row['urls'] for row in banks),
             'unparsedBankURLRows': sum(row['unparsedURL'] for row in banks), 'builtAt': time.time()}
    require_fresh(index, root)
    index['buildSeconds'] = time.monotonic() - started
    return index


def match(index, root, cards, limit=6):
    started = time.monotonic()
    require_fresh(index, root)
    if not isinstance(cards, list) or len(cards) > 10000:
        raise ValueError('cards_array_required_max_10000')
    result = []
    for card in cards:
        if not isinstance(card, dict) or not isinstance(card.get('id'), str):
            raise ValueError('card_id_required')
        for key in ('company', 'title', 'url', 'canonicalURL'):
            if key in card and (not isinstance(card[key], str) or len(card[key]) > 8192):
                raise ValueError('invalid_card_field')
        company, title = normalize(card.get('company', '')), normalize(card.get('title', ''))
        keys = {key for field in ('url', 'canonicalURL') if (key := url_key(card.get(field, '')))}
        exact = sorted({n for key in keys for n in index['bankURLs'].get(key, [])})
        possible = index['roles'].get(company + '\n' + title, []) if company and title else []
        url_refs = {n for key in keys for n in index['urlReferences'].get(key, [])}
        def company_hits(words):
            sets = [set(index['terms'].get(term, [])) for term in set(words)]
            return set.intersection(*sets) if sets else set()
        company_refs = company_hits(company.split())
        company_match = 'name_tokens' if company_refs else 'none'
        # A legal suffix can differ in historical prose. This fallback is only a hint;
        # exact role/URL identity above never uses the shortened employer name.
        words = company.split()
        while len(words) > 1 and words[-1] in {'corporation', 'corp', 'inc', 'ltd', 'limited', 'llc', 'plc', 'gmbh'}:
            words.pop()
        if not company_refs and words != company.split():
            company_refs = company_hits(words)
            if company_refs:
                company_match = 'legal_suffix_hint'
        # Exact reference first, then current company/CRM evidence before historical runs.
        ordered = sorted(url_refs | company_refs, key=lambda n: (
            n not in url_refs, '/sourcing-runs/' in index['records'][n]['path'] or
            '/runtime/' in index['records'][n]['path'], n))
        evidence = []
        seen_paths = set()
        for number in ordered:
            ref = index['records'][number]
            if ref['path'] in seen_paths:
                continue
            seen_paths.add(ref['path'])
            if len(evidence) < limit:
                evidence.append(ref)
        classification = ('known_source_url' if exact else 'possible_role_match' if possible else
                          'history_reference' if url_refs else 'company_history' if company_refs else 'no_match')
        row_numbers = sorted(set(exact) | set(possible))
        bank_evidence = [{**{k: v for k, v in index['bank'][n].items() if k not in ('urls', 'unparsedURL')},
                          'matchKind': 'source_url' if n in exact else 'company_title'} for n in row_numbers[:limit]]
        result.append({'id': card['id'], 'classification': classification,
                       'companyMatch': company_match, 'bankMatches': bank_evidence, 'bankMatchCount': len(row_numbers),
                       'evidence': evidence, 'evidenceFileCount': len(seen_paths),
                       'moreEvidence': len(row_numbers) > limit or len(seen_paths) > limit,
                       'reviewRequired': True})
    require_fresh(index, root)
    return {'version': VERSION, 'historyBuiltAt': index['builtAt'],
            'sourceDigest': hashlib.sha256(json.dumps(index['sources'], sort_keys=True).encode()).hexdigest(),
            'summary': dict(Counter(row['classification'] for row in result)),
            'cardCount': len(result), 'sourceCount': len(index['sources']), 'sourceBytes': index['sourceBytes'],
            'unparsedBankURLRows': index['unparsedBankURLRows'],
            'bankRowsWithoutURL': index['bankRowsWithoutURL'],
            'matchSeconds': time.monotonic() - started, 'modelTokens': None, 'matches': result}


def write_new(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        json.dump(value, stream, ensure_ascii=False, separators=(',', ':'))
        stream.flush()
        os.fsync(stream.fileno())


def main():
    parser = argparse.ArgumentParser(description='Read-only history evidence lookup / Поиск свидетельств в истории без её изменения')
    parser.add_argument('operation', choices=('build', 'match'))
    parser.add_argument('--wiki-root', required=True, type=Path)
    parser.add_argument('--index', required=True, type=Path)
    parser.add_argument('--cards', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    root = args.wiki_root.resolve()
    try:
        if args.operation == 'build':
            index = build(root)
            write_new(args.index, index)
            print(json.dumps({k: index[k] for k in ('version', 'sourceBytes', 'buildSeconds')} | {'sourceCount': len(index['sources'])}))
        else:
            if args.cards is None or args.output is None:
                raise ValueError('cards_and_output_required')
            index = json.loads(args.index.read_text())
            cards = json.loads(args.cards.read_text())
            if isinstance(cards, dict):
                cards = cards.get('cards')
            result = match(index, root, cards)
            write_new(args.output, result)
            print(json.dumps({k: v for k, v in result.items() if k != 'matches'}, ensure_ascii=False))
    except (ValueError, OSError) as error:
        print(json.dumps({'error': str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
