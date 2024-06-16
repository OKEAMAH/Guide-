defmodule BlockScoutWeb.API.V2.AddressView do
  use BlockScoutWeb, :view

  import BlockScoutWeb.Account.AuthController, only: [current_user: 1]

  alias BlockScoutWeb.AddressView
  alias BlockScoutWeb.API.V2.{ApiView, Helper, TokenView}
  alias BlockScoutWeb.API.V2.Helper
  alias Explorer.{Chain, Market}
  alias Explorer.Chain.Address
  alias Explorer.Chain.Address.Counters
  alias Explorer.Chain.SmartContract.Proxy.Models.Implementation
  alias Explorer.Chain.Token.Instance

  @api_true [api?: true]

  def render("message.json", assigns) do
    ApiView.render("message.json", assigns)
  end

  def render("address.json", %{address: address, conn: conn}) do
    prepare_address(address, conn)
  end

  def render("token_balances.json", %{token_balances: token_balances}) do
    Enum.map(token_balances, &prepare_token_balance/1)
  end

  def render("coin_balance.json", %{coin_balance: coin_balance}) do
    prepare_coin_balance_history_entry(coin_balance)
  end

  def render("coin_balances.json", %{coin_balances: coin_balances, next_page_params: next_page_params}) do
    %{"items" => Enum.map(coin_balances, &prepare_coin_balance_history_entry/1), "next_page_params" => next_page_params}
  end

  def render("coin_balances_by_day.json", %{coin_balances_by_day: coin_balances_by_day}) do
    %{
      :items => Enum.map(coin_balances_by_day, &prepare_coin_balance_history_by_day_entry/1),
      :days =>
        Application.get_env(:block_scout_web, BlockScoutWeb.Chain.Address.CoinBalance)[:coin_balance_history_days]
    }
  end

  def render("tokens.json", %{tokens: tokens, next_page_params: next_page_params}) do
    %{"items" => Enum.map(tokens, &prepare_token_balance(&1, true)), "next_page_params" => next_page_params}
  end

  def render("addresses.json", %{
        addresses: addresses,
        next_page_params: next_page_params,
        exchange_rate: exchange_rate,
        total_supply: total_supply
      }) do
    %{
      items: Enum.map(addresses, &prepare_address/1),
      next_page_params: next_page_params,
      exchange_rate: exchange_rate.usd_value,
      total_supply: total_supply && to_string(total_supply)
    }
  end

  def render("nft_list.json", %{token_instances: token_instances, token: token, next_page_params: next_page_params}) do
    %{"items" => Enum.map(token_instances, &prepare_nft(&1, token)), "next_page_params" => next_page_params}
  end

  def render("nft_list.json", %{token_instances: token_instances, next_page_params: next_page_params}) do
    %{"items" => Enum.map(token_instances, &prepare_nft(&1)), "next_page_params" => next_page_params}
  end

  def render("nft_collections.json", %{collections: nft_collections, next_page_params: next_page_params}) do
    %{"items" => Enum.map(nft_collections, &prepare_nft_collection(&1)), "next_page_params" => next_page_params}
  end

  @spec prepare_address(
          {atom() | %{:fetched_coin_balance => any(), :hash => any(), optional(any()) => any()}, any()}
          | Explorer.Chain.Address.t()
        ) :: %{optional(:coin_balance) => any(), optional(:tx_count) => binary(), optional(<<_::32, _::_*8>>) => any()}
  def prepare_address({address, tx_count}) do
    nil
    |> Helper.address_with_info(address, address.hash, true)
    |> Map.put(:tx_count, to_string(tx_count))
    |> Map.put(:coin_balance, if(address.fetched_coin_balance, do: address.fetched_coin_balance.value))
  end

  def prepare_address(address, conn \\ nil) do
    base_info = Helper.address_with_info(conn, address, address.hash, true)

    {:ok, address_with_smart_contract} =
      Chain.hash_to_address(
        address.hash,
        [necessity_by_association: %{:smart_contract => :optional}],
        false
      )

    is_proxy = AddressView.smart_contract_is_proxy?(address_with_smart_contract, @api_true)

    {implementation_addresses, implementation_names} =
      with true <- is_proxy,
           {addresses, names} <-
             Implementation.get_implementation(address_with_smart_contract.smart_contract, @api_true),
           false <- addresses && Enum.empty?(addresses) do
        addresses
        |> Enum.zip(names)
        |> Enum.reduce({[], []}, fn {address, name}, {addresses, names} = acc ->
          with {:ok, address_hash} <- Chain.string_to_address_hash(address),
               checksummed_address <- Address.checksum(address_hash) do
            {[checksummed_address | addresses], [name | names]}
          else
            _ -> acc
          end
        end)
      else
        _ ->
          {[], []}
      end

    balance = address.fetched_coin_balance && address.fetched_coin_balance.value
    exchange_rate = Market.get_coin_exchange_rate().usd_value

    creator_hash = AddressView.from_address_hash(address)
    creation_tx = creator_hash && AddressView.transaction_hash(address)
    token = address.token && TokenView.render("token.json", %{token: address.token})

    # todo: added for backward compatibility, remove when frontend unbound from these props
    {implementation_address, implementation_name} =
      single_implementation(implementation_addresses, implementation_names)

    Map.merge(base_info, %{
      "creator_address_hash" => creator_hash && Address.checksum(creator_hash),
      "creation_tx_hash" => creation_tx,
      "token" => token,
      "coin_balance" => balance,
      "exchange_rate" => exchange_rate,
      # todo: added for backward compatibility, remove when frontend unbound from these props
      "implementation_name" => implementation_name,
      "implementation_names" => implementation_names,
      "implementation_address" => implementation_address,
      "implementation_addresses" => implementation_addresses,
      "block_number_balance_updated_at" => address.fetched_coin_balance_block_number,
      "has_decompiled_code" => AddressView.has_decompiled_code?(address),
      "has_validated_blocks" => Counters.check_if_validated_blocks_at_address(address.hash, @api_true),
      "has_logs" => Counters.check_if_logs_at_address(address.hash, @api_true),
      "has_tokens" => Counters.check_if_tokens_at_address(address.hash, @api_true),
      "has_token_transfers" => Counters.check_if_token_transfers_at_address(address.hash, @api_true),
      "watchlist_address_id" => Chain.select_watchlist_address_id(get_watchlist_id(conn), address.hash),
      "has_beacon_chain_withdrawals" => Counters.check_if_withdrawals_at_address(address.hash, @api_true)
    })
  end

  defp single_implementation(implementation_addresses, implementation_names) do
    implementation_name =
      if implementation_names && !Enum.empty?(implementation_names) do
        implementation_names |> Enum.at(0)
      else
        nil
      end

    implementation_address =
      if implementation_addresses && !Enum.empty?(implementation_addresses) do
        implementation_addresses |> Enum.at(0)
      else
        nil
      end

    {implementation_address, implementation_name}
  end

  @spec prepare_token_balance(Chain.Address.TokenBalance.t(), boolean()) :: map()
  defp prepare_token_balance(token_balance, fetch_token_instance? \\ false) do
    %{
      "value" => token_balance.value,
      "token" => TokenView.render("token.json", %{token: token_balance.token}),
      "token_id" => token_balance.token_id,
      "token_instance" =>
        if(fetch_token_instance? && token_balance.token_id,
          do:
            fetch_and_render_token_instance(
              token_balance.token_id,
              token_balance.token,
              token_balance.address_hash,
              token_balance
            )
        )
    }
  end

  def prepare_coin_balance_history_entry(coin_balance) do
    %{
      "transaction_hash" => coin_balance.transaction_hash,
      "block_number" => coin_balance.block_number,
      "delta" => coin_balance.delta,
      "value" => coin_balance.value,
      "block_timestamp" => coin_balance.block_timestamp
    }
  end

  def prepare_coin_balance_history_by_day_entry(coin_balance_by_day) do
    %{
      "date" => coin_balance_by_day.date,
      "value" => coin_balance_by_day.value
    }
  end

  def get_watchlist_id(conn) do
    case current_user(conn) do
      %{watchlist_id: wl_id} ->
        wl_id

      _ ->
        nil
    end
  end

  defp prepare_nft(nft) do
    prepare_nft(nft, nft.token)
  end

  defp prepare_nft(nft, token) do
    Map.merge(
      %{"token_type" => token.type, "value" => value(token.type, nft)},
      TokenView.prepare_token_instance(nft, token)
    )
  end

  defp prepare_nft_collection(collection) do
    %{
      "token" => TokenView.render("token.json", token: collection.token),
      "amount" => string_or_null(collection.distinct_token_instances_count || collection.value),
      "token_instances" =>
        Enum.map(collection.preloaded_token_instances, fn instance ->
          prepare_nft_for_collection(collection.token.type, instance)
        end)
    }
  end

  defp prepare_nft_for_collection(token_type, instance) do
    Map.merge(
      %{"token_type" => token_type, "value" => value(token_type, instance)},
      TokenView.prepare_token_instance(instance, nil)
    )
  end

  defp value("ERC-721", _), do: "1"
  defp value(_, nft), do: nft.current_token_balance && to_string(nft.current_token_balance.value)

  defp string_or_null(nil), do: nil
  defp string_or_null(other), do: to_string(other)

  # TODO think about this approach mb refactor or mark deprecated for example.
  # Suggested solution: batch preload
  @spec fetch_and_render_token_instance(
          Decimal.t(),
          Ecto.Schema.belongs_to(Chain.Token.t()) | nil,
          Chain.Hash.Address.t(),
          Chain.Address.TokenBalance.t()
        ) :: map()
  def fetch_and_render_token_instance(token_id, token, address_hash, token_balance) do
    token_instance =
      case Chain.nft_instance_from_token_id_and_token_address(
             token_id,
             token.contract_address_hash,
             @api_true
           ) do
        # `%{hash: address_hash}` will match with `address_with_info(_, address_hash)` clause in `BlockScoutWeb.API.V2.Helper`
        {:ok, token_instance} ->
          %Instance{token_instance | owner: %{hash: address_hash}, current_token_balance: token_balance}

        {:error, :not_found} ->
          %Instance{
            token_id: token_id,
            metadata: nil,
            owner: %Address{hash: address_hash},
            current_token_balance: token_balance,
            token_contract_address_hash: token.contract_address_hash
          }
          |> Instance.put_is_unique(token, @api_true)
      end

    TokenView.render("token_instance.json", %{
      token_instance: token_instance,
      token: token
    })
  end
end
