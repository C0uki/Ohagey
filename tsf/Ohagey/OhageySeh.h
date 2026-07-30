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

// ── Guards for COM methods ──────────────────────────────────────────────────
//
// There are around a hundred of these across the text service. Written out
// longhand each guard is a dozen lines, and a thousand lines of near-identical
// boilerplate is both a poor diff and an easy place to get one wrapper subtly
// wrong. These macros make each one a single line that cannot disagree with
// itself about the signature.
//
//     OHAGEY_SEH_HRESULT(CFoo, OnBar,
//                        (_In_ ITfContext *pContext, BOOL *pIsEaten),
//                        (pContext, pIsEaten))
//
// The body moves to `CFoo::OnBarImpl` with the same parameters, declared in the
// header next to the original. Everything in the wrapper is a pointer or an
// integer, so nothing needs unwinding and the __try is legal (see the note at
// the top of this file about C2712).
//
// `params` and `args` are separate because the wrapper needs the declaration in
// one and the call in the other; passing the wrong names shows up immediately
// as a compile error rather than as a guard that calls the wrong thing.
//
// Only HRESULT methods have macros: every guarded entry point in this text
// service returns HRESULT. The exceptions are IUnknown's AddRef and Release,
// which are deliberately left unguarded — see the note in the guarded files.

#define OHAGEY_SEH_FILTER \
    Ohagey::SehFilter(GetExceptionCode(), GetExceptionInformation())

/// Guards a method returning HRESULT. On a fault it reports E_UNEXPECTED: the
/// caller learns the call did not happen, which is the truth.
#define OHAGEY_SEH_HRESULT(cls, method, params, args)                       \
    STDMETHODIMP cls::method params                                         \
    {                                                                       \
        __try { return cls::method##Impl args; }                            \
        __except (OHAGEY_SEH_FILTER) { return E_UNEXPECTED; }               \
    }

/// Guards a method returning HRESULT that hands back a pointer.
///
/// The out parameter is nulled before returning. A caller that gets a failure
/// HRESULT should not look at it, but COM code that releases whatever it finds
/// there is common enough that leaving the fault's leftovers in place would
/// turn a contained fault into a release of a pointer that was never valid.
#define OHAGEY_SEH_HRESULT_OUT(cls, method, params, args, outParam)         \
    STDMETHODIMP cls::method params                                         \
    {                                                                       \
        __try { return cls::method##Impl args; }                            \
        __except (OHAGEY_SEH_FILTER)                                        \
        {                                                                   \
            if (outParam) *(outParam) = nullptr;                            \
            return E_UNEXPECTED;                                            \
        }                                                                   \
    }
