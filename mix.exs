defmodule Malla.MixProject do
  use Mix.Project

  def project do
    [
      app: :malla,
      version: "0.0.1-rc.1",
      elixir: "~> 1.17",
      description: "Framework for developing distributed services in Elixir networks.",
      package: %{
        licenses: ["Apache-2.0"],
        links: %{"GitHub" => "https://github.com/netkubes/malla"},
        files: ~w(lib priv/ai .formatter.exs mix.exs README.md LICENSE.md CHANGELOG.md)
      },
      docs: [
        main: "introduction",
        name: "Malla",
        logo: "assets/logo.png",
        source_ref: "main",
        source_url: "https://github.com/netkubes/malla",
        homepage_url: "https://github.com/netkubes/malla",
        extras: extras(),
        groups_for_extras: groups_for_extras(),
        groups_for_modules: groups_for_modules(),
        before_closing_head_tag: &before_closing_head_tag/1
      ],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :syntax_tools, :crypto, :ssl],
      mod: {Malla.Application, []}
    ]
  end

  defp deps do
    [
      {:telemetry, "~> 1.3"},
      {:ex_doc, "~> 0.40", only: :dev},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp extras do
    [
      "README.md": [title: "Overview"],
      "CHANGELOG.md": [title: "Changelog"],
      "LICENSE.md": [title: "License"],
      "guides/00-glossary.md": [title: "Glossary"],
      "guides/01-introduction.md": [title: "Introduction", filename: "introduction"],
      "guides/02-quick-start.md": [title: "Quick Start"],
      "livebook/getting_started.livemd": [title: "Getting Started Tutorial"],
      "livebook/distributed_tutorial.livemd": [title: "Distributed Services Tutorial"],
      "guides/03-services.md": [title: "Services"],
      "guides/04-plugins.md": [title: "Plugins"],
      "guides/05-callbacks.md": [title: "Callbacks"],
      "guides/06-lifecycle.md": [title: "Service Lifecycle"],
      "guides/07-configuration.md": [title: "Configuration"],
      "guides/07a-reconfiguration.md": [title: "Reconfiguration"],
      "guides/10-storage.md": [title: "Storage and State"],
      "guides/08-distribution/01-cluster-setup.md": [title: "Cluster Setup"],
      "guides/08-distribution/02-service-discovery.md": [title: "Service Discovery"],
      "guides/08-distribution/03-remote-calls.md": [title: "Remote Calls"],
      "guides/08-distribution/04-request-handling.md": [title: "Request Handling"],
      "guides/09-observability/01-tracing.md": [title: "Tracing"],
      "guides/09-observability/02-status-handling.md": [title: "Status Handling"],
      "guides/12-testing.md": [title: "Testing"],
      "guides/13-plugin-development.md": [title: "Plugin Development"],
      "guides/14-troubleshooting.md": [title: "Troubleshooting"],
      "guides/15-deployment.md": [title: "Deployment"]
    ]
  end

  defp groups_for_extras do
    [
      "Getting Started": [
        "Introduction",
        "Quick Start",
        "Getting Started Tutorial",
        "Distributed Services Tutorial"
      ],
      "Core Concepts": [
        "Services",
        "Plugins",
        "Callbacks",
        "Service Lifecycle",
        "Configuration",
        "Reconfiguration",
        "Storage and State"
      ],
      Distribution: [
        "Cluster Setup",
        "Service Discovery",
        "Remote Calls"
      ],
      Observability: [
        "Tracing",
        "Status Handling"
      ],
      "Advanced Topics": [
        "Testing",
        "Plugin Development",
        "Deployment"
      ],
      Reference: [
        "Glossary",
        "Troubleshooting",
        "Plugin API",
        "Service API",
        "Tracer Analysis"
      ]
    ]
  end

  defp groups_for_modules do
    [
      Core: [
        Malla,
        Malla.Service,
        Malla.Service.Interface,
        Malla.Plugin,
        Malla.Plugins.Base
      ],
      Distributed: [
        Malla.Cluster,
        Malla.Node
      ],
      Runtime: [
        Malla.Config,
        Malla.Registry
      ],
      Plugins: [
        Malla.Request,
        Malla.Plugins.Request,
        Malla.Status,
        Malla.Plugins.Status,
        Malla.Tracer,
        Malla.Plugins.Tracer
      ]
    ]
  end

  defp before_closing_head_tag(:html) do
    """
    <script src="https://cdn.jsdelivr.net/npm/mermaid@10.6.1/dist/mermaid.min.js"></script>
    <script>
      document.addEventListener("DOMContentLoaded", function () {
        mermaid.initialize({
          startOnLoad: false,
          theme: document.body.className.includes("dark") ? "dark" : "default"
        });
        let id = 0;
        for (const codeEl of document.querySelectorAll("pre code.mermaid")) {
          const preEl = codeEl.parentElement;
          const graphDefinition = codeEl.textContent;
          const graphEl = document.createElement("div");
          const graphId = "mermaid-graph-" + id++;
          mermaid.render(graphId, graphDefinition).then(({svg, bindFunctions}) => {
            graphEl.innerHTML = svg;
            bindFunctions?.(graphEl);
            preEl.insertAdjacentElement("afterend", graphEl);
            preEl.remove();
          });
        }
      });
    </script>
    """
  end

  defp before_closing_head_tag(_), do: ""

  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      plt_add_apps: [:ex_unit, :mix],
      flags: [:error_handling, :underspecs, :unmatched_returns],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end
end
