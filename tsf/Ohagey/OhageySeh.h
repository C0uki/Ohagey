// Structured exception guards for the TSF entry points (decision 0017).
//
// This DLL runs inside Notepad, Chrome, Word — every application the user types
// in. A fault in our code must not take the host down with it: losing the IME
// is recoverable, losing an unsaved document is not.
//
// ── How to use this ─────────────────────────────────────────────────────────
//
// `__try` cannot appear in a function that needs C++ object unwinding (MSVC
// error C2712), which is almost every function worth guarding. So a guarded
// entry point is split in two: a thin wrapper holding the `__try`, and the real
// body moved to a `...Impl` function it calls. The wrapper must declare no
// objects with destructors.
//
//     LRESULT CALLBACK Foo::Proc(HWND h, UINT m, WPARAM w, LPARAM l)
//     {
//         __try
//         {
//             return ProcImpl(h, m, w, l);
//         }
//         __except (Ohagey::SehFilter(GetExceptionCode(), GetExceptionInformation()))
//         {
//             return DefWindowProc(h, m, w, l);
//         }
//     }
//
// ── What this does not do ───────────────────────────────────────────────────
//
// Swallowing a fault leaves the process in whatever state the fault left it.
// That is the right trade at the boundary of a DLL that has no business ending
// the host's process, but it is not a licence to fault: state that was being
// mutated when the exception hit stays half-updated.

#pragma once

#include <windows.h>

namespace Ohagey
{
    /// Decides whether a structured exception should be swallowed.
    ///
    /// Returns EXCEPTION_EXECUTE_HANDLER for faults the host should be shielded
    /// from, and EXCEPTION_CONTINUE_SEARCH for the ones where swallowing is
    /// worse than the fault:
    ///
    ///   - **Breakpoints and single-step.** These are a debugger talking. Eating
    ///     them makes the DLL undebuggable.
    ///   - **Stack overflow.** The thread's guard page is gone; continuing on
    ///     that stack is not something we can promise anything about, and the
    ///     usual next fault would be inside the handler.
    ///
    /// Also writes the fault to the debugger via OutputDebugString. Local only —
    /// nothing leaves the machine (decision 0016).
    int SehFilter(unsigned long code, struct _EXCEPTION_POINTERS* information);
}
