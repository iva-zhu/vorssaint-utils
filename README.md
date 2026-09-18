## This fork's development build

The [`mix/cycle-widths-ascii`](https://github.com/iva-zhu/vorssaint-utils/tree/mix/cycle-widths-ascii)
branch is a personal development build based on upstream `main`. It contains two
features that are still waiting to land upstream:

- **Window Layout cycling** from [PR #1632](https://github.com/vorssaintapp/vorssaint-utils/pull/1632): repeat the same Left or Right shortcut to cycle `half → two thirds → one third → half` on the current display. It is opt-in and keeps the existing top/bottom and display-crossing behavior when disabled.
- **Automatic ABC layout for Command Bar** from [PR #1342](https://github.com/vorssaintapp/vorssaint-utils/pull/1342): temporarily switches from a non-Latin keyboard layout to an ASCII-capable layout while Command Bar is open, then restores the previous layout.

This is not an official release. It is built for testing and daily use before
both pull requests are merged. Do not update it from inside Vorssaint or via
Homebrew, because an official update will replace these features. To reproduce
the build locally:

```sh
git clone https://github.com/iva-zhu/vorssaint-utils.git
cd vorssaint-utils
git checkout mix/cycle-widths-ascii
./build.sh --install
```
