defmodule Prisma.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/altenwald/prisma"

  def project do
    [
      app: :prisma,
      version: @version,
      language: :erlang,
      erlc_options: [:debug_info],
      description: "Hybrid Success & Gradual Type Analyzer with Modular PPLTs for Erlang and Elixir",
      package: package(),
      docs: docs(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:compiler, :syntax_tools]
    ]
  end

  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: "prisma",
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(src include assets mix.exs rebar.config rebar.lock README* DISCREPANCIES* GRADUAL* LICENSE*)
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "assets/prisma.png",
      assets: %{"assets" => "assets"},
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md", "DISCREPANCIES.md", "GRADUAL.md", "LICENSE"]
    ]
  end
end
