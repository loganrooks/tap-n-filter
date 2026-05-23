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
import tempfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

# Schema version for the journal JSON files. Bumped when the on-disk shape
# changes incompatibly. Minor bumps for additive fields with safe defaults;
# major bumps require a migration path.
SCHEMA_VERSION = "1.0"

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
# DUPLICATE is included because the notes field is where the reference to
# the primary thread lives ("same as thread <id>"). Without notes, a
# DUPLICATE verdict carries no link to what it's duplicating, which defeats
# its purpose and produces incomplete journal records.
VERDICTS_REQUIRE_NOTES = {
    "DEFERRED",
    "REJECTED_FALSE_POSITIVE",
    "REJECTED_BAD_FIT",
    "REJECTED_REGRESSION",
    "DUPLICATE",
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


_QUOTED_RE = re.compile(r'^["\'](.*)["\']$')


def _unquote(value: str) -> str:
    """Strip surrounding whitespace and matching quotes from a block value."""
    v = value.strip()
    m = _QUOTED_RE.match(v)
    if m:
        return m.group(1).strip()
    return v


def parse_block_body(inner: str) -> dict[str, str]:
    """Parse a key: value block body. Values may span the rest of the line.

    The block is line-based. `notes:` is allowed to span multiple lines so long
    as continuation lines are not key: pairs. This keeps the format simple
    while letting maintainers explain themselves.

    Values surrounded by matching single or double quotes are unquoted; this
    keeps the format friendly to copy-pasting from places that auto-quote.
    """
    fields: dict[str, list[str]] = {}
    last_key: str | None = None
    KEY_RE = re.compile(r"^([a-z_]+):\s*(.*)$")
    # Tracks whether the value started as a single line (eligible for
    # quote-stripping) versus accumulated continuation lines (which must NOT
    # be stripped of quotes because they're prose).
    single_line: dict[str, bool] = {}
    for line in inner.splitlines():
        m = KEY_RE.match(line)
        if m:
            last_key = m.group(1)
            fields.setdefault(last_key, []).append(m.group(2))
            # Mark single-line on first sight; flip to False if a continuation
            # comes through.
            single_line.setdefault(last_key, True)
        else:
            # Continuation line for the previous key. Skip if no prior key
            # (malformed) or line is whitespace-only.
            if last_key and line.strip():
                fields[last_key].append(line.rstrip())
                single_line[last_key] = False
            elif last_key and not line.strip() and fields.get(last_key):
                # Empty line within a multi-paragraph value — preserve as a
                # blank line to keep paragraph structure.
                fields[last_key].append("")
                single_line[last_key] = False

    out: dict[str, str] = {}
    for k, parts in fields.items():
        joined = "\n".join(parts).strip()
        if single_line.get(k, True):
            joined = _unquote(joined)
        out[k] = joined
    return out


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
            r"(?i)(?:✅\s*)?Addressed in commits\s+`?[0-9a-f]{7,40}`?\s+to\s+`?([0-9a-f]{7,40})`?",
            r"(?i)(?:✅\s*)?Addressed in commit\s+`?([0-9a-f]{7,40})`?",
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
    inference_rules: list[dict[str, Any]] = field(default_factory=list)
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
        """Return a profile dict, falling back to a human stub if unknown.

        Looks up by canonical login first; if not found, scans every profile's
        `aliases` list. The first profile whose canonical login OR aliases
        contains `reviewer_login` wins.
        """
        if reviewer_login in self.reviewer_profiles:
            return self.reviewer_profiles[reviewer_login]
        for canonical, prof in self.reviewer_profiles.items():
            aliases = prof.get("aliases") or []
            if reviewer_login in aliases:
                return prof
        return {"kind": "human", "severity_patterns": [], "auto_resolve_patterns": []}

    def canonical_login_for(self, reviewer_login: str) -> str:
        """Resolve a reviewer login to its canonical profile key. If the login
        already IS the canonical key, return it unchanged. If it matches an
        alias, return the profile key it aliases to. Otherwise return the
        original login (no profile registered)."""
        if reviewer_login in self.reviewer_profiles:
            return reviewer_login
        for canonical, prof in self.reviewer_profiles.items():
            if reviewer_login in (prof.get("aliases") or []):
                return canonical
        return reviewer_login

    def is_tracked_reviewer(self, reviewer_login: str) -> bool:
        """True if the reviewer (or one of its aliases) is in `cfg.reviewers`.
        Used by enforcement to scope BACKFILL/RESOLVE policy violations to the
        configured reviewer allowlist."""
        if reviewer_login in self.reviewers:
            return True
        # An alias counts if the canonical login is tracked.
        canonical = self.canonical_login_for(reviewer_login)
        return canonical in self.reviewers


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
                inference_rules=list(data.get("inference_rules", []) or []),
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
          comments(first:100) {
            pageInfo { hasNextPage endCursor }
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

# Follow-up query: fetch additional comment pages on a single thread.
COMMENTS_PAGE_QUERY = """
query($thread_id:ID!, $after:String) {
  node(id: $thread_id) {
    ... on PullRequestReviewThread {
      comments(first:100, after:$after) {
        pageInfo { hasNextPage endCursor }
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
"""


def _paginate_thread_comments(thread: dict[str, Any]) -> None:
    """If a thread has more than 100 comments, fetch the rest and append.

    Mutates the thread dict in place so downstream parsers see the full list.
    GitHub's GraphQL caps any single connection page at 100; long-lived review
    threads (frequent re-reviews, lots of discussion) can exceed that, and the
    verdict block is often in the most recent reply.
    """
    comments_conn = thread.get("comments") or {}
    page_info = comments_conn.get("pageInfo") or {}
    if not page_info.get("hasNextPage"):
        return
    after = page_info.get("endCursor")
    nodes = comments_conn.setdefault("nodes", [])
    while after:
        proc = subprocess.run(
            ["gh", "api", "graphql",
             "-f", f"query={COMMENTS_PAGE_QUERY}",
             "-F", f"thread_id={thread['id']}",
             "-F", f"after={after}"],
            capture_output=True, text=True,
        )
        if proc.returncode != 0:
            sys.stderr.write(
                f"warning: comment pagination on thread {thread.get('id', '?')} "
                f"failed (gh exit {proc.returncode}); some comments may be missing.\n"
            )
            return
        try:
            payload = json.loads(proc.stdout)
        except json.JSONDecodeError:
            sys.stderr.write(
                f"warning: comment pagination on thread {thread.get('id', '?')} "
                f"returned non-JSON; some comments may be missing.\n"
            )
            return
        page = (payload.get("data") or {}).get("node", {}).get("comments") or {}
        page_nodes = page.get("nodes") or []
        nodes.extend(page_nodes)
        pi = page.get("pageInfo") or {}
        if not pi.get("hasNextPage"):
            break
        after = pi.get("endCursor")


def fetch_threads_via_gh(owner: str, repo: str, pr_number: int) -> list[dict[str, Any]]:
    """Fetch every thread on a PR via `gh api graphql` (paginated).

    Threads are fetched in pages of 100. Each thread's nested `comments`
    connection is also paginated (see `_paginate_thread_comments`) so that
    long discussion threads' later replies — where verdict blocks often
    live — aren't silently dropped.
    """
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
    # Top-level threads paginated; now paginate any thread whose comments
    # connection overflows. Most threads have < 5 comments; pagination here
    # only fires for long discussion threads.
    for thread in nodes:
        _paginate_thread_comments(thread)
    return nodes


def load_threads_from_file(path: Path) -> list[dict[str, Any]]:
    payload = json.loads(path.read_text())
    return payload["data"]["repository"]["pullRequest"]["reviewThreads"]["nodes"]


# -------------- Inference rules engine --------------

# Inference rules are data, not code. Each rule is a dict with:
#
#   name              — human label, shown in the inferred notes.
#   pattern           — Python regex run against the candidate text.
#   match_against     — one of "all_bodies" (default), "reply_only",
#                       "original_only". Determines which comment text the
#                       rule sees.
#   verdict           — one of the VALID_VERDICTS to emit on match.
#   commit_group      — int. If set, the named capture group is treated as
#                       the commit sha and recorded in verdict_commit.
#   ref_group         — int. If set, the named capture group is treated as
#                       a reference (ADR, U-log, thread id, etc.) and
#                       substituted into the notes_template as {ref}.
#   notes_template    — string. Free-form; supports {commit}, {ref}, {match}
#                       placeholders. {match} is the entire matched span.
#   applies_to_reviewer — string. If set, only fires for threads where the
#                       canonical reviewer login matches (or its aliases).
#                       Omit for global rules.
#
# Default rules below encode the patterns the previous hardcoded heuristics
# covered. The config can extend or override this list.

DEFAULT_INFERENCE_RULES: list[dict[str, Any]] = [
    # CR auto-resolve range form — "Addressed in commits A to B" → final sha.
    {
        "name": "cr-auto-resolve-range",
        "pattern": r"(?i)(?:✅\s*)?Addressed in commits\s+`?[0-9a-f]{7,40}`?\s+to\s+`?([0-9a-f]{7,40})`?",
        "match_against": "all_bodies",
        "verdict": "ACCEPTED_MODIFIED",
        "commit_group": 1,
        "notes_template": "Inferred from auto-resolve range; final commit {commit}.",
        "applies_to_reviewer": "coderabbitai",
    },
    # CR / generic auto-resolve single commit.
    {
        "name": "auto-resolve-single-commit",
        "pattern": r"(?i)(?:✅\s*)?(?:Addressed|Fixed|Resolved|Implemented) in commit\s+`?([0-9a-f]{7,40})`?",
        "match_against": "all_bodies",
        "verdict": "ACCEPTED_MODIFIED",
        "commit_group": 1,
        "notes_template": "Inferred from auto-resolve marker citing commit {commit}.",
    },
    # Generic "Fixed in <sha>" in a reply.
    {
        "name": "fixed-in-commit",
        "pattern": r"(?i)\bfixed in\s+`?([0-9a-f]{7,40})`?\b",
        "match_against": "all_bodies",
        "verdict": "ACCEPTED_MODIFIED",
        "commit_group": 1,
        "notes_template": "Inferred from reply citing commit {commit}.",
    },
    # "already addressed in <sha>" → OBSOLETE.
    {
        "name": "already-addressed-with-commit",
        "pattern": r"(?i)\balready\s+(?:addressed|fixed|resolved)\s+in\s+`?([0-9a-f]{7,40})`?",
        "match_against": "all_bodies",
        "verdict": "OBSOLETE",
        "commit_group": 1,
        "notes_template": "Inferred from reply: already addressed in {commit}.",
    },
    # "Deferred per ADR-NNN" / "Deferred per U-NNN" → DEFERRED.
    # Scoped to reply_only so the reviewer's own finding text mentioning
    # "deferred per ADR-X" (e.g., "we already deferred this per ADR-005,
    # but now I think it should be revisited") does not auto-classify the
    # thread as DEFERRED.
    {
        "name": "deferred-per-adr",
        "pattern": r"\b[Dd]eferred\b[^\n]{0,200}\bper\s+(ADR-\d{3})",
        "match_against": "reply_only",
        "verdict": "DEFERRED",
        "ref_group": 1,
        "notes_template": "Inferred from reply: deferred per {ref}.",
    },
    {
        "name": "deferred-per-ulog",
        "pattern": r"\b[Dd]eferred\b[^\n]{0,200}\bper\s+(U-\d{3})",
        "match_against": "reply_only",
        "verdict": "DEFERRED",
        "ref_group": 1,
        "notes_template": "Inferred from reply: deferred per {ref}.",
    },
    # "Deferred to V0.N"
    {
        "name": "deferred-to-version",
        "pattern": r"\b[Dd]eferred\b[^\n]{0,200}\b(V0\.\d+)\b",
        "match_against": "reply_only",
        "verdict": "DEFERRED",
        "ref_group": 1,
        "notes_template": "Inferred from reply: deferred to {ref}.",
    },
    # Bare "deferred" — last-resort DEFERRED with no ref. Reply-only.
    {
        "name": "deferred-bare",
        "pattern": r"\b[Dd]eferred\b",
        "match_against": "reply_only",
        "verdict": "DEFERRED",
        "notes_template": "Inferred from reply: deferred (no reference).",
    },
    # NOTE: a previous "obsolete-bare" rule (emit OBSOLETE on the bare word)
    # was removed because OBSOLETE requires a commit per the validator, and
    # the bare-word match has none. The richer `already-addressed-with-commit`
    # rule above still catches the legitimate OBSOLETE-with-commit case.
    # "duplicate" / "same as" / "see thread" → DUPLICATE. Reply-only so a
    # reviewer flagging "duplicate code" in their finding doesn't auto-close
    # the thread.
    {
        "name": "duplicate-bare",
        "pattern": r"\b(?:duplicate|same as|see thread)\b",
        "match_against": "reply_only",
        "verdict": "DUPLICATE",
        "notes_template": "Inferred from reply: duplicate.",
    },
]


def _select_bodies(comments: list[dict[str, Any]], scope: str) -> str:
    """Return the joined text to match against, per the rule's scope."""
    if not comments:
        return ""
    if scope == "original_only":
        return comments[0].get("body") or ""
    if scope == "reply_only":
        return "\n----\n".join((c.get("body") or "") for c in comments[1:])
    # default: all_bodies
    return "\n----\n".join((c.get("body") or "") for c in comments)


def _render_template(template: str, *, commit: str | None, ref: str | None, match: str | None) -> str:
    """Best-effort template render with safe defaults for missing values."""
    return (template or "").format(
        commit=commit or "(no-commit)",
        ref=ref or "(no-ref)",
        match=match or "",
    )


def run_inference_rules(
    thread: dict[str, Any],
    rules: list[dict[str, Any]],
    reviewer_login: str,
    canonical_login: str | None = None,
    reviewer_aliases: list[str] | None = None,
) -> VerdictBlock | None:
    """Try each rule in order; return on first match. None if no rule fires.

    A rule's `applies_to_reviewer` (if set) matches when:
      - it equals the observed `reviewer_login` (the GitHub author), OR
      - it equals the `canonical_login` (the profile key the alias resolves to),
        OR
      - it appears in the profile's `aliases` list.
    This three-way check lets a maintainer scope a rule to a canonical bot
    identity even when threads are authored under one of its aliases.
    """
    comments = thread["comments"]["nodes"]
    if not comments:
        return None
    canonical = canonical_login or reviewer_login
    aliases = set(reviewer_aliases or [])
    for rule in rules:
        applies = rule.get("applies_to_reviewer")
        if applies:
            if applies != reviewer_login and applies != canonical and applies not in aliases:
                # The rule is scoped to a specific reviewer identity that
                # doesn't match this thread.
                continue
        pattern = rule.get("pattern")
        if not pattern:
            continue
        try:
            rx = re.compile(pattern)
        except re.error:
            # Skip malformed regex rather than crashing the whole sync.
            sys.stderr.write(
                f"warning: skipping inference rule {rule.get('name', '?')} — invalid regex.\n"
            )
            continue
        verdict = rule.get("verdict")
        if verdict not in VALID_VERDICTS:
            sys.stderr.write(
                f"warning: skipping inference rule {rule.get('name', '?')} — invalid verdict {verdict!r}.\n"
            )
            continue
        scope = rule.get("match_against", "all_bodies")
        text = _select_bodies(comments, scope)
        m = rx.search(text)
        if not m:
            continue
        commit_group = rule.get("commit_group")
        ref_group = rule.get("ref_group")
        try:
            commit = m.group(commit_group) if commit_group else None
            ref = m.group(ref_group) if ref_group else None
        except (IndexError, re.error, TypeError) as e:
            # IndexError if the integer group is out of range or the named
            # group doesn't exist; re.error in older Pythons for missing
            # group; TypeError if the config value is not int-coercible.
            # Any of these means the rule is misconfigured — log and skip
            # rather than crash the sync.
            sys.stderr.write(
                f"warning: skipping inference rule {rule.get('name', '?')} — "
                f"bad commit_group/ref_group ({e!r}).\n"
            )
            continue
        notes = _render_template(
            rule.get("notes_template", ""),
            commit=commit, ref=ref, match=m.group(0),
        )
        return VerdictBlock(
            verdict=verdict,
            kind="verdict",
            commit=commit,
            notes=notes,
        )
    return None


def assemble_inference_rules(cfg: Config, profile: dict[str, Any] | None) -> list[dict[str, Any]]:
    """Compose the rule list to run for a given reviewer thread:
       1) reviewer-profile-level rules (highest priority);
       2) profile's auto_resolve_patterns, lifted to ACCEPTED_MODIFIED rules
          (legacy/sugar form);
       3) repo-config rules (additions / overrides for cross-cutting cases);
       4) DEFAULT_INFERENCE_RULES (last-resort fallbacks).
    """
    out: list[dict[str, Any]] = []
    if profile:
        out.extend(profile.get("inference_rules", []) or [])
        for pat in profile.get("auto_resolve_patterns", []) or []:
            out.append({
                "name": "profile-auto-resolve",
                "pattern": pat,
                "verdict": "ACCEPTED_MODIFIED",
                "commit_group": 1,
                "notes_template": (
                    f"Inferred from {profile.get('display_name') or 'reviewer'} "
                    f"auto-resolve pattern citing commit {{commit}}."
                ),
                "match_against": "all_bodies",
            })
    out.extend(cfg.inference_rules)
    out.extend(DEFAULT_INFERENCE_RULES)
    return out


def infer_verdict(
    thread: dict[str, Any],
    cfg: Config,
    profile: dict[str, Any] | None = None,
    reviewer_login: str = "",
) -> VerdictBlock | None:
    """Backward-compatible wrapper. Composes the rules and runs them."""
    rules = assemble_inference_rules(cfg, profile)
    aliases = (profile or {}).get("aliases") or []
    canonical = cfg.canonical_login_for(reviewer_login) if reviewer_login else None
    return run_inference_rules(
        thread, rules, reviewer_login,
        canonical_login=canonical,
        reviewer_aliases=aliases,
    )


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
    outdated: bool = False
    verdict: str | None = None
    verdict_commit: str | None = None
    verdict_refs: list[str] = field(default_factory=list)
    verdict_notes: str | None = None
    verdict_source: str | None = None  # block | inferred | manual (extensible)
    reconsidered_verdict: dict[str, Any] | None = None
    verdict_history: list[dict[str, Any]] = field(default_factory=list)
    extras: dict[str, Any] = field(default_factory=dict)

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
            "outdated": self.outdated,
            "verdict": self.verdict,
            "verdict_commit": self.verdict_commit,
            "verdict_refs": list(self.verdict_refs),
            "verdict_notes": self.verdict_notes,
            "verdict_source": self.verdict_source,
            "reconsidered_verdict": self.reconsidered_verdict,
            "verdict_history": list(self.verdict_history),
            "extras": dict(self.extras),
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
    author = first.get("author")
    if author and isinstance(author, dict):
        reviewer = author.get("login") or "unknown"
    else:
        reviewer = "unknown"
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
        outdated=bool(thread.get("isOutdated")),
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
    """Return (primary, reconsidered) blocks parsed from any reply on the thread.

    A malformed block in one reply must NOT crash the whole sync. We emit a
    stderr warning naming the thread and skip just that reply; other replies
    and other threads continue to be processed normally.
    """
    primary: VerdictBlock | None = None
    reconsidered: VerdictBlock | None = None
    for c in thread["comments"]["nodes"][1:]:
        body = c.get("body") or ""
        try:
            blocks = parse_all_blocks(body)
        except BlockValidationError as e:
            sys.stderr.write(
                f"warning: malformed review-verdict block on thread "
                f"{thread.get('id', '?')} (comment {c.get('id', '?')}): {e}\n"
            )
            continue
        for block in blocks:
            if block.kind == "reconsidered":
                reconsidered = block
            elif primary is None:
                primary = block
    return primary, reconsidered


# -------------- Journal write --------------

def sort_threads(records: list[ThreadRecord]) -> list[ThreadRecord]:
    return sorted(records, key=lambda r: (r.reviewer, r.created_at or "", r.id))


def _atomic_write(path: Path, body: str) -> None:
    """Write body to path atomically (temp file + os.replace).

    Two parallel runs of the tool can't leave a half-written JSON file behind;
    one process's write wholly succeeds before the other's, and at no instant
    is the file empty or truncated.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_str = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp-", suffix=path.name)
    tmp = Path(tmp_str)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(body)
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            try:
                tmp.unlink()
            except OSError:
                pass


def write_journal(out_path: Path, pr_number: int, repo: str, records: list[ThreadRecord], synced_at: str) -> None:
    payload = {
        "schema_version": SCHEMA_VERSION,
        "pr_number": pr_number,
        "repo": repo,
        "last_synced_at": synced_at,
        "threads": [r.to_dict() for r in records],
    }
    _atomic_write(out_path, json.dumps(payload, indent=2) + "\n")


def _history_entry(source: str, verdict: str | None, by: str = "tool", note: str | None = None) -> dict[str, Any]:
    e: dict[str, Any] = {
        "at": datetime.now(timezone.utc).isoformat(),
        "source": source,
        "verdict": verdict,
        "by": by,
    }
    if note:
        e["note"] = note
    return e


def merge_with_existing(existing_path: Path, fresh: list[ThreadRecord]) -> list[ThreadRecord]:
    """Merge a freshly-derived record list with an existing journal file:

    - `verdict_source: manual` entries take precedence — their verdict fields
      win and overwrite the fresh values.
    - `extras` from any prior record is preserved (downstream consumers attach
      data to the journal without participating in the sync).
    - `verdict_history` accumulates. A history entry is appended whenever the
      verdict_source transitions or the verdict value changes.
    """
    def _seed_history(rec: ThreadRecord) -> None:
        # Only seed history for inferred verdicts (the inference event is the
        # decision worth timestamping). Block-derived verdicts are already
        # audited by the block on GitHub; their "birth" is the comment's
        # createdAt. Manual verdicts that arrive without prior history get a
        # seed too — they're a maintainer decision worth recording.
        if not rec.verdict or rec.verdict_history:
            return
        if rec.verdict_source in {"inferred", "manual"}:
            rec.verdict_history = [_history_entry(rec.verdict_source, rec.verdict)]

    if not existing_path.is_file():
        for rec in fresh:
            _seed_history(rec)
        return fresh
    try:
        existing = json.loads(existing_path.read_text())
    except (json.JSONDecodeError, OSError):
        return fresh
    by_id = {t["id"]: t for t in existing.get("threads", [])}
    for rec in fresh:
        prior = by_id.get(rec.id)
        if not prior:
            _seed_history(rec)
            continue
        # Carry over extras unchanged.
        if isinstance(prior.get("extras"), dict):
            rec.extras = dict(prior["extras"])
        # Carry over history.
        prior_history = list(prior.get("verdict_history") or [])
        rec.verdict_history = prior_history
        # Manual override wins.
        if prior.get("verdict_source") == "manual":
            rec.verdict = prior.get("verdict")
            rec.verdict_commit = prior.get("verdict_commit")
            rec.verdict_notes = prior.get("verdict_notes")
            rec.verdict_source = "manual"
            if prior.get("category"):
                rec.category = prior.get("category")
            if prior.get("verdict_refs"):
                rec.verdict_refs = list(prior.get("verdict_refs") or [])
        # Detect source / verdict transition vs the last history entry; append
        # a new history record if anything changed.
        last = prior_history[-1] if prior_history else None
        if rec.verdict or rec.verdict_source:
            changed = (
                last is None
                or last.get("source") != rec.verdict_source
                or last.get("verdict") != rec.verdict
            )
            if changed:
                rec.verdict_history.append(_history_entry(rec.verdict_source or "unknown", rec.verdict))
    return fresh


# Backward-compat alias for older callers.
merge_manual_overrides = merge_with_existing


def _sanitize_excerpt(text: str, max_len: int = 200) -> str:
    """Defang reviewer-supplied text for inclusion in the backfill markdown.

    Findings frequently contain raw `<details>`, fenced code, and CR badges
    that would break the surrounding markdown when interpolated verbatim
    into a bullet list. Strategy:
      - Collapse any whitespace run (including newlines) to a single space.
      - Replace backticks with a single quote so they don't open code spans.
      - Backslash-escape `<` so HTML-ish tags don't render.
      - Truncate to `max_len` characters with a literal ellipsis.
    """
    flat = " ".join((text or "").split())
    flat = flat.replace("`", "'").replace("<", "\\<")
    if len(flat) > max_len:
        flat = flat[:max_len].rstrip() + "…"
    return flat


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
            # Reviewer findings often contain raw markdown (`<details>`, fenced
            # code, badges) that would leak into the backfill doc and break its
            # rendering. Collapse to one line + sanitize the inline characters
            # that confuse markdown parsers.
            lines.append(f"    - finding: {_sanitize_excerpt(rec.finding_excerpt)}")
            if block.notes:
                lines.append(f"    - inference: {_sanitize_excerpt(block.notes)}")
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
        "schema_version": SCHEMA_VERSION,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "entries": entries,
    }
    _atomic_write(journal_dir / "index.json", json.dumps(index, indent=2) + "\n")


# -------------- Subcommand: validate --------------

REQUIRED_THREAD_FIELDS = {
    "id", "path", "line", "reviewer", "reviewer_kind", "severity", "category",
    "finding_excerpt", "created_at", "resolved", "verdict", "verdict_commit",
    "verdict_notes", "verdict_source", "reconsidered_verdict",
}


def validate_journal(payload: dict[str, Any]) -> list[str]:
    """Return a list of validation errors. Empty list ⇒ journal is well-formed."""
    errors: list[str] = []
    sv = payload.get("schema_version")
    if not sv:
        errors.append("missing required top-level field: schema_version")
    elif not isinstance(sv, str) or not sv.startswith("1."):
        errors.append(f"unsupported schema_version: {sv!r} (expected 1.x)")
    for key in ("pr_number", "repo", "last_synced_at", "threads"):
        if key not in payload:
            errors.append(f"missing required top-level field: {key}")
    # Check `threads` is present AND a list. Don't coerce falsy non-list values
    # ({}, "", 0) to [] — they should be explicit type errors, not silent passes.
    threads_raw = payload.get("threads")
    if threads_raw is None:
        # Missing entirely is caught by the top-level required-key check above;
        # nothing more to validate here.
        return errors
    if not isinstance(threads_raw, list):
        errors.append(f"threads field is not a list (got {type(threads_raw).__name__})")
        return errors
    threads = threads_raw
    for idx, t in enumerate(threads):
        prefix = f"thread[{idx}] (id={t.get('id', '?')})"
        if not isinstance(t, dict):
            errors.append(f"{prefix}: is not a dict")
            continue
        missing = REQUIRED_THREAD_FIELDS - set(t.keys())
        for m in sorted(missing):
            errors.append(f"{prefix}: missing field {m!r}")
        verdict = t.get("verdict")
        if verdict is not None and verdict not in VALID_VERDICTS:
            errors.append(
                f"{prefix}: invalid verdict value {verdict!r}. Allowed: {sorted(VALID_VERDICTS)}"
            )
        # Per-verdict required fields.
        if verdict in VERDICTS_REQUIRE_COMMIT and not t.get("verdict_commit"):
            errors.append(f"{prefix}: verdict={verdict} requires verdict_commit")
        if verdict in VERDICTS_REQUIRE_NOTES and not t.get("verdict_notes"):
            errors.append(f"{prefix}: verdict={verdict} requires verdict_notes")
        # extras shape, if present.
        extras = t.get("extras")
        if extras is not None and not isinstance(extras, dict):
            errors.append(f"{prefix}: extras must be a dict if present")
        # verdict_history shape, if present.
        history = t.get("verdict_history")
        if history is not None and not isinstance(history, list):
            errors.append(f"{prefix}: verdict_history must be a list if present")
    return errors


def cmd_validate(args: argparse.Namespace) -> int:
    path = Path(args.path)
    if not path.is_file():
        sys.stderr.write(f"error: {path} does not exist\n")
        return 2
    try:
        payload = json.loads(path.read_text())
    except json.JSONDecodeError as e:
        sys.stderr.write(f"error: {path} is not valid JSON: {e}\n")
        return 2
    errors = validate_journal(payload)
    if not errors:
        if args.verbose:
            print(f"OK: {path} validates clean.")
        return 0
    for err in errors:
        sys.stderr.write(f"{err}\n")
    return 1


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

    # --repo wins if passed; otherwise fall back to GH_REPO env var (matches
    # `gh`'s own convention). The CLI help advertises this fallback.
    repo_arg = args.repo or os.environ.get("GH_REPO")
    if not repo_arg:
        sys.stderr.write("error: --repo OWNER/REPO required (or set GH_REPO env var)\n")
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
                    block = infer_verdict(t, cfg, profile=profile, reviewer_login=rec.reviewer)
                    if block is not None:
                        apply_inferred_to_record(rec, block)
                        inferred_pairs.append((rec, block))
                    else:
                        backfill_needed.append(rec)
                else:
                    backfill_needed.append(rec)
        if reconsidered is not None:
            # A reconsidered block supersedes the original verdict. Push the
            # original into history (so the chain of custody is preserved) and
            # swap the record's current verdict fields to the reconsidered
            # values.
            if rec.verdict:
                rec.verdict_history.append({
                    "at": datetime.now(timezone.utc).isoformat(),
                    "source": rec.verdict_source or "block",
                    "verdict": rec.verdict,
                    "by": "tool",
                    "note": "Superseded by reconsidered block",
                })
            rec.reconsidered_verdict = {
                "verdict": reconsidered.verdict,
                "commit": reconsidered.commit,
                "notes": reconsidered.notes,
                "finding_category": reconsidered.finding_category,
            }
            rec.verdict = reconsidered.verdict
            rec.verdict_commit = reconsidered.commit
            rec.verdict_notes = reconsidered.notes
            if reconsidered.finding_category:
                rec.category = reconsidered.finding_category
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

    # Enforcement: emit BACKFILL NEEDED / RESOLVE NEEDED to stderr — but only
    # for reviewers in `cfg.reviewers`. Threads by untracked authors (humans,
    # bots not in the allowlist) don't trigger policy violations even if they
    # lack a verdict block.
    #
    # Additionally: a thread that became `verdict_source: manual` via
    # merge_with_existing is the maintainer's confirmed final state — it must
    # not appear in BACKFILL NEEDED even if the current PR's replies have no
    # parseable block.
    if enforce_mode != "off":
        backfill_filtered = [
            r for r in backfill_needed
            if cfg.is_tracked_reviewer(r.reviewer) and r.verdict_source != "manual"
        ]
        resolve_filtered = [
            r for r in resolve_needed
            if cfg.is_tracked_reviewer(r.reviewer)
        ]
        for rec in backfill_filtered:
            sys.stderr.write(
                f"BACKFILL NEEDED: thread {rec.id} ({rec.path}:{rec.line}) "
                f"by {rec.reviewer} — resolved without a verdict block.\n")
        for rec in resolve_filtered:
            sys.stderr.write(
                f"RESOLVE NEEDED: thread {rec.id} ({rec.path}:{rec.line}) "
                f"by {rec.reviewer} — has a verdict block but is unresolved.\n")
        if enforce_mode == "strict" and (backfill_filtered or resolve_filtered):
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
        sp.add_argument("--repo", required=False, help="OWNER/REPO (falls back to GH_REPO env var if unset)")
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

    p_val = sub.add_parser("validate", help="Validate a journal file against the schema")
    p_val.add_argument("path", help="Path to pr-N.json")
    p_val.add_argument("-v", "--verbose", action="store_true", help="Print OK on success")
    p_val.set_defaults(func=cmd_validate)

    ns = p.parse_args(argv)
    return ns.func(ns)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
