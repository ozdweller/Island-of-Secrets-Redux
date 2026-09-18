<p align="center"><img src="art/banner.jpg" width="480" alt="An island crowned by a castle and a pyramid beneath a glowing crystal"></p>

# Island of Secrets Redux

A fan resurrection of **_Island of Secrets_**, the 1984 Usborne type-in text
adventure by Jenny Tyler and Les Howarth, as native macOS apps.

> Adapted from the Usborne book **_Island of Secrets_** (Usborne Publishing).
> Usborne have kindly made their 1980s computer books free to download and
> allow the programs to be adapted and shared non-commercially:
> **<https://usborne.com/gb/books/computer-and-coding-books>**

## The game

Long ago, the Sky People gave the Ancients five ordinary-looking objects to
hide. Then a war darkened the Earth. Omegan was sent to gather the objects and
restore the world, but kept their power for himself instead. He still lives on
his Island of Secrets. You play Alphan, a young scholar who has only his
explorer grandfather's map to go on, and who sets out to find the objects and
bring back the light.

As in the original, the game won't tell you where the exits are or point out
every useful object. You'll need the map, careful reading and some
experimenting to survive the island, its creatures and its puzzles.

This repository contains two versions:

| | **Island of Secrets (Classic)** | **Island of Secrets 2.0** |
|---|---|---|
| What it is | The original 1984 game, unchanged | A reimagining set in the same world |
| How it works | A small BASIC interpreter runs the original program line by line | You type ordinary sentences; a local language model works out what you meant, and a rule engine decides what happens |
| Commands | The original two-word commands (`GET APPLE`, `GO NORTH`) | Free text ("pick up the apple and head north") |
| Language model | Optional (adds narration, hints, command help) | Required (via [Ollama](https://ollama.com)) |

Both versions run entirely on your own Mac. Nothing is sent to a cloud service.

## Requirements

- A Mac running macOS 13 (Ventura) or later. Apple silicon and Intel both work.
- Apple's free **Command Line Tools**, which provide `swift` (to build the apps)
  and `python3` (to run the game engines). The full Xcode app also works but
  isn't needed.
- **Ollama**, a free app for running language models locally. It's optional for
  Classic and required for 2.0.

### Step 1: Install the Command Line Tools

Open **Terminal** (Applications → Utilities → Terminal) and run:

```sh
xcode-select --install
```

A window appears. Click **Install** and accept the licence. The download is
around 1 GB and takes a few minutes. If you're told the tools are already
installed, skip ahead.

Check that it worked:

```sh
swift --version
python3 --version
```

Both should print a version number. Python needs to be 3.9 or later; the
version bundled with the Command Line Tools is fine, and there's nothing to
`pip install`.

### Step 2 (optional for Classic): Install Ollama and a model

1. Download Ollama from <https://ollama.com/download> and open it once. It then
   runs in the menu bar.
2. In Terminal, download a model (about 5 GB):

   ```sh
   ollama pull llama3.1:8b
   ```

Any model you've pulled can be picked from the dropdown in either app. Macs
with 16 GB of RAM or more will give the smoothest experience.

## Installation

```sh
git clone https://github.com/ozdweller/Island-Of-Secrets-Redux.git
cd Island-Of-Secrets-Redux
chmod +x launch.command launch2.command
```

Or use **Code → Download ZIP** on GitHub and unzip it anywhere.

The first launch of each version compiles the app, which takes a minute or two.
Later launches are quick.

## Playing

**Classic:** double-click `launch.command`. Choose **Classic** to play the
original game exactly as it was, or **Cyber** to add local-LLM narration, hints
and help with commands.

**2.0:** double-click `launch2.command`, pick a model from the dropdown and
press **Start**.

If macOS blocks a `.command` file the first time, right-click it and choose
**Open**.

**Terminal only (no app window):**

```sh
python3 engine/play.py                                     # Classic
python3 "Island 2.0/engine/shell.py" --model llama3.1:8b   # 2.0
```

### Grandpa's map (recommended)

The original game gives no on-screen directions: you find your way using the
map printed in the book. The map is Usborne's artwork, so it isn't included
here. To use it in the game:

1. Download the free _Island of Secrets_ PDF from the
   [Usborne page](https://usborne.com/gb/books/computer-and-coding-books).
2. Export pages 6–7 (the "Grandpa's map" spread) as an image.
3. Save it as `art/Grandpa's map.png` (or `.jpg`).

The **Map** button in either app then opens it in its own window. The rest of
the book (the full story, character notes and a clues page for when you're
stuck) is worth reading too.

## Credits

- **Original game:** _Island of Secrets_ by Jenny Tyler and Les Howarth,
  illustrated by Patrick Lynch, published by Usborne Publishing (1984).
- **This adaptation:** the macOS apps, Python engines and 2.0 rule design were
  written with extensive help from AI coding assistants.
- **Artwork:** the illustrations in `art/` were created for this project with
  an AI image generator (Grok Imagine), from descriptions of the book's
  locations and characters. They are new images, not copies of the book's
  illustrations, and some carry the generator's small watermark.

## License and rights

This is a non-commercial fan project, shared under Usborne's published terms:

> You may adapt any of the programs in these books to modern computer
> languages, and share the adaptations freely online. You may not use the
> adaptations for commercial purposes. Please credit the name of the Usborne
> book from which you adapted the program, and provide a link to this webpage.
> — <https://usborne.com/gb/books/computer-and-coding-books>

- **Code** (Swift, Python, scripts): [PolyForm Noncommercial 1.0.0](LICENSE)
- **Artwork:** [CC BY-NC 4.0](art/LICENSE.txt)
- **The original game** (its story, characters, in-game text and the BASIC
  listing in `listing.bas`) remains © Usborne Publishing Ltd. The book's
  backstory and character notes appear here only as paraphrased summaries. The
  book's illustrations and map aren't redistributed.

These licences cover only this project's own work, not Usborne's material.
This project is not affiliated with or endorsed by Usborne Publishing.
