# Story stickers redesign

## Why
Shared story cards should make every follower stop: non-fighters get one big number they understand instantly, fighters find the stats only a fighter appreciates, and everyone can see that FIGHT tracked and coached the session, which is what makes other fighters want the app.

## Goals
- Every card has three layers: hero number, three-stat proof row, one coach line, plus a "Coached by FIGHT" signature.
- Fight-broadcast look (red name tab, black panel, white stat strip, red signature bar) as the house style.
- Three broadcast session stickers: Main event, Round by round, Tale of the tape.
- An upgraded fight-poster sticker.
- A see-through overlay (stacked or one line) for the athlete's own video or photo, like a Strava run.
- Background choice when sharing: Plain, Photo, or Video from the camera roll.

## Non-goals / anti-goals
- No heart-rate trace line on any card (judged to look bad).
- No animated/rendered video cards.
- No invented comparisons (no "top 10% for your age").

## Approach (picked)
Rebuild the cards as native SwiftUI views (shapes only, no UIKit controls, so ImageRenderer captures them exactly) and keep Instagram's sticker flow: the card is always a movable sticker; Plain sends background colours, Photo sends `backgroundImage`, Video sends `backgroundVideo`. Alternatives considered: rendering a full 9:16 image (not movable), compositing video in-app (slow, heavy).

## Design
- Cards for a workout: Main event, Round by round (2+ rounds), Tale of the tape (needs a comparable session of the same type 3–8 weeks earlier), Fight poster, Overlay.
- Cards elsewhere, restyled in the broadcast look: Fighter (Fight Fitness), Progress (benchmark or last 30 days), Record, Countdown.
- Overlay switches to dark text when the chosen photo/video frame is bright.
- "More options" shares the composed image (plain or photo background) or the transparent sticker (video background).
- Privacy switches stay: hide name, hide weight, only improvements.

## Calls made by the builder
- Tale of the tape greens: higher recovery, more strikes, more work time. Peak heart rate is shown neutral.
- Coach line source: new record, else the workout review's first takeaway, else Gas Tank.
