# Script Anatomy

Full reference for the standard Avorion Lua script header and structural rules.

## Canonical header template

```lua
-- ── Package path ─────────────────────────────────────────────────────────────
-- Must appear before any include() call.
-- The lib/ extension is needed for almost every script.
package.path = package.path .. ";data/scripts/lib/?.lua"
-- Additional extensions used by sector/player scripts that need sibling paths:
-- package.path = package.path .. ";data/scripts/?.lua"
-- package.path = package.path .. ";?"

-- ── Includes ─────────────────────────────────────────────────────────────────
-- Always include "callable" if this script exposes RPC-callable functions.
-- Always include "stringutility" if using the %_t localization operator.
include("callable")
include("stringutility")
include("utility")
-- Module-returning include: assign to a local.
local Dialog = include("dialogutility")

-- ── Namespace declaration ─────────────────────────────────────────────────────
-- DO NOT remove or alter this comment. The C++ engine parses it.
-- It must match the global table name exactly (case-sensitive).
-- namespace MyScript
MyScript = {}

-- ── Body ─────────────────────────────────────────────────────────────────────
-- ... callbacks, helper functions, callable registrations ...

-- ── Trailing return ──────────────────────────────────────────────────────────
-- ALWAYS unconditional. Engine injects mod extensions immediately before this line.
return MyScript
```

## Why each part is mandatory

### `package.path` extension

The game mounts mod overlay paths at startup in C++. Lua's `package.path` is only aware of the standard `./?.lua;...` pattern. Without the extension, `include("utility")` either fails with "module not found" or, worse, succeeds by finding a stale cached version that doesn't include your mod's extensions to that library.

Sector scripts that import galaxy helpers (e.g., `include("galaxy")`) need the second `data/scripts/?.lua` extension because `galaxy.lua` sits one level up from `lib/`. The third catch-all `";"` covers edge cases with relative paths used in some vanilla files.

### `include` vs `require`

Avorion's VFS intercepts `include(path)` and:
1. Resolves the path through all mounted mod overlays
2. For each enabled mod that provides a file at that path, **concatenates** the fragments in dependency order
3. Executes the combined result as a single Lua chunk

`require(path)` uses Lua's standard module loader, which reads files from the filesystem directly, ignoring the VFS overlay. Consequences:
- Your mod's extensions to `utility.lua` are never executed by scripts that `require`d it
- Other mods' extensions to libs you depend on are also skipped
- The `Callable` table on the library's namespace is never populated by `callable.lua`

Use `require` only for third-party Lua modules that live outside the Avorion VFS (rare).

### The namespace comment

The C++ loader scans each loaded Lua file for the literal string `-- namespace <Name>` (must be on its own line, with exactly one space before the name, no trailing text). If found, the script is executed in the shared VM for that namespace. If not found, the script gets its own isolated VM — cross-script callbacks in the namespace stop working, and extension by other mods that merge into the same namespace path breaks.

The namespace name must match the global table name exactly (case-sensitive). `-- namespace myScript` with `MyScript = {}` is a bug.

### Global namespace table

`MyScript = {}` (without `local`) makes the table discoverable by:
- The engine's callback dispatch (it calls `MyScript.initialize`, etc.)
- Other mods appended to the same file path (they see `MyScript` already populated)
- Cross-script calls via `entity:invokeFunction("path/myscript.lua", "funcName", ...)`

`local MyScript = {}` would be invisible outside the file-scope, breaking all of the above.

### Unconditional trailing return

The engine's mod-injection mechanism finds the **last** `return` statement in the concatenated script and inserts mod extensions immediately before it. If you write:

```lua
if onServer() then return MyScript end   -- WRONG: injection point is inside the block
```

...mod fragments that come after this file in the concatenation never execute. Instead:

```lua
if not onServer() then return end   -- early exit at TOP for server-only behavior
MyScript = {}
-- ... callbacks ...
return MyScript                      -- unconditional at BOTTOM
```

## `include` call styles

| Style | When to use |
|-------|-------------|
| `include("stringutility")` | Library injects globals and returns nil. Side-effecting. Common for "extension" libs. |
| `local X = include("plangenerator")` | Library returns a table. Assign to a local so callers use `X.method()` |
| `local X = include("upgradegenerator")()` | Library returns a factory function. Call it to get the module instance. |

If you're not sure which style a library uses, read the last line of `$AVORION_DATA_DIR/scripts/lib/<name>.lua` — a `return` statement means it's module-returning.

## Failure modes for each rule

| Rule omitted | Symptom |
|-------------|---------|
| Missing `package.path` | `include()` fails with "module not found" or silently loads wrong file |
| `require` instead of `include` | Mod extensions to that library are skipped; `Callable` table missing |
| Missing/altered namespace comment | Script runs in isolated VM; cross-script callbacks fail silently |
| `local` namespace table | Engine can't find callbacks; other mods can't extend the namespace |
| Conditional `return Module` | Mod extensions appended after this file never run |