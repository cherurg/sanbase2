defmodule SanbaseWeb.Graphql.Resolvers.ProjectResolver do
  require Logger

  import Ecto.Query, warn: false
  import Absinthe.Resolution.Helpers

  alias Sanbase.Model.Project
  alias Sanbase.Model.ProjectEthAddress
  alias Sanbase.Model.ProjectBtcAddress
  alias Sanbase.Model.LatestBtcWalletData
  alias Sanbase.Model.LatestEthWalletData
  alias Sanbase.Model.LatestCoinmarketcapData
  alias Sanbase.Model.Ico
  alias Sanbase.Model.Currency
  alias Sanbase.Model.MarketSegment
  alias Sanbase.Model.Infrastructure
  alias Sanbase.Model.ProjectTransparencyStatus

  alias Sanbase.Repo

  def all_projects(_parent, args, resolution, only_project_transparency \\ nil) do
    only_project_transparency = case only_project_transparency do
      nil -> Map.get(args, :only_project_transparency, false)
      value -> value
    end

    query = from p in Project,
    where: (^only_project_transparency or not is_nil(p.coinmarketcap_id))
        and (not ^only_project_transparency or p.project_transparency)

    projects = case coinmarketcap_requested?(resolution) do
      true -> Repo.all(query) |> Repo.preload(:latest_coinmarketcap_data)
      _ -> Repo.all(query)
    end

    {:ok, projects}
  end

  def project(_parent, args, resolution) do
    id = Map.get(args, :id)

    project = case coinmarketcap_requested?(resolution) do
      true -> Repo.get(Project, id) |> Repo.preload(:latest_coinmarketcap_data)
      _ -> Repo.get(Project, id)
    end

    {:ok, project}
  end

  def all_projects_with_eth_contract_info(_parent, _args, resolution) do
    all_icos_query = from i in Ico,
    select: %{project_id: i.project_id,
              main_contract_address: i.main_contract_address,
              contract_block_number: i.contract_block_number,
              contract_abi: i.contract_abi,
              rank: fragment("row_number() over(partition by ? order by ? asc)", i.project_id, i.start_date)}

    query = from d in subquery(all_icos_query),
    inner_join: p in Project, on: p.id == d.project_id,
    where: not is_nil(p.coinmarketcap_id)
          and d.rank == 1
          and not is_nil(d.main_contract_address)
          and not is_nil(d.contract_block_number)
          and not is_nil(d.contract_abi),
    select: p

    projects = case coinmarketcap_requested?(resolution) do
      true -> Repo.all(query) |> Repo.preload(:latest_coinmarketcap_data)
      _ -> Repo.all(query)
    end

    {:ok, projects}
  end

  def eth_balance(%Project{id: id}, _args, resolution, only_project_transparency \\ nil) do
    only_project_transparency = case only_project_transparency do
      nil ->
        get_parent_args(resolution)
        |> Map.get(:only_project_transparency, false)
      value -> value
    end

    batch({__MODULE__, :eth_balances_by_id, only_project_transparency}, id, fn batch_results ->
      {:ok, Map.get(batch_results, id)}
    end)
  end
  def eth_balances_by_id(only_project_transparency, project_ids) do
    query = from a in ProjectEthAddress,
    inner_join: wd in LatestEthWalletData, on: wd.address == a.address,
    where: a.project_id in ^project_ids and
          (not ^only_project_transparency or a.project_transparency),
    group_by: a.project_id,
    select: %{project_id: a.project_id, balance: sum(wd.balance)}

    balances = Repo.all(query)

    Map.new(balances, fn balance -> {balance.project_id, balance.balance} end)
  end

  def btc_balance(%Project{id: id}, _args, resolution, only_project_transparency \\ nil) do
    only_project_transparency = case only_project_transparency do
      nil ->
        get_parent_args(resolution)
        |> Map.get(:only_project_transparency, false)
      value -> value
    end

    batch({__MODULE__, :btc_balances_by_id, only_project_transparency}, id, fn batch_results ->
      {:ok, Map.get(batch_results, id)}
    end)
  end
  def btc_balances_by_id(only_project_transparency, project_ids) do
    query = from a in ProjectBtcAddress,
    inner_join: wd in LatestBtcWalletData, on: wd.address == a.address,
    where: a.project_id in ^project_ids and
          (not ^only_project_transparency or a.project_transparency),
    group_by: a.project_id,
    select: %{project_id: a.project_id, balance: sum(wd.satoshi_balance)}

    balances = Repo.all(query)

    Map.new(balances, fn balance -> {balance.project_id, balance.balance} end)
  end

  # If there is no raw data for any currency for a given ico, then fallback one of the precalculated totals - one of Ico.funds_raised_usd, Ico.funds_raised_btc, Ico.funds_raised_eth (checked in that order)
  def funds_raised_icos(%Project{id: id}, _args, _resolution) do
    # We have to aggregate all amounts for every currency for every ICO of the given project, this is the last part of the query (after the with clause).
    # The data to be aggreagated has to be fetched and unioned from two different sources (the "union all" inside the with clause):
    #   * For ICOs that have raw data entered for at least one currency we aggregate it by currency (the first query)
    #   * For ICOs that don't have that data entered (currently everything imported from the spreadsheet) we fall back to a precalculated total (the second query)
    query =
      '''
      with data as (select c.code currency_code, ic.amount
      from icos i
      join ico_currencies ic
      	on ic.ico_id = i.id
      		and ic.amount is not null
      join currencies c
      	on c.id = ic.currency_id
      where i.project_id = $1
      union all
      select case
      		when i.funds_raised_usd is not null then 'USD'
      		when i.funds_raised_btc is not null then 'BTC'
      		when i.funds_raised_eth is not null then 'ETH'
      		else null
      	end currency_code
      	, coalesce(i.funds_raised_usd, i.funds_raised_btc, i.funds_raised_eth) amount
      from icos i
      where i.project_id = $1
      	and not exists (select 1
      		from ico_currencies ic
      		where ic.ico_id = i.id
      			and ic.amount is not null))
      select d.currency_code, sum(d.amount) amount
      from data d
      where d.currency_code is not null
      group by d.currency_code
      order by case
          			when d.currency_code = 'BTC' then '_'
          			when d.currency_code = 'ETH' then '__'
          			when d.currency_code = 'USD' then '___'
          			else d.currency_code
          		end
      '''

      %{rows: rows} = Ecto.Adapters.SQL.query!(Sanbase.Repo, query, [id])

      funds_raised = rows
      |> Enum.map(fn([currency_code, amount]) -> %{currency_code: currency_code, amount: amount} end)

      {:ok, funds_raised}
  end

  def market_segment(%Project{market_segment_id: nil}, _args, _resolution), do: {:ok, nil}
  def market_segment(%Project{market_segment_id: market_segment_id}, _args, _resolution) do
    batch({__MODULE__, :market_segments_by_id}, market_segment_id, fn batch_results ->
      {:ok, Map.get(batch_results, market_segment_id)}
    end)
  end
  def market_segments_by_id(_, market_segment_ids) do
    market_segments = from(i in MarketSegment,
    where: i.id in ^market_segment_ids)
    |> Repo.all()

    Map.new(market_segments, fn market_segment -> {market_segment.id, market_segment.name} end)
  end

  def infrastructure(%Project{infrastructure_id: nil}, _args, _resolution), do: {:ok, nil}
  def infrastructure(%Project{infrastructure_id: infrastructure_id}, _args, _resolution) do
    batch({__MODULE__, :infrastructures_by_id}, infrastructure_id, fn batch_results ->
      {:ok, Map.get(batch_results, infrastructure_id)}
    end)
  end
  def infrastructures_by_id(_, infrastructure_ids) do
    infrastructures = from(i in Infrastructure,
    where: i.id in ^infrastructure_ids)
    |> Repo.all()

    Map.new(infrastructures, fn infrastructure -> {infrastructure.id, infrastructure.code} end)
  end

  def project_transparency_status(%Project{project_transparency_status_id: nil}, _args, _resolution), do: {:ok, nil}
  def project_transparency_status(%Project{project_transparency_status_id: project_transparency_status_id}, _args, _resolution) do
    batch({__MODULE__, :project_transparency_statuses_by_id}, project_transparency_status_id, fn batch_results ->
      {:ok, Map.get(batch_results, project_transparency_status_id)}
    end)
  end
  def project_transparency_statuses_by_id(_, project_transparency_status_ids) do
    project_transparency_statuses = from(i in ProjectTransparencyStatus,
    where: i.id in ^project_transparency_status_ids)
    |> Repo.all()

    Map.new(project_transparency_statuses, fn project_transparency_status -> {project_transparency_status.id, project_transparency_status.name} end)
  end

  def roi_usd(%Project{} = project, _args, _resolution) do
    roi = Project.roi_usd(project)

    {:ok, roi}
  end

  def symbol(%Project{latest_coinmarketcap_data: %LatestCoinmarketcapData{symbol: symbol}}, _args, _resolution) do
    {:ok, symbol}
  end
  def symbol(_parent, _args, _resolution), do: {:ok, nil}

  def rank(%Project{latest_coinmarketcap_data: %LatestCoinmarketcapData{rank: rank}}, _args, _resolution) do
    {:ok, rank}
  end
  def rank(_parent, _args, _resolution), do: {:ok, nil}

  def price_usd(%Project{latest_coinmarketcap_data: %LatestCoinmarketcapData{price_usd: price_usd}}, _args, _resolution) do
    {:ok, price_usd}
  end
  def price_usd(_parent, _args, _resolution), do: {:ok, nil}

  def volume_usd(%Project{latest_coinmarketcap_data: %LatestCoinmarketcapData{volume_usd: volume_usd}}, _args, _resolution) do
    {:ok, volume_usd}
  end
  def volume_usd(_parent, _args, _resolution), do: {:ok, nil}

  def marketcap_usd(%Project{latest_coinmarketcap_data: %LatestCoinmarketcapData{market_cap_usd: market_cap_usd}}, _args, _resolution) do
    {:ok, market_cap_usd}
  end
  def marketcap_usd(_parent, _args, _resolution), do: {:ok, nil}

  def available_supply(%Project{latest_coinmarketcap_data: %LatestCoinmarketcapData{available_supply: available_supply}}, _args, _resolution) do
    {:ok, available_supply}
  end
  def available_supply(_parent, _args, _resolution), do: {:ok, nil}

  def total_supply(%Project{latest_coinmarketcap_data: %LatestCoinmarketcapData{total_supply: total_supply}}, _args, _resolution) do
    {:ok, total_supply}
  end
  def total_supply(_parent, _args, _resolution), do: {:ok, nil}

  def percent_change_1h(%Project{latest_coinmarketcap_data: %LatestCoinmarketcapData{percent_change_1h: percent_change_1h}}, _args, _resolution) do
    {:ok, percent_change_1h}
  end
  def percent_change_1h(_parent, _args, _resolution), do: {:ok, nil}

  def percent_change_24h(%Project{latest_coinmarketcap_data: %LatestCoinmarketcapData{percent_change_24h: percent_change_24h}}, _args, _resolution) do
    {:ok, percent_change_24h}
  end
  def percent_change_24h(_parent, _args, _resolution), do: {:ok, nil}

  def percent_change_7d(%Project{latest_coinmarketcap_data: %LatestCoinmarketcapData{percent_change_7d: percent_change_7d}}, _args, _resolution) do
    {:ok, percent_change_7d}
  end
  def percent_change_7d(_parent, _args, _resolution), do: {:ok, nil}

  def initial_ico(%Project{} = project, _args, _resolution) do
    ico = Project.initial_ico(project)

    {:ok, ico}
  end

  def ico_cap_currency(%Ico{cap_currency_id: nil}, _args, _resolution), do: {:ok, nil}
  def ico_cap_currency(%Ico{cap_currency_id: cap_currency_id}, _args, _resolution) do
    batch({__MODULE__, :currencies_by_id}, cap_currency_id, fn batch_results ->
      {:ok, Map.get(batch_results, cap_currency_id)}
    end)
  end
  def currencies_by_id(_, currency_ids) do
    currencies = from(i in Currency,
    where: i.id in ^currency_ids)
    |> Repo.all()

    Map.new(currencies, fn currency -> {currency.id, currency.code} end)
  end

  def ico_currency_amounts(%Ico{id: id}, _args, _resolution) do
    batch({__MODULE__, :ico_currency_amounts_by_id}, id, fn batch_results ->
      {:ok, Map.get(batch_results, id)}
    end)
  end
  def ico_currency_amounts_by_id(_, ico_ids) do
    query = from i in Ico,
    left_join: ic in assoc(i, :ico_currencies),
    inner_join: c in assoc(ic, :currency),
    where: i.id in ^ico_ids,
    select: %{ico_id: i.id, currency_code: c.code, amount: ic.amount}

    Repo.all(query)
    |> Enum.group_by(&(&1.ico_id), &(%{currency_code: &1.currency_code, amount: &1.amount}))
  end

  defp coinmarketcap_requested?(resolution) do
    case requested_fields(resolution) do
      %{symbol: true} -> true
      %{rank: true} -> true
      %{priceUsd: true} -> true
      %{volumeUsd: true} -> true
      %{marketcapUsd: true} -> true
      %{availableSupply: true} -> true
      %{totalSupply: true} -> true
      %{percent_change_1h: true} -> true
      %{percent_change_24h: true} -> true
      %{percent_change_7d: true} -> true
      _ -> false
    end
  end

  defp requested_fields(resolution) do
    resolution.definition.selections
    |> Enum.map(&(Map.get(&1, :name) |> String.to_atom()))
    |> Enum.into(%{}, fn field -> {field, true} end)
  end

  defp get_parent_args(resolution) do
    case resolution do
      %{path: [_, %{argument_data: parent_args} | _]} -> parent_args
      _ -> %{}
    end
  end
end
