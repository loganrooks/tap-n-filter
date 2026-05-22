#!/usr/bin/env python3
"""review_journal — per-PR review-recommendation journal tool.

Two subcommands:

  parse-block         Read a comment body from stdin, parse the verdict block,
                      emit JSON to stdout. Exit 2 on validation error.

  sync                Fetch a PR's threads from GitHub (or load from a local
                      JSON file), parse verdict blocks in replies, write a
                      normalized journal file at <journal_dir>/pr-<N>.json.
                      Optionally infer verdicts for threads missing a block.

The CLI surface is documented in tools/review-journal/README.md and pinned by
the shell tests in tests/test_*.sh.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

# Vocabulary defined by ADR-016 and the review-journal spec.
VALID_VERDICTS = {
    "ACCEPTED",
    "ACCEPTED_MODIFIED",
    "DEFERRED",
    "REJECTED_FALSE_POSITIVE",
    "REJECTED_BAD_FIT",
    "REJECTED_REGRESSION",
    "OBSOLETE",
    "DUPLICATE",
}

# Verdicts that require a `commit:` field in the block.
VERDICTS_REQUIRE_COMMIT = {"ACCEPTED", "ACCEPTED_MODIFIED", "OBSOLETE"}

# Verdicts that require a `notes:` field in the block.
VERDICTS_REQUIRE_NOTES = {
    "DEFERRED",
    "REJECTED_FALSE_POSITIVE",
    "REJECTED_BAD_FIT",
    "REJECTED_REGRESSION",
}

VERDICT_BLOCK_FENCE = "review-verdict"
RECONSIDERED_FENCE = "review-verdict-reconsidered"

FINDING_EXCERPT_LEN = 300


# -------------- Block parsing --------------

@dataclass
class VerdictBlock:
    verdict: str
    kind: str  # "verdict" or "reconsidered"
    commit: str | None = None
    finding_category: str | None = None
    reviewer: str | None = None
    notes: str | None = None
    raw: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "kind": self.kind,
            "verdict": self.verdict,
            "commit": self.commit,
            "finding_category": self.finding_category,
            "reviewer": self.reviewer,
            "notes": self.notes,
        }


class BlockValidationError(Exception):
    pass


_BLOCK_PATTERN = re.compile(
    r"```(?P<fence>" + VERDICT_BLOCK_FENCE + r"|" + RECONSIDERED_FENCE + r")\s*\n(?P<body>.*?)\n```",
    re.DOTALL,
)


def find_blocks(body: str) -> list[tuple[str, str]]:
    """Return list of (fence, inner-body) for each verdict block in `body`."""
    return [(m.group("fence"), m.group("body")) for m in _BLOCK_PATTERN.finditer(body)]


def parse_block_body(inner: str) -> dict[str, str]:
    """Parse a key: value block body. Values may span the rest of the line.

    The block is line-based. `notes:` is allowed to span multiple lines so long
    as continuation lines are not key: pairs. This keeps the format simple
    while letting maintainers explain themselves.
    """
    fields: dict[str, list[str]] = {}
    last_key: str | None = None
    KEY_RE = re.compile(r"^([a-z_]+):\s*(.*)$")
    for line in inner.splitlines():
        m = KEY_RE.match(line)
        if m:
            last_key = m.group(1)
            fields.setdefault(last_key, []).append(m.group(2))
        else:
            # Continuation line for the previous key. Skip if no prior key
            # (malformed) or line is whitespace-only.
            if last_key and line.strip():
                fields[last_key].append(line.rstrip())
    return {k: "\n".join(v).strip() for k, v in fields.items()}


def validate_block(parsed: dict[str, str], fence: str) -> VerdictBlock:
    if "verdict" not in parsed:
        raise BlockValidationError("block missing required field: verdict")
    verdict = parsed["verdict"].strip()
    if verdict not in VALID_VERDICTS:
        raise BlockValidationError(
            f"invalid verdict value: {verdict!r}. Allowed: {sorted(VALID_VERDICTS)}"
        )
    commit = parsed.get("commit", "").strip() or None
    notes = parsed.get("notes", "").strip() or None
    if verdict in VERDICTS_REQUIRE_COMMIT and not commit:
        raise BlockValidationError(
            f"verdict={verdict} requires field: commit"
        )
    if verdict in VERDICTS_REQUIRE_NOTES and not notes:
        raise BlockValidationError(
            f"verdict={verdict} requires field: notes"
        )
    return VerdictBlock(
        verdict=verdict,
        kind="reconsidered" if fence == RECONSIDERED_FENCE else "verdict",
        commit=commit,
        finding_category=parsed.get("finding_category", "").strip() or None,
        reviewer=parsed.get("reviewer", "").strip() or None,
        notes=notes,
    )


def parse_first_block(body: str) -> VerdictBlock:
    blocks = find_blocks(body)
    if not blocks:
        raise BlockValidationError("no review-verdict block found")
    fence, inner = blocks[0]
    return validate_block(parse_block_body(inner), fence)


def parse_all_blocks(body: str) -> list[VerdictBlock]:
    out = []
    for fence, inner in find_blocks(body):
        out.append(validate_block(parse_block_body(inner), fence))
    return out


# -------------- Reviewer profiles --------------

# A profile describes a reviewer's bot kind, how to extract severity from its
# finding bodies, and how it auto-resolves threads. The default profile catalog
# below covers the bots tap-n-filter currently uses; the maintainer adds new
# entries via `.review-journal.json`'s `reviewer_profiles` map.
#
# Profile fields:
#   kind                 — free-form. Conventional values:
#                            "bot:agentic-llm"     (CR, Codex, Copilot review, etc.)
#                            "bot:static-analyzer" (e.g., SonarCloud, custom linters)
#                            "bot:author"          (dependabot, renovate)
#                            "human"
#   display_name         — optional, shown in summaries.
#   severity_patterns    — ordered list of {pattern, severity}. First match
#                          wins. Patterns run against the original finding body.
#   auto_resolve_patterns — list of regex strings. A match in any comment body
#                          (including the original) triggers ACCEPTED_MODIFIED
#                          inference. The first capture group, if present, is
#                          treated as the commit sha.
#   notes                — free text describing the reviewer's quirks.

DEFAULT_PROFILES: dict[str, dict[str, Any]] = {
    "coderabbitai": {
        "kind": "bot:agentic-llm",
        "display_name": "CodeRabbit",
        "severity_patterns": [
            {"pattern": r"🔴\s*Critical|\bCritical\b(?=\s*(?:issue|finding|\|))", "severity": "critical"},
            {"pattern": r"🟠\s*Major|\bMajor\b(?=\s*(?:issue|finding|\|))", "severity": "major"},
            {"pattern": r"🟡\s*Minor|\bMinor\b(?=\s*(?:issue|finding|\|))", "severity": "minor"},
            {"pattern": r"⚪\s*Nit|\bNit\b(?=\s*(?:pick|\|))", "severity": "nit"},
        ],
        "auto_resolve_patterns": [
            # Range pattern first — capture the LATER sha (the completion of
            # the range) rather than the earlier one.
            r"(?:✅\s*)?Addressed in commits\s+`?[0-9a-f]{7,40}`?\s+to\s+`?([0-9a-f]{7,40})`?",
            r"(?:✅\s*)?Addressed in commit\s+`?([0-9a-f]{7,40})`?",
        ],
        "notes": "Trial-version of CodeRabbit is the initial driver for the verdict-block discipline.",
    },
    "chatgpt-codex-connector": {
        "kind": "bot:agentic-llm",
        "display_name": "Codex (via chatgpt-codex-connector)",
        "severity_patterns": [
            {"pattern": r"\bP0\b", "severity": "P0"},
            {"pattern": r"\bP1\b", "severity": "P1"},
            {"pattern": r"\bP2\b", "severity": "P2"},
            {"pattern": r"\bP3\b", "severity": "P3"},
        ],
        "auto_resolve_patterns": [],
        "notes": "Triggered by '@codex review'. Posts a single report comment plus per-thread P-rated findings.",
    },
    # Hint for adding GitHub Copilot reviews — maintainer can flip
    # `included_by_default: true` or override patterns once empirical samples
    # are collected. Left here as documentation; not active.
    "copilot-pull-request-reviewer[bot]": {
        "kind": "bot:agentic-llm",
        "display_name": "GitHub Copilot review (placeholder)",
        "severity_patterns": [
            {"pattern": r"\bHigh\b", "severity": "high"},
            {"pattern": r"\bMedium\b", "severity": "medium"},
            {"pattern": r"\bLow\b", "severity": "low"},
        ],
        "auto_resolve_patterns": [],
        "notes": "Placeholder — fill in once GH Copilot review is enabled and a few sample threads are observed.",
    },
}


def merge_profiles(custom: dict[str, dict[str, Any]] | None) -> dict[str, dict[str, Any]]:
    """Merge custom profiles over the defaults. Custom entries fully replace
    the default for the same login (deep-merge would surprise; explicit is
    better). Unknown defaults stay untouched."""
    merged = {k: dict(v) for k, v in DEFAULT_PROFILES.items()}
    if custom:
        for login, prof in custom.items():
            merged[login] = dict(prof)
    return merged


# -------------- Config --------------

@dataclass
class Config:
    enforcement_mode: str = "warning"
    reviewers: list[str] = field(default_factory=lambda: ["coderabbitai", "chatgpt-codex-connector"])
    reviewer_profiles: dict[str, dict[str, Any]] = field(default_factory=dict)
    categories: list[str] = field(default_factory=list)
    journal_dir: str = "docs/governance/review-journal"
    config_root: Path | None = None  # Directory where .review-journal.json was found.

    def resolve_journal_dir(self) -> Path:
        if Path(self.journal_dir).is_absolute():
            return Path(self.journal_dir)
        # Relative to config_root if we found a config, else PWD.
        root = self.config_root or Path.cwd()
        return root / self.journal_dir

    def profile_for(self, reviewer_login: str) -> dict[str, Any]:
        """Return a profile dict, falling back to a human stub if unknown."""
        return self.reviewer_profiles.get(
            reviewer_login,
            {"kind": "human", "severity_patterns": [], "auto_resolve_patterns": []},
        )


def load_config(start: Path | None = None) -> Config:
    """Walk up from `start` (or PWD) looking for `.review-journal.json`."""
    here = (start or Path.cwd()).resolve()
    for d in [here, *here.parents]:
        candidate = d / ".review-journal.json"
        if candidate.is_file():
            try:
                data = json.loads(candidate.read_text())
            except json.JSONDecodeError as e:
                raise SystemExit(f"error: {candidate} is not valid JSON: {e}")
            cfg = Config(
                enforcement_mode=data.get("enforcement_mode", "warning"),
                reviewers=data.get("reviewers", ["coderabbitai", "chatgpt-codex-connector"]),
                reviewer_profiles=merge_profiles(data.get("reviewer_profiles")),
                categories=data.get("categories", []),
                journal_dir=data.get("journal_dir", "docs/governance/review-journal"),
                config_root=d,
            )
            return cfg
    # No config file found — return defaults including the canned profiles.
    return Config(reviewer_profiles=merge_profiles(None))


# -------------- GitHub fetcher --------------

GRAPHQL_QUERY = """
query($owner:String!, $repo:String!, $pr:Int!, $after:String) {
  repository(owner:$owner, name:$repo) {
    pullRequest(number:$pr) {
      reviewThreads(first:100, after:$after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          comments(first:50) {
            nodes {
              id
              author { login }
              body
              createdAt
              url
            }
          }
        }
      }
    }
  }
}
"""


def fetch_threads_via_gh(owner: str, repo: str, pr_number: int) -> list[dict[str, Any]]:
    """Fetch every thread on a PR via `gh api graphql` (paginated)."""
    nodes: list[dict[str, Any]] = []
    after: str | None = None
    while True:
        args = [
            "gh", "api", "graphql",
            "-f", f"query={GRAPHQL_QUERY}",
            "-F", f"owner={owner}",
            "-F", f"repo={repo}",
            "-F", f"pr={pr_number}",
        ]
        if after:
            args += ["-F", f"after={after}"]
        else:
            args += ["-f", "after="]
        proc = subprocess.run(args, capture_output=True, text=True)
        if proc.returncode != 0:
            sys.stderr.write(proc.stderr)
            raise SystemExit(f"gh api graphql failed (exit {proc.returncode})")
        payload = json.loads(proc.stdout)
        rt = payload["data"]["repository"]["pullRequest"]["reviewThreads"]
        nodes.extend(rt["nodes"])
        if not rt["pageInfo"]["hasNextPage"]:
            break
        after = rt["pageInfo"]["endCursor"]
    return nodes


def load_threads_from_file(path: Path) -> list[dict[str, Any]]:
    payload = json.loads(path.read_text())
    return payload["data"]["repository"]["pullRequest"]["reviewThreads"]["nodes"]


# -------------- Inference --------------

# Best-effort regex patterns for inferring a verdict from a reply body or the
# auto-resolution suffix that CodeRabbit appends to its own original comment.

# "Addressed in commit <sha>" or "fixed in <sha>" → ACCEPTED_MODIFIED with sha.
RE_ADDRESSED_COMMIT = re.compile(
    r"(?:✅\s*)?(?:Addressed|Fixed|Resolved|Implemented)\s+in\s+commit\s+`?([0-9a-f]{7,40})`?",
    re.IGNORECASE,
)
# "Addressed in commits <sha1> to <sha2>" → ACCEPTED_MODIFIED with sha2.
RE_ADDRESSED_RANGE = re.compile(
    r"(?:✅\s*)?(?:Addressed|Fixed|Resolved|Implemented)\s+in\s+commits?\s+`?([0-9a-f]{7,40})`?\s+to\s+`?([0-9a-f]{7,40})`?",
    re.IGNORECASE,
)
# "Fixed in <sha>" anywhere in the body.
RE_FIXED_IN = re.compile(r"\bfixed in\s+`?([0-9a-f]{7,40})`?\b", re.IGNORECASE)
# "per ADR-NNN" or "deferred to V0.N" → DEFERRED, capture the reference.
RE_PER_ADR = re.compile(r"\bper\s+(ADR-\d{3})\b", re.IGNORECASE)
RE_PER_ULOG = re.compile(r"\bper\s+(U-\d{3})\b", re.IGNORECASE)
RE_DEFERRED_TO = re.compile(r"\bdeferred(?:\s+to)?\s+(?:to\s+)?(V0\.\d+|ADR-\d{3}|U-\d{3})\b", re.IGNORECASE)
# "already addressed" / "obsolete" → OBSOLETE.
RE_ALREADY_ADDRESSED = re.compile(
    r"\balready\s+(?:addressed|fixed|resolved)\s+(?:in\s+`?([0-9a-f]{7,40})`?)?",
    re.IGNORECASE,
)
RE_OBSOLETE = re.compile(r"\bobsolete\b", re.IGNORECASE)
# "duplicate" / "see thread X" → DUPLICATE.
RE_DUPLICATE = re.compile(r"\b(?:duplicate|same as|see thread)\b", re.IGNORECASE)
# Generic "Deferred" word + we have an ADR/U-log ref in the same body.
RE_DEFERRED_WORD = re.compile(r"\bdeferred\b", re.IGNORECASE)


def infer_verdict(thread: dict[str, Any], profile: dict[str, Any] | None = None) -> VerdictBlock | None:
    """Return a VerdictBlock with kind='verdict' and verdict_source-equivalent
    'inferred' status (caller marks the source). None if nothing matches.

    Honors the reviewer's profile-specific `auto_resolve_patterns` before
    falling back to generic prose patterns.
    """
    comments = thread["comments"]["nodes"]
    if not comments:
        return None
    # We look at the FIRST comment's body (where CR appends "Addressed in
    # commit X") AND any subsequent replies.
    bodies = [c.get("body") or "" for c in comments]
    joined = "\n----\n".join(bodies)

    # 0) Reviewer-profile auto-resolve patterns get first crack. These are
    # what makes the tool adaptable to new bots without code changes.
    if profile:
        for pat in profile.get("auto_resolve_patterns", []) or []:
            try:
                rx = re.compile(pat)
            except re.error:
                continue
            m = rx.search(joined)
            if m:
                commit = m.group(1) if m.lastindex else None
                return VerdictBlock(
                    verdict="ACCEPTED_MODIFIED",
                    kind="verdict",
                    commit=commit,
                    notes=(
                        f"Inferred from {profile.get('display_name') or 'reviewer'} auto-resolve pattern"
                        + (f" citing commit {commit}." if commit else ".")
                    ),
                )

    # 1) Commit range "Addressed in commits A to B" — use B.
    m = RE_ADDRESSED_RANGE.search(joined)
    if m:
        return VerdictBlock(
            verdict="ACCEPTED_MODIFIED",
            kind="verdict",
            commit=m.group(2),
            notes=f"Inferred from auto-resolution range {m.group(1)}..{m.group(2)}.",
        )
    # 2) Single-commit "Addressed in commit X".
    m = RE_ADDRESSED_COMMIT.search(joined)
    if m:
        return VerdictBlock(
            verdict="ACCEPTED_MODIFIED",
            kind="verdict",
            commit=m.group(1),
            notes=f"Inferred from auto-resolution marker citing commit {m.group(1)}.",
        )
    # 3) "Fixed in X" prose in a reply.
    m = RE_FIXED_IN.search(joined)
    if m:
        return VerdictBlock(
            verdict="ACCEPTED_MODIFIED",
            kind="verdict",
            commit=m.group(1),
            notes=f"Inferred from reply citing commit {m.group(1)}.",
        )
    # 4) "already addressed in <sha>" → OBSOLETE if a sha is present, else
    # OBSOLETE with no commit.
    m = RE_ALREADY_ADDRESSED.search(joined)
    if m:
        sha = m.group(1)
        if sha:
            return VerdictBlock(
                verdict="OBSOLETE",
                kind="verdict",
                commit=sha,
                notes=f"Inferred from reply: already addressed in {sha}.",
            )
        return VerdictBlock(
            verdict="OBSOLETE",
            kind="verdict",
            notes="Inferred from reply: already addressed (no commit cited).",
        )
    # 5) DEFERRED — prose contains "deferred" and an ADR/U-log/V0.N ref.
    if RE_DEFERRED_WORD.search(joined):
        adr = RE_PER_ADR.search(joined) or RE_DEFERRED_TO.search(joined)
        ulog = RE_PER_ULOG.search(joined)
        ref = (adr.group(1) if adr else None) or (ulog.group(1) if ulog else None)
        return VerdictBlock(
            verdict="DEFERRED",
            kind="verdict",
            notes=(f"Inferred from reply: deferred per {ref}." if ref else "Inferred from reply: deferred (no reference)."),
        )
    # 6) OBSOLETE — bare "obsolete" word.
    if RE_OBSOLETE.search(joined):
        return VerdictBlock(
            verdict="OBSOLETE",
            kind="verdict",
            notes="Inferred from reply: obsolete.",
        )
    # 7) DUPLICATE.
    if RE_DUPLICATE.search(joined):
        return VerdictBlock(
            verdict="DUPLICATE",
            kind="verdict",
            notes="Inferred from reply: duplicate.",
        )
    return None


# -------------- Thread → record --------------

@dataclass
class ThreadRecord:
    id: str
    path: str | None
    line: int | None
    reviewer: str
    reviewer_kind: str
    severity: str | None
    category: str | None
    finding_excerpt: str
    created_at: str | None
    resolved: bool
    verdict: str | None = None
    verdict_commit: str | None = None
    verdict_notes: str | None = None
    verdict_source: str | None = None  # block | inferred | manual
    reconsidered_verdict: dict[str, Any] | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "path": self.path,
            "line": self.line,
            "reviewer": self.reviewer,
            "reviewer_kind": self.reviewer_kind,
            "severity": self.severity,
            "category": self.category,
            "finding_excerpt": self.finding_excerpt,
            "created_at": self.created_at,
            "resolved": self.resolved,
            "verdict": self.verdict,
            "verdict_commit": self.verdict_commit,
            "verdict_notes": self.verdict_notes,
            "verdict_source": self.verdict_source,
            "reconsidered_verdict": self.reconsidered_verdict,
        }


def extract_severity(body: str, profile: dict[str, Any]) -> str | None:
    """Apply the profile's severity_patterns in order; first match wins."""
    for entry in profile.get("severity_patterns", []) or []:
        try:
            rx = re.compile(entry["pattern"])
        except (re.error, KeyError):
            continue
        if rx.search(body):
            return entry.get("severity")
    return None


