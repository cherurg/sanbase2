defmodule Sanbase.Clickhouse.EthDailyActiveAddresses do
  use Ecto.Schema

  import Ecto.Query
  alias Sanbase.ClickhouseRepo
  alias __MODULE__

  # @primary_key {:dt, :date, []}
  # @timestamps_opts updated_at: false

  schema "eth_daily_active_addresses" do
    field(:dt, :naive_datetime)
    field(:address, :string)
    field(:total_transactions, :integer)
  end

  def changeset(_, _attrs \\ %{}) do
    raise "Should not try to change eth daily active addresses"
  end

  def count_eth_daa() do
    from(
      daa in EthDailyActiveAddresses,
      group_by: daa.dt,
      order_by: daa.dt,
      select: {daa.dt, count("*")}
    )
    |> ClickhouseRepo.all()
  end
end
