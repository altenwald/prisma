defmodule Spectra.MixProject do
  use Mix.Project

  def project do
    [
      app: :spectra,
      version: "0.1.0",
      language: :erlang,
      erlc_options: [:debug_info],
      description: "Hybrid Success & Gradual Type Analyzer with Modular PLTs for Erlang and Elixir",
      package: package(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:compiler, :syntax_tools]
    ]
  end

  defp deps do
    []
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/altenwald/spectra"}
    ]
  end
end