def build_record(thread: dict[str, Any], cfg: Config) -> ThreadRecord:
    comments = thread["comments"]["nodes"]
    first = comments[0] if comments else {}
    reviewer = (first.get("author") or {}).get("login", "unknown")
    profile = cfg.profile_for(reviewer)
    body = first.get("body") or ""
    excerpt = body[:FINDING_EXCERPT_LEN].strip()
    return ThreadRecord(
        id=thread["id"],
        path=thread.get("path"),
        line=thread.get("line"),
        reviewer=reviewer,
        reviewer_kind=profile.get("kind", "human"),
        severity=extract_severity(body, profile),
        category=None,
        finding_excerpt=excerpt,
        created_at=first.get("createdAt"),
        resolved=bool(thread.get("isResolved")),
    )


def apply_block_to_record(rec: ThreadRecord, block: VerdictBlock) -> None:
    rec.verdict = block.verdict
    rec.verdict_commit = block.commit
    rec.verdict_notes = block.notes
    rec.verdict_source = "block"
    if block.finding_category:
        rec.category = block.finding_category


def apply_inferred_to_record(rec: ThreadRecord, block: VerdictBlock) -> None:
    rec.verdict = block.verdict
    rec.verdict_commit = block.commit
    rec.verdict_notes = block.notes
    rec.verdict_source = "inferred"
    if block.finding_category and not rec.category:
        rec.category = block.finding_category


