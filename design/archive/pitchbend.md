# My take on the semantics of detune and pitchbend

## Basic setup

Consider a single channel. Detune lives only on the **column-1** note
stream of that channel; columns 2+ are tuning-neutral and never carry
detune. All statements below are about that single col-1 stream.

Col-1 notes on a channel may overlap (within `overlapInterval`), but
are never simultaneous — no two col-1 notes share a start ppq. This
means ownership needs a tie-break on the overlap segment, given
below.

- For each ppq P, there is a value raw(P), the raw MIDI pitchbend in
  effect at P, expressed in cents. raw is a step function, right-
  continuous at pb events. We write P⁻ for the left limit at P — i.e.
  "the state just before any event at P takes effect".

- For each note N, there is a value detune(N), the deviation in cents
  of the intended pitch of that note from its MIDI pitch.

- A ppq P is owned by a note N if N.ppq ≤ P < N.endppq, and no note
  N' with N'.ppq > N.ppq also has N'.ppq ≤ P < N'.endppq. In plain
  terms: among the (possibly several) col-1 notes covering P, the
  latest-starting one wins.

- Thus, for each ppq P, there is a value detune(P), which equals
  detune(N) if N owns P, and is zero otherwise.

- For each ppq P, we define logical(P), the logical pitchbend in
  effect at P, to be raw(P) - detune(P).


## Invariants

1) Any ppq P which is not owned by a note contains no pitchbend.
2) If P is owned by N then there is a pitchbend at P if and only if
   logical(P) ≠ logical(P⁻) or detune(P) ≠ detune(P⁻).

Note that (2) is an _iff_. The "only if" direction forbids interior
no-op pbs. The "if" direction requires a pb at every transition — in
particular at a note-start where detune flips, even if logical is
continuous across the boundary.

### Worked example: abutting notes

Two col-1 notes on the same channel: N₁ = [0, 100), detune +20;
N₂ = [100, 200), detune -30. Suppose the user wants logical ≡ 0
throughout.

- At P=0: 0 is owned by N₁. detune(0⁻)=0, detune(0)=+20 → pb
  required, raw=+20.
- At P=100: 100 is owned by N₂ (half-open: N₁ is [0,100), N₂ is
  [100,200)). detune(100⁻)=+20, detune(100)=-30 → pb required,
  raw=-30.
- At P=200: 200 is *not* owned by anything — N₂ is half-open on
  the right. Invariant (1) forbids a pb there. No restore marker.

So just two pbs, both at note starts. After P=200 raw stays at
-30 indefinitely; that's fine, because the gap has detune=0 and no
sounding note, so "logical" there is a purely theoretical value
that nobody observes. The next note on this channel will set up
its own raw regime via its own note-start pb.

Key point: required pbs live only at ppqs owned by some note, and
invariant (2) only ever forces them at note *starts* (since detune
is constant across the interior of a single note — overlaps aside
— and note-ends are unowned unless abutted, in which case they're
really the start of the next note).

## Stage 1: rebuild

For this stage, we are presented with a MIDI take in unknown state.

We are allowed to define detune(N) for each N, and logical(P) for each
P, and to add and remove pitchbends, subject to the conditions that:

1) If detune(N) exists in the metadata, it is respected
2) For any P, detune(P) + logical(P) is the raw(P) from the MIDI take
3) the two invariants are satisfied afterwards

We do so by following steps 1-3 below.

### STEP 1 - add detunes

If detune(N) does not exist for any note, it is set to 0.
This then determines detune(P) and so logical(P) for each P.

### STEP 2 - delete pitchbends

Step through pitchbends and remove those which:

(1) are not owned by any note
(2) are at a position P owned by some note, for which logical(P) =
    logical(P⁻) and detune(P) = detune(P⁻)

This forces invariant (1) and the "only if" half of invariant (2).
(This is exactly the `reduce` operation defined in Stage 2.)

### STEP 3 - add pitchbends

The "if" half of invariant (2) can only be violated at owned ppqs
where detune or logical transitions. Since detune is constant across
the interior of any single note, all such transitions happen at note
*starts* — a note end in a gap is unowned (and forbidden to carry a
pb by invariant (1)), while a note end that abuts another note is
really the start of that next note.

Step through notes N. For P = N.ppq, if there is no pitchbend at P
and logical(P) ≠ logical(P⁻) or detune(P) ≠ detune(P⁻), add one with
value logical(P⁻) + detune(P) (which makes logical continuous
across P).

## Stage 2: editing

trackerManager exposes the operations listed below; the view layer
composes all its edits from these.

We assume given a take which satisfies the invariants. We will build a
take that will satisfy the invariants after the next rebuild.

On flush, a queue of these operations will be carried out in
sequential order, modifying a simulation of the MIDI state as it goes.

Within each operation, all queried values (raw, logical, detune, P',
Q, ...) are taken from the state going into the operation. The
operation then mutates the state, and queues a list of raw edits to
pass onto midiManager. Once the queue is empty these operations are
carried out simultaneously.

trackerManager will reject invalid edits:

- changing the channel of notes;
- changing the ppq of pitchbend events;
- changing detune and ppq/endppq of notes simultaneously;
- adjusting notes into a space where they are not accepted, or to
  begin before they start.

Before processing the queue, we pre-process by placing a pitchbend
with value raw(P) at the ppq of any note-on event, if no such exists.

### Helpers

**`retune(P1, P2, D)`** for every pitchbend with ppq P in [P1, P2) set
its value to raw(P) + D.

**`reduce`** — delete pitchbends that are not owned by any col-1 note
and interior no-ops (pb at P where logical(P)=logical(P⁻) and
detune(P)=detune(P⁻)).

### Add/amend pitchbend at P with logical value L

- Let P' be the first ppq > P at which logical changes (or +∞).
- retune(P, P', L - logical(P)).
- Guaranteed to only change the logical pitchbend list.

### Delete pitchbend at P

- Let P' be the first ppq > P at which logical changes (or +∞).
- retune(P, P', logical(P⁻) - logical(P)).
- Guaranteed to only change the logical pitchbend list.

### Move pitchbend

Not allowed; delete and recreate.

### Add note N at P with detune D

- If D is not specified, take it to be 0.
- Add a pitchbend at P with value logical(P⁻) + D
  (i.e. raw(P⁻) - detune(P⁻) + D) so that logical is continuous across P.
- Add the note.
- Guaranteed not to change the logical pitchbend list.

### Amend tuning of note N from D1 to D2 (with D1 ≠ D2)

- retune(N.ppq, N.endppq, D2 - D1).
- assignNote(N, { detune = D2 }).
- Guaranteed not to change the logical pitchbend list. 

### Amend startppq and endppq of note N to (P1, P2)

- Let L = logical(P1).
- assignNote(N, { ppq = P1, endppq = P2 }).
- If there is no pitchbend at P1, place one with value detune(N) + L.
- reduce.
- Guarantees: no note apart from N changes in pitch; logical(P1) is
  unchanged.

### Delete note N

- deleteNote(N).
- reduce.
- Guarantees: no note changes in pitch.

### Change channel of note N

Not allowed; delete and recreate.
