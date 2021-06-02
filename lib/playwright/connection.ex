defmodule Playwright.Connection do
  require Logger

  use GenServer
  alias Playwright.ChannelOwner.Root

  # API
  # ----------------------------------------------------------------------------

  # Transport.Driver | Transport.WebSocket
  @type transport_module :: module()
  @type transport_config :: {transport_module, [term()]}

  defstruct(catalog: %{}, messages: %{count: 0, pending: %{}}, queries: %{}, transport: %{})
  # messages -> pending, awaiting, ...

  @spec start_link([transport_config]) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  # API: items...

  def get(connection, {:guid, _guid} = item) do
    GenServer.call(connection, {:get, item})
  end

  # API: messages...

  # TODO: backfill test
  def find(connection, attributes, default \\ []) do
    GenServer.call(connection, {:find, attributes, default})
  end

  def post(connection, {:data, _data} = message) do
    GenServer.call(connection, {:post, message})
  end

  def recv(connection, {:text, _json} = message) do
    GenServer.cast(connection, {:recv, message})
  end

  # @impl
  # ----------------------------------------------------------------------------

  @impl GenServer
  def init([{transport_module, config}]) do
    {:ok,
     %__MODULE__{
       catalog: %{
         "Root" => Root.new(self())
       },
       transport: %{
         mod: transport_module,
         pid: transport_module.start_link!([self()] ++ config)
       }
     }}
  end

  @impl GenServer
  def handle_call({:find, attrs, default}, _from, %{catalog: catalog} = state) do
    case select(Map.values(catalog), attrs, []) do
      [] ->
        {:reply, default, state}

      result ->
        {:reply, result, state}
    end
  end

  @impl GenServer
  def handle_call({:get, {:guid, guid}}, from, %{catalog: catalog, queries: queries} = state) do
    case catalog[guid] do
      nil ->
        {:noreply, %{state | queries: Map.put(queries, guid, from)}}

      item ->
        {:reply, item, state}
    end
  end

  @impl GenServer
  def handle_call({:post, {:data, data}}, from, %{messages: messages, queries: queries, transport: transport} = state) do
    index = messages.count + 1
    payload = Map.put(data, :id, index)
    queries = Map.put(queries, index, from)

    messages =
      Map.merge(messages, %{
        count: index,
        pending: Map.put(messages.pending, index, payload)
      })

    transport.mod.post(transport.pid, Jason.encode!(payload))

    {:noreply, %{state | messages: messages, queries: queries}}
  end

  @impl GenServer
  def handle_cast({:recv, {:text, json}}, state) do
    {:noreply, _recv_(json, state)}
  end

  # temp/legacy (while refactoring)
  # ----------------------------------------------------------------------------
  @impl GenServer
  def handle_info({:process_frame, {:data, data}}, state) do
    handle_cast({:recv, {:text, Jason.encode!(data)}}, state)
  end

  # private
  # ----------------------------------------------------------------------------

  defp _del_(guid, catalog) do
    children = select(Map.values(catalog), %{parent: catalog[guid]}, [])

    catalog =
      children
      |> Enum.reduce(catalog, fn item, acc ->
        _del_(item.guid, acc)
      end)

    Map.delete(catalog, guid)
  end

  defp _put_(item, %{catalog: catalog, queries: queries} = state) do
    case Map.pop(queries, item.guid, nil) do
      {nil, _queries} ->
        state

      {from, queries} ->
        GenServer.reply(from, item)
        %{state | queries: queries}
    end

    Map.put(catalog, item.guid, item)
  end

  defp _recv_(<<json::binary>>, state) do
    _recv_(Jason.decode!(json), state)
  end

  defp _recv_(%{"id" => message_id, "result" => result}, state) do
    case Map.to_list(result) do
      [{_key, %{"guid" => guid}}] ->
        reply_from_catalog({message_id, guid}, state)

      [{"elements", value}] ->
        reply_with_value({message_id, value}, state)

      # [{"value", <<value::binary>>}] ->
      [{"value", value}] ->
        reply_with_value({message_id, value}, state)

      [] ->
        reply_with_value({message_id, nil}, state)
    end
  end

  defp _recv_(%{"id" => message_id} = data, state) do
    reply_from_messages({message_id, data}, state)
  end

  defp _recv_(%{"guid" => ""} = data, state) do
    _recv_(Map.put(data, "guid", "Root"), state)
  end

  defp _recv_(
         %{"guid" => parent_guid, "method" => "__create__", "params" => params},
         %{catalog: catalog} = state
       ) do
    item = apply(resource(params), :new, [catalog[parent_guid], params])
    %{state | catalog: _put_(item, state)}
  end

  defp _recv_(%{"guid" => guid, "method" => "__dispose__"}, %{catalog: catalog} = state) do
    %{state | catalog: _del_(guid, catalog)}
  end

  defp _recv_(data, state) do
    Logger.debug("_recv_ other   :: #{inspect(data)}")
    state
  end

  defp resource(%{"type" => type}) do
    String.to_existing_atom("Elixir.Playwright.ChannelOwner.#{type}")
  end

  defp reply_from_catalog({message_id, guid}, %{catalog: catalog, messages: messages, queries: queries} = state) do
    {_message, pending} = Map.pop!(messages.pending, message_id)
    {from, queries} = Map.pop!(queries, message_id)

    GenServer.reply(from, catalog[guid])

    %{state | messages: Map.put(messages, :pending, pending), queries: queries}
  end

  defp reply_from_messages({message_id, data}, %{catalog: _catalog, messages: messages, queries: queries} = state) do
    {message, pending} = Map.pop!(messages.pending, message_id)
    {from, queries} = Map.pop!(queries, message_id)

    # Logger.debug(
    #   "reply_from_messages with message: #{inspect(message)} and catalog keys: #{inspect(Map.keys(catalog))}"
    # )

    # TODO (need to atomize keys):
    stringified = Jason.decode!(Jason.encode!(message))
    GenServer.reply(from, Map.merge(stringified, data))

    %{state | messages: Map.put(messages, :pending, pending), queries: queries}
  end

  defp reply_with_value({message_id, value}, %{messages: messages, queries: queries} = state) do
    {_message, pending} = Map.pop!(messages.pending, message_id)
    {from, queries} = Map.pop!(queries, message_id)

    GenServer.reply(from, value)

    %{state | messages: Map.put(messages, :pending, pending), queries: queries}
  end

  defp select([], _attrs, result) do
    result
  end

  defp select([head | tail], attrs, result) when head.type == "" do
    select(tail, attrs, result)
  end

  defp select([head | tail], %{parent: parent, type: type} = attrs, result)
       when head.parent.guid == parent.guid and head.type == type do
    select(tail, attrs, result ++ [head])
  end

  defp select([head | tail], %{parent: parent} = attrs, result)
       when head.parent.guid == parent.guid do
    select(tail, attrs, result ++ [head])
  end

  defp select([head | tail], %{guid: guid} = attrs, result)
       when head.guid == guid do
    select(tail, attrs, result ++ [head])
  end

  defp select([_head | tail], attrs, result) do
    select(tail, attrs, result)
  end
end