def extract_blocks_from_thread(thread: dict[str, Any]) -> tuple[VerdictBlock | None, VerdictBlock | None]:
    """Return (primary, reconsidered) blocks parsed from any reply on the thread."""
    primary: VerdictBlock | None = None
    reconsidered: VerdictBlock | None = None
    for c in thread["comments"]["nodes"][1:]:
        body = c.get("body") or ""
        for block in parse_all_blocks(body):
            if block.kind == "reconsidered":
                reconsidered = block
            elif primary is None:
                primary = block
    return primary, reconsidered


# -------------- Journal write --------------

def sort_threads(records: list[ThreadRecord]) -> list[ThreadRecord]:
    return sorted(records, key=lambda r: (r.reviewer, r.created_at or "", r.id))


def write_journal(out_path: Path, pr_number: int, repo: str, records: list[ThreadRecord], synced_at: str) -> None:
    payload = {
        "pr_number": pr_number,
        "repo": repo,
        "last_synced_at": synced_at,
        "threads": [r.to_dict() for r in records],
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(payload, indent=2) + "\n")


def merge_manual_overrides(existing_path: Path, fresh: list[ThreadRecord]) -> list[ThreadRecord]:
    """If a journal file already exists with `verdict_source: manual` entries,
    preserve those entries' verdict fields over the freshly-derived ones."""
    if not existing_path.is_file():
        return fresh
    try:
        existing = json.loads(existing_path.read_text())
    except (json.JSONDecodeError, OSError):
        return fresh
    manual_by_id = {
        t["id"]: t for t in existing.get("threads", [])
        if t.get("verdict_source") == "manual"
    }
    if not manual_by_id:
        return fresh
    merged: list[ThreadRecord] = []
    for rec in fresh:
        m = manual_by_id.get(rec.id)
        if m:
            rec.verdict = m.get("verdict")
            rec.verdict_commit = m.get("verdict_commit")
            rec.verdict_notes = m.get("verdict_notes")
            rec.verdict_source = "manual"
            if m.get("category"):
                rec.category = m.get("category")
        merged.append(rec)
    return merged


