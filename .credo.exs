# Credo's defaults, with looser limits on nesting and complexity: the
# GenServers (room/server.ex, agent/worker.ex) dispatch on many messages
# and states, and splitting them up to satisfy the defaults wouldn't make
# them easier to read. The agents project picks this file up too.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      checks: %{
        extra: [
          {Credo.Check.Refactor.Nesting, max_nesting: 4},
          {Credo.Check.Refactor.CyclomaticComplexity, max_complexity: 15}
        ]
      }
    }
  ]
}
