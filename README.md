# Urban Dictionary for macOS

Builds a personal macOS dictionary (Dictionary.app, Look Up / force-click) from an
existing Urban Dictionary data dump. Nothing is scraped. **This repo contains tools
only; data and built dictionaries are gitignored and must not be redistributed.**
The content is copyrighted by Urban Dictionary and its contributors.

## Requirements (on your Mac)

- Python 3.9+ (no packages needed)
- Apple's **Dictionary Development Kit**: download *Additional Tools for Xcode* from
  <https://developer.apple.com/download/all/>, then copy
  `Utilities/Dictionary Development Kit` to `/Applications/Utilities/`.
  (Or pass `DICT_BUILD_TOOL_DIR=/path/to/kit` to `make`.)

## Steps

1. Download a dump into `data/`, e.g. the Kaggle dataset
   *"Urban Dictionary Words And Definitions"* (`urbandict-word-defs.csv`).
   Any CSV/JSON/JSONL with `word` + `definition` columns works; vote, author,
   example and date columns are detected automatically.
2. Build and install:

   ```sh
   make                 # converts data/* -> build/UrbanDictionary.xml, then builds
   make install         # copies into ~/Library/Dictionaries
   ```
3. Open Dictionary.app → Settings, tick **Urban Dictionary**, and drag it where you
   want it in the list.

## Filtering

By default an entry is kept if it has **≥ 50 upvotes** and a **≥ 60 % up-ratio**.
Each word gets up to **3** definitions, best score (up − down) first. Override:

```sh
make clean && make FILTER="--min-up 200 --min-ratio 0.7 --max-defs 2 --max-words 50000"
```

| Flag | Default | Meaning |
|---|---|---|
| `--min-up` | 50 | minimum upvotes per definition |
| `--min-ratio` | 0.6 | minimum up / (up + down) |
| `--max-defs` | 3 | definitions per headword |
| `--max-words` | none | total headword cap, best first |
| `--max-word-len` | 60 | drop headwords longer than this |
| `--no-author` | off | hide author names |

Build time on the Mac scales with entry count. Start with `--max-words 20000` to check
the result before doing a full build.

## Development

```sh
make test     # runs the unit tests (works on Linux, too)
make xml      # only generate the XML, no DDK needed
```