def write_backfill_md(out_path: Path, pr_number: int, repo: str, inferred: list[tuple[ThreadRecord, VerdictBlock]]) -> None:
    lines: list[str] = []
    lines.append(f"# PR #{pr_number} review-journal backfill — {repo}")
    lines.append("")
    lines.append(f"Generated {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}.")
    lines.append("")
    lines.append(
        "Each thread below has an inferred verdict. Confirm by checking the box "
        "and either re-running `extract-pr.sh <N> --accept-inferred` to flip the "
        "source to `manual`, or by hand-editing the journal JSON.")
    lines.append("")
    if not inferred:
        lines.append("_No threads required inference. The journal is complete._")
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text("\n".join(lines) + "\n")
        return

    by_reviewer: dict[str, list[tuple[ThreadRecord, VerdictBlock]]] = {}
    for rec, block in inferred:
        by_reviewer.setdefault(rec.reviewer, []).append((rec, block))

    for reviewer in sorted(by_reviewer.keys()):
        lines.append(f"## {reviewer}")
        lines.append("")
        for rec, block in by_reviewer[reviewer]:
            commit_part = f" — commit `{block.commit}`" if block.commit else ""
            path_part = f"`{rec.path}`" if rec.path else "(no path)"
            line_part = f":{rec.line}" if rec.line else ""
            lines.append(f"- [ ] **{block.verdict}**{commit_part} — {path_part}{line_part} (thread `{rec.id}`)")
            lines.append(f"    - finding: {rec.finding_excerpt[:200]}")
            if block.notes:
                lines.append(f"    - inference: {block.notes}")
            lines.append("")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text("\n".join(lines) + "\n")


