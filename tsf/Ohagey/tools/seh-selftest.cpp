// Tests the structured exception guards (decision 0017).
//
// An exception handler nobody has ever seen fire is a liability: it looks like
// protection and may not be. This one deliberately faults inside a guard and
// checks that execution carries on, which is the entire promise being made to
// the host application.
//
// Build and run: tsf/Ohagey/tools/build-and-run-seh.ps1

#include "../OhageySeh.h"

#include <cstdio>

namespace
{
    int g_failures = 0;

    void Check(bool ok, const char* what)
    {
        printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what);
        if (!ok) ++g_failures;
    }

    // Faults on purpose. `volatile` so the compiler neither folds it away nor
    // warns about an obviously null dereference.
    int Fault()
    {
        volatile int* pointer = nullptr;
        return *pointer;
    }

    int DivideByZero()
    {
        volatile int zero = 0;
        volatile int one = 1;
        return one / zero;
    }

    // The shape every guarded entry point uses: a wrapper with no C++ objects,
    // holding the __try, calling the real body.
    bool GuardedFault()
    {
        __try
        {
            Fault();
            return false;   // not reached
        }
        __except (Ohagey::SehFilter(GetExceptionCode(), GetExceptionInformation()))
        {
            return true;
        }
    }

    bool GuardedDivideByZero()
    {
        __try
        {
            DivideByZero();
            return false;
        }
        __except (Ohagey::SehFilter(GetExceptionCode(), GetExceptionInformation()))
        {
            return true;
        }
    }

    bool GuardedSuccess(int* out)
    {
        __try
        {
            *out = 42;
            return true;
        }
        __except (Ohagey::SehFilter(GetExceptionCode(), GetExceptionInformation()))
        {
            return false;
        }
    }
}

int main()
{
    printf("the filter's policy\n");
    Check(Ohagey::SehFilter(EXCEPTION_ACCESS_VIOLATION, nullptr) == EXCEPTION_EXECUTE_HANDLER,
          "an access violation is handled");
    Check(Ohagey::SehFilter(EXCEPTION_INT_DIVIDE_BY_ZERO, nullptr) == EXCEPTION_EXECUTE_HANDLER,
          "integer divide by zero is handled");
    Check(Ohagey::SehFilter(EXCEPTION_ILLEGAL_INSTRUCTION, nullptr) == EXCEPTION_EXECUTE_HANDLER,
          "an illegal instruction is handled");

    // Swallowing these costs more than it saves; see OhageySeh.h.
    Check(Ohagey::SehFilter(EXCEPTION_BREAKPOINT, nullptr) == EXCEPTION_CONTINUE_SEARCH,
          "a breakpoint is left to the debugger");
    Check(Ohagey::SehFilter(EXCEPTION_SINGLE_STEP, nullptr) == EXCEPTION_CONTINUE_SEARCH,
          "single-step is left to the debugger");
    Check(Ohagey::SehFilter(EXCEPTION_STACK_OVERFLOW, nullptr) == EXCEPTION_CONTINUE_SEARCH,
          "stack overflow is not swallowed");

    printf("\nfaulting for real inside a guard\n");
    Check(GuardedFault(), "a null dereference reaches the handler");
    Check(GuardedDivideByZero(), "a divide by zero reaches the handler");

    // The point of all this: the process is still here.
    printf("\nstill running after two faults\n");
    int value = 0;
    Check(GuardedSuccess(&value) && value == 42, "a guard that does not fault returns normally");
    Check(GuardedFault(), "and a later fault is still caught");

    printf("\n%s (%d failure%s)\n", g_failures == 0 ? "ALL PASSED" : "FAILED",
           g_failures, g_failures == 1 ? "" : "s");
    return g_failures == 0 ? 0 : 1;
}
