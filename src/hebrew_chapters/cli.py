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
import sys

from . import __version__


def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="chapters", description="Hebrew podcast episode kit.")
    p.add_argument("media", help="path to an mp3 or mp4 file")
    p.add_argument("--model", default="medium", help="faster-whisper model (default: medium)")
    p.add_argument("--lang", default="he", help="transcript language (default: he)")
    p.add_argument("--max-chapters", type=int, default=12)
    p.add_argument("--format", choices=["md", "txt", "youtube"], default="md")
    p.add_argument("--shownotes", action="store_true", help="also generate Hebrew show notes")
    p.add_argument("--quotes", action="store_true", help="also extract pull-quotes")
    p.add_argument("--out", help="base path for sibling output files")
    p.add_argument("--no-cache", action="store_true", help="bypass the transcript cache")
    p.add_argument("--version", action="version", version=f"hebrew-chapters {__version__}")
    return p


def _emit(kind: str, body: str, out_base: str | None) -> None:
    if out_base:
        path = f"{out_base}.{kind}.md"
        with open(path, "w", encoding="utf-8") as f:
            f.write(body + "\n")
        print(f"wrote {path}", file=sys.stderr)
    else:
        print(f"\n# {kind}\n{body}")


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)

    # Fail fast on a missing key BEFORE the expensive transcription step.
    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("error: ANTHROPIC_API_KEY is not set", file=sys.stderr)
        return 1

    from . import format as fmt
    from . import generate, transcribe

    try:
        segments = transcribe.transcribe(
            args.media, model=args.model, lang=args.lang, use_cache=not args.no_cache
        )
    except FileNotFoundError:
        print(f"error: file not found: {args.media}", file=sys.stderr)
        return 1
    if not segments:
        print("error: no speech detected", file=sys.stderr)
        return 1

    audio_end = segments[-1].end
    chapters = generate.make_chapters(segments, max_chapters=args.max_chapters)

    if args.format == "youtube":
        body = fmt.render_chapters_youtube(chapters, audio_end)
        if not body:
            print("warning: fewer than 3 chapters; emitting markdown instead", file=sys.stderr)
            body = fmt.render_chapters_md(chapters)
    else:
        body = fmt.render_chapters_md(chapters)
    _emit("chapters", body, args.out)

    if args.shownotes:
        _emit("shownotes", fmt.render_shownotes_md(generate.make_shownotes(segments)), args.out)
    if args.quotes:
        _emit("quotes", fmt.render_quotes_md(generate.make_quotes(segments)), args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