def update_index(journal_dir: Path) -> None:
    """Maintain an index.json listing every pr-N.json in the journal dir."""
    entries: list[dict[str, Any]] = []
    for p in sorted(journal_dir.glob("pr-*.json")):
        if p.name == "index.json":
            continue
        try:
            data = json.loads(p.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        entries.append({
            "pr_number": data.get("pr_number"),
            "repo": data.get("repo"),
            "last_synced_at": data.get("last_synced_at"),
            "thread_count": len(data.get("threads", [])),
            "file": p.name,
        })
    index = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "entries": entries,
    }
    (journal_dir / "index.json").write_text(json.dumps(index, indent=2) + "\n")


# -------------- Subcommand: parse-block --------------

def cmd_parse_block(args: argparse.Namespace) -> int:
    body = sys.stdin.read()
    try:
        if args.all:
            blocks = parse_all_blocks(body)
            print(json.dumps([b.to_dict() for b in blocks]))
            return 0
        block = parse_first_block(body)
        print(json.dumps(block.to_dict()))
        return 0
    except BlockValidationError as e:
        sys.stderr.write(f"error: {e}\n")
        return 2


# -------------- Subcommand: sync --------------

def _sync_core(args: argparse.Namespace, infer: bool, write_backfill: bool) -> int:
    cfg = load_config()
    enforce_mode = args.enforce or cfg.enforcement_mode
    if enforce_mode not in {"off", "warning", "strict"}:
        sys.stderr.write(f"error: --enforce must be off | warning | strict (got {enforce_mode!r})\n")
        return 2

    repo_arg = args.repo
    if not repo_arg:
        sys.stderr.write("error: --repo OWNER/REPO is required\n")
        return 2
    if "/" not in repo_arg:
        sys.stderr.write(f"error: --repo must be OWNER/REPO (got {repo_arg!r})\n")
        return 2
    owner, repo = repo_arg.split("/", 1)

    if args.threads_from:
        raw_path = Path(args.threads_from)
        if not raw_path.is_absolute():
            raw_path = Path.cwd() / raw_path
        threads = load_threads_from_file(raw_path)
    else:
        threads = fetch_threads_via_gh(owner, repo, args.pr_number)

    records: list[ThreadRecord] = []
    inferred_pairs: list[tuple[ThreadRecord, VerdictBlock]] = []
    backfill_needed: list[ThreadRecord] = []
    resolve_needed: list[ThreadRecord] = []

    for t in threads:
        rec = build_record(t, cfg)
        primary, reconsidered = extract_blocks_from_thread(t)
        if primary is not None:
            apply_block_to_record(rec, primary)
            if not rec.resolved:
                # Has a verdict but unresolved — RESOLVE NEEDED.
                resolve_needed.append(rec)
        else:
            if rec.resolved:
                if infer:
                    profile = cfg.profile_for(rec.reviewer)
                    block = infer_verdict(t, profile=profile)
                    if block is not None:
                        apply_inferred_to_record(rec, block)
                        inferred_pairs.append((rec, block))
                    else:
                        backfill_needed.append(rec)
                else:
                    backfill_needed.append(rec)
        if reconsidered is not None:
            rec.reconsidered_verdict = {
                "verdict": reconsidered.verdict,
                "commit": reconsidered.commit,
                "notes": reconsidered.notes,
                "finding_category": reconsidered.finding_category,
            }
        records.append(rec)

    records = sort_threads(records)

    if args.journal_dir:
        journal_dir = Path(args.journal_dir)
        if not journal_dir.is_absolute():
            journal_dir = Path.cwd() / journal_dir
    else:
        journal_dir = cfg.resolve_journal_dir()

    journal_dir.mkdir(parents=True, exist_ok=True)
    out_path = journal_dir / f"pr-{args.pr_number}.json"

    records = merge_manual_overrides(out_path, records)

    write_journal(out_path, args.pr_number, repo_arg, records,
                  datetime.now(timezone.utc).isoformat())
    update_index(journal_dir)

    if write_backfill:
        # Drop the manual-source entries from the backfill list — they're
        # already decided.
        inferred_pairs_md = [
            (rec, block) for (rec, block) in inferred_pairs
            if rec.verdict_source != "manual"
        ]
        md_path = journal_dir / f"pr-{args.pr_number}-backfill.md"
        write_backfill_md(md_path, args.pr_number, repo_arg, inferred_pairs_md)

    if args.summary:
        print_summary(records, repo_arg, args.pr_number)

    # Enforcement: emit BACKFILL NEEDED / RESOLVE NEEDED to stderr.
    if enforce_mode != "off":
        for rec in backfill_needed:
            sys.stderr.write(
                f"BACKFILL NEEDED: thread {rec.id} ({rec.path}:{rec.line}) "
                f"by {rec.reviewer} — resolved without a verdict block.\n")
        for rec in resolve_needed:
            sys.stderr.write(
                f"RESOLVE NEEDED: thread {rec.id} ({rec.path}:{rec.line}) "
                f"by {rec.reviewer} — has a verdict block but is unresolved.\n")
        if enforce_mode == "strict" and (backfill_needed or resolve_needed):
            return 1

    return 0


