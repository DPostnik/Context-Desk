# Documentation

Tracked files in this directory describe the app, building, architecture, and
delivered improvements. Private research and working documents belong in
`docs/private/`, which is excluded from the main Git repository.

## Private document revisions

Use this structure for local documents:

```text
docs/private/
  README.md
  CHANGELOG.md
  research/
    <topic>/
      README.md
      YYYY-MM-DD-v001.md
      YYYY-MM-DD-v002.md
```

Each topic's README links to its latest revision. Preserve existing numbered
revisions; create a new file for substantive updates, incrementing the version
even when the date changes. Include the date, status, source, evidence, and
validation limitations in each revision. Record the new path and a brief change
description in the private CHANGELOG, then update the topic's latest link.

This is explicit file-based versioning, not automatic Git history. Private files
and their revision history are not included in commits, pushes, fresh clones, or
Git-based backups. Back up this directory separately if needed. Do not force-add
private documents, personal usage analyses, or raw chat exports to the repository.

Product delivery records remain in the tracked `improvements.md`; private
research recommendations are not evidence of implemented app behavior.
