// Diagnostic log for the TSF side (decision 0033).
//
// ── Why this exists ─────────────────────────────────────────────────────────
//
// The engine got a log file after a real-machine bug could not be chased
// without one, and it immediately paid for itself. The DLL then hit the same
// wall from the other side: left context arrived at the engine empty, the wire
// format and the engine's decoder both checked out, and the only remaining
// suspect -- the code that reads the text out of the document -- runs inside
// Notepad with nowhere to say anything. Three rounds of guessing followed.
//
// ── What must never go in it ────────────────────────────────────────────────
//
// **Nothing the user typed.** Not readings, not candidates, not the context
// this was written to debug. Lengths, HRESULTs and counts answer every question
// worth asking here; the characters themselves would turn a debug aid into a
// transcript of everything written on the machine. Same rule as the engine's
// log, and for the same reason.
//
// ── Cheap and safe ──────────────────────────────────────────────────────────
//
// This runs inside other people's applications (decision 0017), so it opens the
// file per line with sharing and append access rather than holding a handle:
// several applications have the IME loaded at once and all of them write here.
// Every failure is swallowed. A lost diagnostic costs a line; a text service
// that throws costs the user their editor.

#pragma once

namespace Ohagey
{
    // Appends one line. Printf-style, ASCII only, no user text.
    void Log(const char* format, ...);
}
