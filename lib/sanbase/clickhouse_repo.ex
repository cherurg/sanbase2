defmodule Sanbase.ClickhouseRepo do
  use Ecto.Repo, otp_app: :sanbase

  @doc """
  Dynamically loads the repository url from the
  DATABASE_URL environment variable.
  """
  def init(_, opts) do
    # System.get_env("CLICKHOUSE_DATABASE_URL"))}
    {:ok, Keyword.put(opts, :url, "")}
  end
end
