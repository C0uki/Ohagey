// Opening the settings app from inside the user's application.
//
// The settings app is installed beside this DLL and beside the engine, in a
// directory nobody browses to. Windows' own input-method list reaches the IME,
// but nothing reaches its settings — so without an entry point here, the only
// way in is the Start menu shortcut the installer creates.

#pragma once

namespace Ohagey
{
    /// Starts the settings app, if it can be found and started.
    ///
    /// Returns false rather than reporting anything: this runs inside whatever
    /// application the user is typing in, and an AppContainer application is
    /// denied CreateProcess outright (decision 0031). A message box from inside
    /// someone's word processor would be worse than the menu item doing
    /// nothing.
    bool LaunchSettingsApp();
}
