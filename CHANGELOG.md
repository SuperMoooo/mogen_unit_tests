# [1.4.0]

## Added

- **flutter_bloc support.** `Bloc<Event, State>` and `Cubit<State>` classes are
  now detected alongside Riverpod notifiers, and get tests built on the
  `bloc_test` package (`blocTest<B, S>(...)` with `build:`, `act:`, `setUp:`,
  `verify:` and `errors:`).
    - A bloc is driven by its events: every `on<Event>(...)` registration
      becomes a test group whose `act:` adds a real event instance, built from
      the event class's own constructor. Both inline `(event, emit) {...}`
      closures and tear-off handlers are supported.
    - A cubit is driven by its public methods.
    - Constructor-injected collaborators are mocked and passed into `build:`.
    - A bloc/cubit dependency is mocked with `bloc_test`'s `MockBloc`/
      `MockCubit` and has its `state` stubbed, since a bare `Mock` has no state
      stream.
    - Calls made by the constructor itself are stubbed once in `setUp()` and
      never failed in the error path — `build:` runs after a `blocTest`'s
      `setUp:`, so failing them would break construction instead of the action.
    - When a handler doesn't catch the failure, the error test asserts
      `errors: () => [isA<AppException>()]` instead of a state field the error
      never reaches.
- The feature scan now covers `presentation/bloc`, `presentation/blocs`,
  `presentation/cubit`, `presentation/cubits`, `presentation/logic` and
  top-level `bloc/`, `cubit/` folders in addition to `presentation/notifiers`.
- State and event classes declared as `part` of a bloc file are recognised as
  such and are no longer imported separately (importing a part file does not
  compile).

## Fixed

- `required this.x` constructor parameters resolved to the literal type
  `this.` instead of the field's declared type, which leaked into generated
  imports and values.
- A method-scoped call scan also picked up calls made in the class's
  constructor.
