defmodule Copilot.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :copilot_sdk_supercharged,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Copilot SDK",
      description: "Elixir SDK for the GitHub Copilot CLI",
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/jeremiahjordanisaacson/copilot-sdk-supercharged"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"]
    ]
  end
end
