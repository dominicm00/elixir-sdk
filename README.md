# Antithesis SDK for BEAM

This library provides methods for BEAM languages (current Erlang/Elixir) to configure the Antithesis platform. These are namespaced into `Assert` for defining test properties, `Random` for Antithesis fuzzer input, and `Lifecycle` for controlling the Antithesis simulation.

Assertions, lifecycle events, randomness and coverage instrumentation for
Elixir and Erlang programs tested in Antithesis.

Build requirements: Linux, Erlang/OTP 27 or later (including development
headers), Elixir 1.18 or later, `make`, and a C compiler. 

## Elixir

### 1. Add the dependency

From your application's root, extract the SDK archive:

```sh
mkdir -p vendor/antithesis-beam-sdk
tar -xzf antithesis-beam-sdk-0.1.0.tar.gz \
  -C vendor/antithesis-beam-sdk --strip-components=1
```

Add the dependency to your application's `mix.exs`:

```elixir
defp deps do
  [{:antithesis_elixir, path: "vendor/antithesis-beam-sdk/elixir"}]
end
```

### 2. Write assertions

All assertions take:

- A **unique string literal** identifying the property
- Optional JSON-encodable details

```elixir
defmodule Bank do
  require Antithesis.Assert, as: Assert

  def withdraw(account, amount) do
    balance = account.balance - amount
    Assert.reachable("withdrawals occur")
    Assert.always(balance >= 0, "balance is never negative", %{balance: balance})
    Assert.sometimes(amount == account.balance, "an account is emptied")
    Assert.always_less_than(amount, 10_000, "withdrawals stay under the limit")
    %{account | balance: balance}
  end
end
```

### 3. Use lifecycle/randomness

These methods should be used in workloads to control fuzzing.

```elixir
Antithesis.Lifecycle.setup_complete()         # the system is ready for fuzzing
Antithesis.Random.get_random()                # get fuzzer-defined random 64-bit integer
Antithesis.Random.random_choice([:a, :b, :c]) # get fuzzer-defined choice
```

### 4. Build

The instrumentation task compiles the project & then instruments the compiled
modules of the project and its dependencies, including transitive dependencies.
The Antithesis SDK applications are excluded.

```sh
MIX_ENV=prod mix deps.get
MIX_ENV=prod mix antithesis.instrument
MIX_ENV=prod mix release
```

To instrument only project applications, use `--skip-dependencies`:

```sh
MIX_ENV=prod mix antithesis.instrument --skip-dependencies
```

This flag does not remove existing dependency instrumentation. Recompile any
previously instrumented dependencies first if you want to remove their probes.

To compile separately, pass `--no-compile` to the instrumentation task:

```sh
MIX_ENV=prod mix deps.get
MIX_ENV=prod mix compile
MIX_ENV=prod mix antithesis.instrument --no-compile
MIX_ENV=prod mix release --no-compile
```

The compiled modules must retain debug information, which Mix includes by default.

Copy `_build/prod/antithesis/symbols` into `/symbols` in the image submitted to
Antithesis. Keep earlier symbol tables when incrementally instrumenting a build.

### 5. Build a container

Replace `my_app` with your release name. Include `vendor/` in the build context;
exclude host `_build/` and `deps/` directories with `.dockerignore`.
The example uses a Trixie-based builder and runtime. When changing images,
keep their Debian versions compatible; releases include native binaries.
Add any dependency setup or runtime libraries required by your application.

```dockerfile
FROM elixir:1.19.7-otp-28 AS build
WORKDIR /app
ENV MIX_ENV=prod
COPY . .
RUN mix antithesis.instrument && mix release

FROM debian:trixie-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       libstdc++6 libncurses6
ENV LANG=C.UTF-8
COPY --from=build /app/_build/prod/rel/my_app /app
COPY --from=build /app/_build/prod/antithesis/symbols /symbols
CMD ["/app/bin/my_app", "start"]
```

### Optional: disable assertions outside Antithesis

To completely compile out assertions for non-Antithesis builds, add the following configuration:

```elixir
config :antithesis_elixir, assertions: false
```

Disabled assertions return `:ok` without evaluating their arguments. Note this can cause unused variable warnings if you have a variable only used for an assertion.
