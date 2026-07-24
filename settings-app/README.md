# settings-app/ — WinUI 3 settings application (decision 0013)

Planned screens:
- **Backend**: CPU / CUDA / Vulkan selection (decision 0010), model status
  (downloaded / missing / re-download button, decisions 0008/0009)
- **Learning**: enable/disable toggle + "clear learning data" button
  (decision 0025), targeting `%LOCALAPPDATA%\Ohagey\` (decision 0024)
- **User dictionary**: add/edit/remove entries (decision 0026)
- **About**: version info, licenses, Zenzai model attribution
  (see `docs/decisions/0009-model-license.md`)

Settings are written to the registry / a settings file that `tsf/` and `engine/`
watch for changes and hot-reload (decision 0014) — this app does not talk to the
running engine process directly.

🚧 Not yet scaffolded as a WinUI 3 project. Will be added with `dotnet new winui3`
(or equivalent template) once implementation begins.
