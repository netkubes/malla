# Used by "mix format"
locals_without_parens = [
  defcb: 1,
  defcb: 2,
  defcallback: 1,
  defcallback: 2,
  req: 1,
  req: 2,
  call: 1,
  call: 2
]

[
  inputs: ["lib/**/*.ex", "config/*.exs", "{mix,.formatter}.exs", "test/**/*.ex", "test/**/*.exs"],
  locals_without_parens: locals_without_parens,
  export: [
    locals_without_parens: locals_without_parens
  ]
]
