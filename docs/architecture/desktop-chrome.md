# Analysis: how much space the desktop chrome may take

State as of 2 September 2026, measured on the code of `_ExpandedShell`
(`features/conversations/conversation_workspace.dart`) and on running build 45 on
`win-test-1`.

## What is drawn today

The wide layout is a `Row` of five fixed bands from left to right:

| band | width | source |
| --- | --- | --- |
| `_AccountRail` | **88 px hardcoded** | `conversation_account_chrome.dart:23` |
| `VerticalDivider` | 1 px | |
| conversation list | **300 px** on desktop | `AppMetrics.listPaneWidth` |
| `VerticalDivider` | 1 px | |
| chat | the rest | `Expanded` |
| conversation details | `clamp(300, 27vw, 500)` | optional, toggleable |

So before the chat begins, **390 px are always spent**, regardless of what is in
those bands. On a 1400 px window that is 28% of the width; on 1024 px, which is
still an ordinary laptop, **38%**.

## Measured width budget

Measured by rendering the real `ConversationWorkspace` at four window widths;
`chrome` is the rail plus the list, that is everything to the left of the
conversation.

| window | accounts | rail | list | conversation | chrome | share |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1024 | 1 | 0 | 330 | 693 | 330 | **32.2%** |
| 1024 | 2 | 88 | 330 | 604 | 418 | **40.8%** |
| 1280 | 1 | 0 | 390 | 889 | 390 | 30.5% |
| 1280 | 2 | 88 | 390 | 800 | 478 | 37.3% |
| 1400 | 1 | 0 | 390 | 1009 | 390 | 27.9% |
| 1400 | 2 | 88 | 390 | 920 | 478 | 34.1% |
| 1920 | 1 | 0 | 390 | 1529 | 390 | 20.3% |
| 1920 | 2 | 88 | 390 | 1440 | 478 | 24.9% |

Two things in that table are worth attention.

First, **the rail is most expensive exactly where there is least space**: at
1024 px it costs 8.6 percentage points, at 1920 px only 4.6. Fixed-width chrome
gets more expensive the smaller the window is — and a 1024 px laptop is not an
edge case.

Second, the numbers come from a widget test, where the **touch** `VisualDensity`
applies, so the list comes out at 330–390 px. On a real desktop it is 300 px, so
the real share is somewhat lower; the ratios between the rows still hold.

## What is actually in that rail

The contents of `_AccountRail` from top to bottom: a `BrandMark` of 44 px, a
separator, a `ListView` of account avatars at 56 px each, and two buttons at the
bottom — add account and settings.

With **a single account** that means 88 px across the full height of the window
for:

1. an application logo that does nothing,
2. the avatar of the only account, which cannot be clicked
   (`onTap: isSelected ? null`),
3. two buttons.

A switcher with nothing to switch between is not navigation — it is decoration
with a width. And that it is decoration is proven by the code itself: `onTap` is
`null` for the selected account, so the single item of the list is a dead target.

## The key finding: the right pattern is already in the repo

The compact layout solves the same problem from the start, and solves it well.
`_AccountMenu` (`conversation_account_chrome.dart:100`) is a `PopupMenuButton`
whose icon is the avatar of the current account and whose menu carries **exactly
the same three things**: the list of accounts to switch to, "Add account" and
"Settings". It takes up a single button in the header.

The wide rail is therefore not a different feature. It is **a permanently
expanded copy of a menu that already exists**, and it is expanded even when the
list has one element.

## Decisions

**D-041: chrome with nothing to switch between is not drawn.**

`_AccountRail` is rendered in the wide layout only when `accounts.length > 1`.
With a single account, its place is taken by `_AccountMenu` in the header of the
conversation list — the same button, the same menu, the same actions as on
mobile.

This wins **89 px** (the rail and its divider) for content. On a 1024 px window
that is almost nine percent of the width given back to the chat.

Why not otherwise:

- *Narrow the rail* — 88 px is the Material size for a 56 px touch target with
  padding; narrowing it would break the target, not the problem.
- *Keep the rail and only hide the logo* — a band for two buttons remains.
- *Hide the rail manually with a toggle* — adds state and another control for
  something the app can derive by itself from the number of accounts.

**D-042: the conversation list can be hidden.**

The conversation details can be toggled (`detailsOpen`), the list cannot, even
though it is wider and, while reading a longer conversation, just as
unnecessary. A toggle is added to the chat header that folds the list. The state
is not held by the layout — that is the wrong place for state, which it discards
itself on resize — but is a preference, see D-043.

It folds to zero, not to an icon strip. A strip is a third width mode on top,
and only in order to save one click back.

**D-043: the app remembers the folded list.**

The fold state survives a restart. A desktop application that does not remember
its layout gets rearranged on every launch. It is stored in a file next to the
theme choice, that is NOT per account: the fold is a property of how a person
uses this window, and switching the account is no reason to expand it.

An unreadable preference falls back to "shown". That direction is deliberate: a
list hidden by mistake looks like lost conversations, one shown by mistake costs
one click.

## What deliberately does not change

- **Multi-server stays.** It is the reason this client exists. The only change is
  that whoever does not use it no longer pays for it in space.
- **The 300 px list width** is taken from the Nextcloud navigation column and
  stays.
- **The touch layout** does not change at all; the rail was never there.