def print_summary(records: list[ThreadRecord], repo: str, pr_number: int) -> None:
    print(f"# Review journal for {repo} PR #{pr_number}")
    print(f"({len(records)} threads)")
    by_reviewer: dict[str, list[ThreadRecord]] = {}
    for r in records:
        by_reviewer.setdefault(r.reviewer, []).append(r)
    for reviewer in sorted(by_reviewer.keys()):
        rs = by_reviewer[reviewer]
        print(f"\n## {reviewer} ({len(rs)} threads)")
        verdicts: dict[str, int] = {}
        for r in rs:
            v = r.verdict or "(no verdict)"
            verdicts[v] = verdicts.get(v, 0) + 1
        for v in sorted(verdicts.keys()):
            print(f"  {v}: {verdicts[v]}")


def cmd_sync(args: argparse.Namespace) -> int:
    return _sync_core(args, infer=False, write_backfill=False)


def cmd_extract(args: argparse.Namespace) -> int:
    return _sync_core(args, infer=True, write_backfill=True)


# -------------- argparse --------------

def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="review_journal", description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    p_parse = sub.add_parser("parse-block", help="Parse a verdict block from stdin")
    p_parse.add_argument("--all", action="store_true", help="Return all blocks in body, not just the first.")
    p_parse.set_defaults(func=cmd_parse_block)

    def add_sync_args(sp: argparse.ArgumentParser) -> None:
        sp.add_argument("pr_number", type=int, help="PR number")
        sp.add_argument("--repo", required=False, help="OWNER/REPO (defaults to env GH_REPO if set)")
        sp.add_argument("--threads-from", help="Read raw GraphQL threads JSON from a file instead of fetching")
        sp.add_argument("--journal-dir", help="Override the journal output directory")
        sp.add_argument("--enforce", choices=["off", "warning", "strict"], help="Enforcement mode")
        sp.add_argument("--summary", action="store_true", help="Print a per-reviewer summary to stdout")

    p_sync = sub.add_parser("sync", help="Sync PR threads to the journal (no inference)")
    add_sync_args(p_sync)
    p_sync.set_defaults(func=cmd_sync)

    p_ext = sub.add_parser("extract", help="Sync + infer verdicts for threads missing a block; write backfill md")
    add_sync_args(p_ext)
    p_ext.add_argument("--accept-inferred", action="store_true", help="(Reserved; inferred verdicts are recorded as `inferred` until human confirmation flips them to `manual`.)")
    p_ext.set_defaults(func=cmd_extract)

    ns = p.parse_args(argv)
    return ns.func(ns)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
