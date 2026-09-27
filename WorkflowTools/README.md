# Run-scoped history lookup / Сверка с историей на один запуск

English: this local CLI reads the vacancy bank, pipeline, company pages, board
memory and earlier sourcing JSON/Markdown. It builds an inverted lookup once and
returns small evidence references for a batch of compact cards before full JD
qualification. It never collects, applies, changes history, or makes a skip decision.

Русский: локальная утилита читает банк вакансий, CRM, страницы компаний, историю
площадок и прошлые отчёты JSON/Markdown. Она один раз строит индекс и возвращает
ссылки на нужные записи для набора карточек до чтения полных JD. Утилита не добавляет
вакансии, не подаёт заявки, не меняет историю и не принимает решение об исключении.

## Development contract

Python 3.9+ standard library only. Source formats and output version are fixed by
`VERSION = 1`; unsupported bank rows fail explicitly. No package installation,
network, browser or scheduler is needed. Run from any working directory:

```sh
python3 WorkflowTools/history.py build --wiki-root /path/to/super-wiki \
  --index /private/run/history-index.json
python3 WorkflowTools/history.py match --wiki-root /path/to/super-wiki \
  --index /private/run/history-index.json --cards /private/run/cards.json \
  --output /private/run/history-matches.json
python3 -B -m unittest discover -s WorkflowTools -p 'test_*.py'
```

Cards are a JSON array or a browser response with a `cards` array. Required `id` is
opaque and source-scoped; optional `company`, `title`, `url`, `canonicalURL` remain
data. A bare board ID is never equated to a requisition on another board. URL keys
remove only `utm_*` parameters; other queries, signatures, paths and fragments
remain significant. Original URLs are never rewritten or visited.

`known_source_url` means an exact comparison key occurs in a bank Source URL cell,
not that it is canonical, unchanged, qualified or safe to skip. Each bank reference
labels its own `matchKind` as `source_url` or `company_title`; do not transfer the
status of a title-only match to an exact URL match. `possible_role_match`
is company/title only. `history_reference` is an older URL mention;
`company_history` is a token match, which may be a false positive. If the full name
is absent, a trailing legal suffix can be dropped for a `legal_suffix_hint` only;
exact role and URL matching never use this shortening. `no_match` proves
neither novelty nor qualification. Every result requires review. Read current
bank/CRM/company evidence before reusing a decision; conflicting, unknown, reopened
or changed roles still need reconciliation. Canonical URL/requisition resolution
remains the agent's responsibility. No company-wide exclusion or early stop.

References contain a file path and line number or JSON pointer. Current company
and CRM files precede historical mentions. More than six evidence files/rows are
explicitly flagged; follow them as needed. Unknown source URL cell formats are
counted in `unparsedBankURLRows`, not guessed. Legacy tables without source URLs
remain available as hints; `bankRowsWithoutURL` reports their identity limitation. All source paths and SHA-256 hashes
are rechecked before and after matching; additions/deletions/edits reject stale
indices. Concurrent changes after a result still require rereading evidence before
a decision. Malformed/missing sources fail, never silently imply an empty history.

Outputs are private, exclusive-create files (0600); place them in the current run's
private evidence directory, outside the indexed source folders. Never commit them.
The index holds normalized words, URL keys and bank metadata; it is sensitive.
The CLI prints counts/timing only. Measurements are bytes and CPU/wall time, not
model tokens. Index freshness does not replace candidate-profile validation.
