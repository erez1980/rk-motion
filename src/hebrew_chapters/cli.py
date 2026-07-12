"""`chapters` CLI entrypoint.

  chapters episode.mp4                         # chapters to stdout
  chapters episode.mp3 --shownotes --quotes    # add show notes + pull-quotes
  chapters ep.mp4 --format youtube --out ep    # writes ep.chapters.md (youtube body)

Multi-output routing: with --out, each generator writes a sibling file
(FILE.chapters.md / FILE.shownotes.md / FILE.quotes.md); without --out, each is
printed to stdout under a labeled header.
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys

from . import __version__


def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="chapters", description="Hebrew podcast episode kit.")
    p.add_argument("media", help="an mp3/mp4 file, an RSS feed URL, a YouTube URL, or a direct audio URL")
    p.add_argument("--episode", type=int, default=1,
                   help="which episode from an RSS feed (1 = first/latest item); ignored for files")
    p.add_argument("--list-episodes", action="store_true",
                   help="list the episodes in an RSS feed and exit")
    p.add_argument(
        "--model",
        default="ivrit-ai/whisper-large-v3-turbo-ct2",
        help="faster-whisper model or HF ct2 repo id (default: Hebrew-tuned ivrit-ai turbo)",
    )
    p.add_argument("--lang", default="he", help="transcript language (default: he)")
    p.add_argument("--max-chapters", type=int, default=12)
    p.add_argument(
        "--format",
        choices=["md", "txt", "youtube", "spotify", "podcast"],
        default="md",
        help="chapter output: md/txt (read), youtube (description paste, >=10s), "
        "spotify (description paste for Spotify/Megaphone, >=30s), "
        "podcast (Podcasting 2.0 chapters JSON for your RSS feed)",
    )
    p.add_argument(
        "--embed-into",
        metavar="AUDIO",
        help="write chapter markers into a copy of this audio file (for Apple "
        "Podcasts etc.); output is <AUDIO stem>.chapters.<ext>",
    )
    p.add_argument(
        "--titler",
        choices=["api", "claude-cli"],
        default="api",
        help="generation backend: api (Anthropic API, needs ANTHROPIC_API_KEY) or "
        "claude-cli (`claude -p`, uses your Claude Code / Pro/Max subscription, no key)",
    )
    p.add_argument("--shownotes", action="store_true", help="also generate Hebrew show notes")
    p.add_argument("--quotes", action="store_true", help="also extract pull-quotes")
    p.add_argument("--clips-json", metavar="PATH",
                   help="write a clips.json (clip ranges + hooks + per-word timings) for a social-clip renderer")
    p.add_argument("--out", help="base path for sibling output files")
    p.add_argument("--no-cache", action="store_true", help="bypass the transcript cache")
    p.add_argument("--version", action="version", version=f"hebrew-chapters {__version__}")
    return p


def _emit(kind: str, body: str, out_base: str | None, ext: str = "md") -> None:
    if out_base:
        path = f"{out_base}.{kind}.{ext}"
        with open(path, "w", encoding="utf-8") as f:
            f.write(body + "\n")
        print(f"wrote {path}", file=sys.stderr)
    else:
        print(f"\n# {kind}\n{body}")


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)

    from . import feed

    # List a feed's episodes and exit — no key or transcription needed.
    if args.list_episodes:
        if not feed.is_url(args.media):
            print("error: --list-episodes needs an RSS feed URL", file=sys.stderr)
            return 1
        try:
            episodes = feed.list_episodes(args.media)
        except (feed.FeedError, OSError) as e:
            print(f"error: {e}", file=sys.stderr)
            return 1
        if not episodes:
            print("error: no episodes with an audio enclosure found", file=sys.stderr)
            return 1
        for i, ep in enumerate(episodes, 1):
            print(f"{i}\t{ep.title}")
        return 0

    # Fail fast on a missing backend BEFORE the expensive transcription step.
    if args.titler == "api" and not os.environ.get("ANTHROPIC_API_KEY"):
        print("error: ANTHROPIC_API_KEY is not set (or use --titler claude-cli)", file=sys.stderr)
        return 1
    if args.titler == "claude-cli" and not shutil.which("claude"):
        print("error: claude CLI not found — install Claude Code or use --titler api", file=sys.stderr)
        return 1

    # Resolve an RSS feed / audio URL to a local file (downloads + caches). A
    # local path passes through unchanged.
    try:
        media_path = feed.resolve(args.media, episode=args.episode)
    except (feed.FeedError, OSError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    from . import format as fmt
    from . import generate, transcribe

    try:
        segments = transcribe.transcribe(
            media_path, model=args.model, lang=args.lang, use_cache=not args.no_cache
        )
    except FileNotFoundError:
        print(f"error: file not found: {args.media}", file=sys.stderr)
        return 1
    if not segments:
        print("error: no speech detected", file=sys.stderr)
        return 1

    audio_end = segments[-1].end
    # Each generator is independent: if one fails, warn and keep going so the
    # others still produce output (they're separate Claude calls by design).
    failed = 0

    try:
        chapters = generate.make_chapters(segments, max_chapters=args.max_chapters, titler=args.titler)
        ext = "md"
        if args.format in ("youtube", "spotify"):
            min_gap = 30.0 if args.format == "spotify" else 10.0
            body = fmt.render_chapters_youtube(chapters, audio_end, min_gap=min_gap)
            ext = "txt"
            if not body:
                print("warning: fewer than 3 chapters; emitting markdown instead", file=sys.stderr)
                body, ext = fmt.render_chapters_md(chapters), "md"
        elif args.format == "podcast":
            body, ext = fmt.render_chapters_podcast_json(chapters), "json"
        elif args.format == "txt":
            body, ext = fmt.render_chapters_md(chapters), "txt"
        else:
            body = fmt.render_chapters_md(chapters)
        _emit("chapters", body, args.out, ext)

        # Optionally embed the same chapters into an audio file for apps that
        # read in-file chapter markers (Apple Podcasts, etc.).
        if args.embed_into:
            from . import embed
            from pathlib import Path
            src = Path(args.embed_into)
            dst = str(src.with_suffix("")) + ".chapters" + src.suffix
            try:
                embed.embed_chapters(str(src), chapters, audio_end, dst)
                print(f"wrote {dst} (embedded chapters)", file=sys.stderr)
            except (RuntimeError, OSError) as e:
                print(f"warning: embedding failed: {e}", file=sys.stderr)
                failed += 1
    except generate.GenerationError as e:
        print(f"warning: chapters failed: {e}", file=sys.stderr)
        failed += 1

    if args.shownotes:
        try:
            _emit("shownotes", fmt.render_shownotes_md(generate.make_shownotes(segments, titler=args.titler)), args.out)
        except generate.GenerationError as e:
            print(f"warning: show notes failed: {e}", file=sys.stderr)
            failed += 1
    if args.quotes:
        try:
            _emit("quotes", fmt.render_quotes_md(generate.make_quotes(segments, titler=args.titler)), args.out)
        except generate.GenerationError as e:
            print(f"warning: quotes failed: {e}", file=sys.stderr)
            failed += 1
    if args.clips_json:
        try:
            import json
            from pathlib import Path
            doc = {
                "schema_version": 1,
                "source": {"video": os.path.abspath(media_path)},
                "clips": generate.make_clips(segments, titler=args.titler),
            }
            Path(args.clips_json).write_text(json.dumps(doc, ensure_ascii=False, indent=2))
            print(f"wrote {args.clips_json} ({len(doc['clips'])} clips)", file=sys.stderr)
        except generate.GenerationError as e:
            print(f"warning: clips-json failed: {e}", file=sys.stderr)
            failed += 1
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
