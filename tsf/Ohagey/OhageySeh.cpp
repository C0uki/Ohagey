// See OhageySeh.h.

#include "OhageySeh.h"

#include <cstdio>

namespace Ohagey
{
    namespace
    {
        const char* FaultName(unsigned long code)
        {
            switch (code)
            {
            case EXCEPTION_ACCESS_VIOLATION:      return "access violation";
            case EXCEPTION_ARRAY_BOUNDS_EXCEEDED: return "array bounds exceeded";
            case EXCEPTION_DATATYPE_MISALIGNMENT: return "datatype misalignment";
            case EXCEPTION_FLT_DIVIDE_BY_ZERO:    return "float divide by zero";
            case EXCEPTION_ILLEGAL_INSTRUCTION:   return "illegal instruction";
            case EXCEPTION_IN_PAGE_ERROR:         return "in-page error";
            case EXCEPTION_INT_DIVIDE_BY_ZERO:    return "integer divide by zero";
            case EXCEPTION_PRIV_INSTRUCTION:      return "privileged instruction";
            case EXCEPTION_STACK_OVERFLOW:        return "stack overflow";
            default:                              return "exception";
            }
        }
    }

    int SehFilter(unsigned long code, struct _EXCEPTION_POINTERS* information)
    {
        switch (code)
        {
        case EXCEPTION_BREAKPOINT:
        case EXCEPTION_SINGLE_STEP:
            // A debugger is talking. Eating these would make the DLL
            // undebuggable, which costs more than it saves.
            return EXCEPTION_CONTINUE_SEARCH;

        case EXCEPTION_STACK_OVERFLOW:
            // The guard page is gone. Anything the handler does runs on a stack
            // that has already failed once, so there is nothing useful to
            // promise here — let it go to whoever handles it next.
            return EXCEPTION_CONTINUE_SEARCH;

        default:
            break;
        }

        // Local only; no telemetry, nothing leaves the machine (decision 0016).
        const void* address = (information && information->ExceptionRecord)
            ? information->ExceptionRecord->ExceptionAddress
            : nullptr;

        char message[256] = {};
        sprintf_s(message,
                  "Ohagey: caught %s (0x%08lX) at %p — the host application was "
                  "shielded, but the IME may be in a bad state (decision 0017)\n",
                  FaultName(code), code, address);
        OutputDebugStringA(message);

        return EXCEPTION_EXECUTE_HANDLER;
    }
}
