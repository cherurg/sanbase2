defmodule Sanbase.Clickhouse.EthTransfers do
  use Ecto.Schema
  import Ecto.Query
  alias Sanbase.ClickhouseRepo

  schema "eth_transfers" do
    field(:from, :string)
    field(:to, :string)
    field(:value, :float)
    field(:blockNumber, :integer)
    field(:timestamp, :integer)
    field(:transactionHash, :string)
    field(:transactionPosition, :integer)
  end

  def changeset(_, _attrs \\ %{}) do
    raise "Should not try to change eth transfers"
  end
end
