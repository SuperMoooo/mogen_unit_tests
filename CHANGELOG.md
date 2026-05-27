## [1.0.12]

### Improvements

- Only stubs methods actually called in the notifier
- Filters to only mock repository interfaces (not services)
- Generates generic repository return stubs for any feature
- Generates specific state field assertions (before/after)
- Imports only relevant domain repository interfaces
- Skips helper methods starting with 'p' (internal notifier extensions)
